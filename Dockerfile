# syntax=docker/dockerfile:1
FROM alpine:latest AS builder

ARG SSL_LIBRARY=aws-lc

ARG AWS_LC_TAG=v5.15.0 \
	LIBRESSL_TAG=v4.4.1 \
	OPENSSL_TAG=openssl-4.1.0 \
	WOLFSSL_TAG=v5.9.4 \
	HAPROXY_VERSION=3.4.8

RUN <<EOF
set -ex
sed -i -r 's/v\d+\.\d+/edge/g' /etc/apk/repositories
apk update
apk upgrade --no-interactive --latest
apk add --no-cache \
	clang \
	curl \
	file \
	gcc \
	libc-dev \
	linux-headers \
	lld \
	lua5.4-dev \
	make \
	openssl \
	pcre2-dev \
	pcre2-static \
	perl \
	tar \
	--repository=http://dl-cdn.alpinelinux.org/alpine/edge/main
EOF

RUN <<EOF
set -ex
mkdir -p /usr/src

case "${SSL_LIBRARY}" in
	openssl)
		#
		# OpenSSL library (with QUIC support)
		#
		apk add --no-cache autoconf automake
		curl --fail --show-error --silent --location https://github.com/openssl/openssl/archive/refs/tags/${OPENSSL_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=openssl --strip-components=1
		cd /usr/src/openssl
		CC=clang ./config no-shared no-tests no-apps no-module --libdir=lib -ffunction-sections -fdata-sections
		make -j"$(nproc)" && make install_sw
		;;
	libressl)
		#
		# LibreSSL
		#
		apk add --no-cache autoconf automake libtool git patch
		curl --fail --show-error --silent --location https://github.com/libressl-portable/portable/archive/refs/tags/${LIBRESSL_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libressl --strip-components=1
		cd /usr/src/libressl
		./autogen.sh
		CC=clang CXX=clang++ CFLAGS="-O2 -ffunction-sections -fdata-sections" ./configure \
			--disable-shared \
			--disable-tests \
			--enable-static
		make -j"$(nproc)" install
		;;
	aws-lc)
		#
		# AWS-LC
		#
		apk add --no-cache cmake samurai
		curl --fail --show-error --silent --location https://github.com/aws/aws-lc/archive/refs/tags/${AWS_LC_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=aws-lc --strip-components=1
		cd /usr/src/aws-lc
		mkdir -p .openssl/lib .openssl/include
		ln -sf /usr/src/aws-lc/include/openssl /usr/src/aws-lc/.openssl/include/openssl
		CC=clang CXX=clang++ cmake -GNinja -B build \
			-DCMAKE_BUILD_TYPE=Release \
			-DBUILD_TESTING=OFF \
			-DBUILD_TOOL=OFF \
			-DDISABLE_GO=ON \
			-DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
			-DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections"
		ninja -C build
		cp build/crypto/libcrypto.a build/ssl/libssl.a .openssl/lib
		;;
	wolfssl)
		#
		# WolfSSL
		#
		apk add --no-cache autoconf automake libtool
		mkdir -p /usr/src/wolfssl
		curl --fail --show-error --silent --location https://github.com/wolfSSL/wolfssl/archive/refs/tags/${WOLFSSL_TAG}-stable.tar.gz | tar xz -C /usr/src/wolfssl --strip-components=1
		cd /usr/src/wolfssl
		./autogen.sh
		CC=clang CXX=clang++ CFLAGS="-O2 -ffunction-sections -fdata-sections" ./configure \
			--disable-examples \
			--disable-shared \
			--enable-static \
			--enable-alpn \
			--enable-earlydata \
			--enable-haproxy \
			--enable-quic \
			--enable-tlsv12 \
			--enable-tls13 \
			--enable-curve25519 \
			--enable-ed25519
		make -j"$(nproc)" install
		;;
	*)
		echo "Unsupported SSL_LIBRARY: '${SSL_LIBRARY}' (expected: aws-lc, openssl, libressl, wolfssl)" >&2
		exit 1
		;;
esac
EOF

RUN <<EOF
#
# Compile HAProxy
#
set -ex
curl --fail --show-error --silent --location "https://www.haproxy.org/download/$(echo "${HAPROXY_VERSION}" | cut -f 1-2 -d .)/src/haproxy-${HAPROXY_VERSION}.tar.gz" | tar xz -C /usr/src --one-top-level=haproxy --strip-components=1
cd /usr/src/haproxy

# Default make options
# Note: USE_STATIC_PCRE2 is implied due to static LDFLAGS
MAKE_OPTS=" \
	TARGET=linux-musl \
	CPU=generic \
	CC=clang \
	CXX=clang++ \
	LUA_INC=/usr/include/lua5.4 \
	LUA_LIB=/usr/lib/lua5.4 \
	LUA_LIB_NAME=lua \
	USE_CPU_AFFINITY=1 \
	USE_GETADDRINFO=1 \
	USE_LIBCRYPT=1 \
	USE_LUA=1 \
	USE_NS=1 \
	USE_OPENSSL=1 \
	USE_PCRE2=1 \
	USE_PCRE2_JIT=1 \
	USE_QUIC=1 \
	USE_SLZ=1 \
	USE_TFO=1 \
	USE_THREAD=1 \
	"

MAKE_OPTS_EXTRA=""
case "${SSL_LIBRARY}" in
	openssl)
		MAKE_OPTS_EXTRA=" \
			SSL_INC=/usr/local/include \
			SSL_LIB=/usr/local/lib \
			"
		;;
	wolfssl)
		MAKE_OPTS_EXTRA=" \
			SSL_INC=/usr/local/include/wolfssl \
			SSL_LIB=/usr/local/lib \
			USE_OPENSSL_WOLFSSL=1 \
			"
		;;
	libressl)
		MAKE_OPTS_EXTRA=" \
			SSL_INC=/usr/local/include \
			SSL_LIB=/usr/local/lib \
			"
		;;
	aws-lc)
		MAKE_OPTS_EXTRA=" \
			SSL_INC=/usr/src/aws-lc/.openssl/include \
			SSL_LIB=/usr/src/aws-lc/.openssl/lib \
			USE_OPENSSL_AWSLC=1 \
			"
		;;
esac

make -j "$(nproc)" \
	$MAKE_OPTS \
	$MAKE_OPTS_EXTRA \
	ADD_CFLAGS="-ffunction-sections -fdata-sections -flto=thin" \
	LDFLAGS="-static -s -Wl,--gc-sections -Wl,-z,nostart-stop-gc -flto=thin -fuse-ld=lld" \
	SUBVERS="-http3-${SSL_LIBRARY}"

make PREFIX=/usr install-bin
ls -lh /usr/sbin/haproxy
file /usr/sbin/haproxy
/usr/sbin/haproxy -vv
EOF

COPY --link ["scratchfs", "/scratchfs"]

RUN <<EOF
set -ex
mkdir -p /scratchfs/etc/ssl /scratchfs/usr/sbin /scratchfs/var/lib/haproxy/stats /scratchfs/etc/haproxy/conf.d /scratchfs/var/run

#
# Prepare destination scratchfs
#
# Create self-signed certificate
/usr/bin/openssl req -x509 -newkey rsa:4096 -nodes -keyout /scratchfs/etc/ssl/localhost.pem.key -out /scratchfs/etc/ssl/localhost.pem -days 365 -sha256 -subj "/CN=localhost"
chown 1000:1000 /scratchfs/etc/ssl/localhost.pem.key /scratchfs/var/lib/haproxy /scratchfs/var/lib/haproxy/stats /scratchfs/var/run

#
# Mozilla CA cert bundle
#
curl --fail --show-error --silent --location --compressed --output /scratchfs/etc/ssl/cacert.pem https://curl.se/ca/cacert.pem
curl --fail --show-error --silent --location --compressed --output /scratchfs/etc/ssl/cacert.pem.sha256 https://curl.se/ca/cacert.pem.sha256
cd /scratchfs/etc/ssl
sha256sum -c /scratchfs/etc/ssl/cacert.pem.sha256
rm /scratchfs/etc/ssl/cacert.pem.sha256

cp /usr/sbin/haproxy /scratchfs/usr/sbin/
EOF

FROM scratch

COPY --from=builder /scratchfs /

EXPOSE 8080/tcp 8443/tcp 8443/udp
STOPSIGNAL SIGUSR1

ENTRYPOINT ["/usr/sbin/haproxy"]
CMD ["-f", "/etc/haproxy/haproxy.cfg", "-f", "/etc/haproxy/conf.d/"]
