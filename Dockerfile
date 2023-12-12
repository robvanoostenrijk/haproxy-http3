# syntax=docker/dockerfile:1.4
FROM alpine:latest AS builder

ARG SSL_LIBRARY

ENV OPENSSL_QUIC_TAG=openssl-3.1.4-quic1 \
    LIBRESSL_TAG=v3.8.2 \
    WOLFSSL_TAG=v5.6.3-stable \
    LIBSLZ_TAG=v1.2.1 \
    LUA_VERSION=5.4.6 \
    LUA_SHA256=7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88 \
    HAPROXY_VERSION=2.8.5

COPY --link ["scratchfs", "/scratchfs"]

RUN <<EOF
set -ex
apk add --no-cache --virtual .build-deps \
  autoconf \
  automake \
  clang \
  curl \
  file \
  git \
  gnupg \
  libc-dev \
  libtool \
  linux-headers \
  make \
  openssl \
  patch \
  pcre2-dev \
  perl \
  readline-dev \
  tar \
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
if [ "${SSL_LIBRARY}" = "openssl" ]; then curl --silent --location https://github.com/quictls/openssl/archive/refs/tags/${OPENSSL_QUIC_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=openssl --strip-components=1; fi

#
# LibreSSL
#
if [ "${SSL_LIBRARY}" = "libressl" ]; then curl --silent --location https://github.com/libressl-portable/portable/archive/refs/tags/${LIBRESSL_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libressl --strip-components=1; fi

#
# WolfSSL
#
#
# WolfSSL
#
if [ "${SSL_LIBRARY}" = "wolfssl" ]; then 
  curl --silent --location -o /usr/src/wolfssl.tar.gz https://github.com/wolfSSL/wolfssl/archive/refs/tags/${WOLFSSL_TAG}-stable.tar.gz
  mkdir /usr/src/wolfssl
  tar xzf /usr/src/wolfssl.tar.gz -C /usr/src/wolfssl --strip-components=1
  rm /usr/src/wolfssl.tar.gz
fi

#
# LUA
#
  curl --silent --location --output /usr/src/lua.tar.gz https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz
  cd /usr/src
  echo "$LUA_SHA256 lua.tar.gz" | sha256sum -c
  tar -xzf /usr/src/lua.tar.gz -C /usr/src --one-top-level=lua --strip-components=1
  rm /usr/src/lua.tar.gz
#
# libslz
#
  curl --silent --location https://github.com/wtarreau/libslz/archive/refs/tags/${LIBSLZ_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libslz --strip-components=1
#
# HAProxy
#
  curl --silent --location http://www.haproxy.org/download/$(echo ${HAPROXY_VERSION} | cut -f 1-2 -d .)/src/haproxy-${HAPROXY_VERSION}.tar.gz | tar xz -C /usr/src --one-top-level=haproxy --strip-components=1
#
# OpenSSL+quic1
#
if [ "${SSL_LIBRARY}" = "openssl" ]; then
  cd /usr/src/openssl
  CC=clang ./Configure no-shared no-tests linux-generic64
  make -j$(getconf _NPROCESSORS_ONLN) && make install_sw
  SSL_COMMIT="openssl+quic1-${OPENSSL_QUIC_TAG}"
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
  SSL_COMMIT="libressl-${LIBRESSL_TAG}"
fi
#
# WolfSSL
#
if [ "${SSL_LIBRARY}" = "wolfssl" ]; then
  cd /usr/src/wolfssl
  ./autogen.sh
  CC=clang CXX=clang++ ./configure \
    --disable-shared \
    --disable-tests \
    --enable-static \
    --enable-haproxy
  make -j$(getconf _NPROCESSORS_ONLN) install
  SSL_COMMIT="wolfssl-${WOLFSSL_TAG}"
fi
#
# Compile LUA
#
  cd /usr/src/lua
  make CC=clang -j "$(getconf _NPROCESSORS_ONLN)" linux
#
# Compile libslz
#
  cd /usr/src/libslz
  make CC=clang static

EOF

#
# Compile HAProxy
#
RUN <<EOF

set -x
cd /usr/src/haproxy
make -j "$(getconf _NPROCESSORS_ONLN)" \
    TARGET=linux-musl \
    LDFLAGS="-g -w -static -s" \
    CPU=generic \
    CC=clang \
    CXX=clang \
    LUA_INC=/usr/src/lua/src \
    LUA_LIB=/usr/src/lua/src \
    SLZ_INC=/usrc/src/libslz/src \
    SLZ_LIB=/usr/src/libslz \
    USE_CPU_AFFINITY=1 \
    USE_GETADDRINFO=1 \
    USE_LIBCRYPT=1 \
    USE_LUA=1 \
    USE_NS=1 \
    USE_OPENSSL=1 \
    USE_PCRE2=1 \
    USE_PCRE2_JIT=1 \
    USE_QUIC=1 \
    USE_STATIC_PCRE2= \
    USE_TFO=1 \
    USE_THREAD=1 \
    SUBVERS="-http3-${SSL_LIBRARY}"
make PREFIX=/usr install-bin
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
