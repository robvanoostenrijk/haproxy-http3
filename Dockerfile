# syntax=docker/dockerfile:1
FROM alpine:latest AS builder

ARG SSL_LIBRARY

ARG AWS_LC_TAG=v1.68.0 \
	LIBRESSL_TAG=v4.1.2 \
	OPENSSL_TAG=openssl-3.6.1 \
	WOLFSSL_TAG=v5.8.4 \
	LIBSLZ_TAG=v1.2.1 \
	HAPROXY_VERSION=3.3.4

COPY --link ["scratchfs", "/scratchfs"]

RUN <<EOF
set -ex
sed -i -r 's/v\d+\.\d+/edge/g' /etc/apk/repositories
apk update
apk upgrade --no-interactive --latest
apk add --no-cache --virtual .build-deps \
	autoconf \
	automake \
	clang \
	cmake \
	curl \
	file \
	git \
	go \
	gnupg \
	libc-dev \
	libtool \
	linux-headers \
	lua5.4-dev \
	make \
	openssl \
	patch \
	pcre2-dev \
	pcre2-static \
	perl \
	readline-dev \
	samurai \
	tar \
	util-linux-misc \
	--repository=http://dl-cdn.alpinelinux.org/alpine/edge/main

#
# Prepare destination scratchfs
#
# Create self-signed certificate
openssl req -x509 -newkey rsa:4096 -nodes -keyout /scratchfs/etc/ssl/localhost.pem.key -out /scratchfs/etc/ssl/localhost.pem -days 365 -sha256 -subj "/CN=localhost"
chown 1000:1000 /scratchfs/etc/ssl/localhost.pem.key /scratchfs/var/lib/haproxy /scratchfs/var/lib/haproxy/stats

#
# Mozilla CA cert bundle
#
curl --silent --location --compressed --output /scratchfs/etc/ssl/cacert.pem https://curl.haxx.se/ca/cacert.pem
curl --silent --location --compressed --output /scratchfs/etc/ssl/cacert.pem.sha256 https://curl.haxx.se/ca/cacert.pem.sha256
cd /scratchfs/etc/ssl
sha256sum -c /scratchfs/etc/ssl/cacert.pem.sha256
rm /scratchfs/etc/ssl/cacert.pem.sha256

mkdir -p /usr/src
#
# OpenSSL library (with QUIC support)
#
if [ "${SSL_LIBRARY}" = "openssl" ]; then curl --silent --location https://github.com/openssl/openssl/archive/refs/tags/${OPENSSL_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=openssl --strip-components=1; fi

#
# LibreSSL
#
if [ "${SSL_LIBRARY}" = "libressl" ]; then curl --silent --location https://github.com/libressl-portable/portable/archive/refs/tags/${LIBRESSL_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libressl --strip-components=1; fi

#
# AWS-LC
#
if [ "${SSL_LIBRARY}" = "aws-lc" ]; then curl --silent --location https://github.com/aws/aws-lc/archive/refs/tags/${AWS_LC_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=aws-lc --strip-components=1; fi

#
# WolfSSL
#
if [ "${SSL_LIBRARY}" = "wolfssl" ]; then 
	curl --silent --location -o /usr/src/wolfssl.tar.gz https://github.com/wolfSSL/wolfssl/archive/refs/tags/${WOLFSSL_TAG}-stable.tar.gz
	mkdir /usr/src/wolfssl
	tar -xzf /usr/src/wolfssl.tar.gz -C /usr/src/wolfssl --strip-components=1
	rm /usr/src/wolfssl.tar.gz
fi

#
# libslz
#
curl --silent --location https://github.com/wtarreau/libslz/archive/refs/tags/${LIBSLZ_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libslz --strip-components=1

#
# HAProxy
#
curl --silent --location http://www.haproxy.org/download/$(echo ${HAPROXY_VERSION} | cut -f 1-2 -d .)/src/haproxy-${HAPROXY_VERSION}.tar.gz | tar xz -C /usr/src --one-top-level=haproxy --strip-components=1

#
# OpenSSL
#
if [ "${SSL_LIBRARY}" = "openssl" ]; then
	cd /usr/src/openssl
	CC=clang ./Configure no-shared no-tests linux-generic64
	make -j$(getconf _NPROCESSORS_ONLN) && make install_sw
fi

#
# LibreSSL
#
if [ "${SSL_LIBRARY}" = "libressl" ]; then
	cd /usr/src/libressl
	./autogen.sh
	CC=clang CXX=clang++ ./configure \
	--disable-shared \
	--disable-tests \
	--enable-static
make -j$(getconf _NPROCESSORS_ONLN) install
fi

#
# AWS-LC
#
if [ "${SSL_LIBRARY}" = "aws-lc" ]; then
	cd /usr/src/aws-lc
	mkdir -p .openssl/lib .openssl/include
	ln -sf /usr/src/aws-lc/include/openssl /usr/src/aws-lc/.openssl/include/openssl
	CC=clang CXX=clang++ cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release
	ninja -C build || exit 1
	cp build/crypto/libcrypto.a build/ssl/libssl.a .openssl/lib
fi

#
# WolfSSL
#
if [ "${SSL_LIBRARY}" = "wolfssl" ]; then
	cd /usr/src/wolfssl
	./autogen.sh
	CC=clang CXX=clang++ ./configure \
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
	make -j$(getconf _NPROCESSORS_ONLN) install
fi

#
# Compile libslz
#
cd /usr/src/libslz
make CC=clang static
EOF

RUN <<EOF
#
# Compile HAProxy
#
set -x
cd /usr/src/haproxy

# Default make options
# Note: USE_PCRE2_STATIC is implied due to static LD_FLAGS
MAKE_OPTS=" \
		TARGET=linux-musl \
		CPU=generic \
		CC=clang \
		CXX=clang \
		SLZ_INC=/usrc/src/libslz/src \
		SLZ_LIB=/usr/src/libslz \
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

if [ "${SSL_LIBRARY}" = "wolfssl" ]; then
MAKE_OPTS_EXTRA=" \
	SSL_INC=/usr/local/include/wolfssl
	USE_OPENSSL_WOLFSSL=1 \
	"
fi

if [ "${SSL_LIBRARY}" = "aws-lc" ]; then
MAKE_OPTS_EXTRA=" \
	SSL_INC=/usr/src/aws-lc/.openssl/include \
	SSL_LIB=/usr/src/aws-lc/.openssl/lib \
	USE_OPENSSL_AWSLC=1 \
	"
fi

make -j "$(getconf _NPROCESSORS_ONLN)" \
	$MAKE_OPTS \
	$MAKE_OPTS_EXTRA \
	LDFLAGS="-g -w -static -s" \
	SUBVERS="-http3-${SSL_LIBRARY}"

make PREFIX=/usr install-bin
ls -lh /usr/sbin/haproxy
file /usr/sbin/haproxy
/usr/sbin/haproxy -vv

cp /usr/sbin/haproxy /scratchfs/usr/sbin/

EOF

FROM scratch

COPY --from=builder /scratchfs /

EXPOSE 8080/tcp 8443/tcp 8443/udp
STOPSIGNAL SIGUSR1

ENTRYPOINT ["/usr/sbin/haproxy"]
CMD ["-f", "/etc/haproxy/haproxy.cfg"]
