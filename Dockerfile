# syntax=docker/dockerfile:1.4
FROM alpine:latest AS builder

ARG SSL_LIBRARY

ENV	OPENSSL_QUIC_TAG=openssl-3.0.7+quic1 \
    LIBRESSL_TAG=v3.6.1 \
    LIBSLZ_TAG=v1.2.1 \
    LUA_VERSION=5.4.4 \
    LUA_SHA256=164c7849653b80ae67bec4b7473b884bf5cc8d2dca05653475ec2ed27b9ebf61 \
    HAPROXY_VERSION=2.7.1

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
  patch \
  pcre2-dev \
  perl \
  readline-dev \
  tar \
  xz \
  --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main

mkdir -p /usr/src
#
# OpenSSL library (with QUIC support)
#
if [ "${SSL_LIBRARY}" = "openssl" ]; then curl --location https://github.com/quictls/openssl/archive/refs/tags/${OPENSSL_QUIC_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=openssl --strip-components=1; fi

#
# LibreSSL
#
if [ "${SSL_LIBRARY}" = "libressl" ]; then curl --location https://github.com/libressl-portable/portable/archive/refs/tags/${LIBRESSL_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libressl --strip-components=1; fi

#
# LUA
#
  curl --location --output /usr/src/lua.tar.gz https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz
  cd /usr/src
  echo "$LUA_SHA256 *lua.tar.gz" | sha256sum -c
  tar -xzf /usr/src/lua.tar.gz -C /usr/src --one-top-level=lua --strip-components=1
  rm /usr/src/lua.tar.gz
#
# libslz
#
  curl --location https://github.com/wtarreau/libslz/archive/refs/tags/${LIBSLZ_TAG}.tar.gz | tar xz -C /usr/src --one-top-level=libslz --strip-components=1
#
# HAProxy
#
  curl --location http://www.haproxy.org/download/$(echo ${HAPROXY_VERSION} | cut -f 1-2 -d .)/src/haproxy-${HAPROXY_VERSION}.tar.gz | tar xz -C /usr/src --one-top-level=haproxy --strip-components=1
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

EOF

FROM busybox

RUN <<EOF

set -x
echo "haproxy:x:1000:1000:haproxy:/bin:/bin/false" >> /etc/passwd
echo "haproxy:x:1000:" >> /etc/group

mkdir -p /var/lib/haproxy/stats
chown -R haproxy:haproxy /var/lib/haproxy

EOF

COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY --from=builder /usr/sbin/haproxy /usr/sbin/haproxy

STOPSIGNAL SIGUSR1

EXPOSE 80/tcp 443/tcp 443/udp

ENTRYPOINT ["/usr/sbin/haproxy"]
CMD ["-f", "/etc/haproxy/haproxy.cfg"]
