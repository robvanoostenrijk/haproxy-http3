FROM alpine:latest

ARG SSL_LIBRARY

ENV	OPENSSL_QUIC_TAG=openssl-3.0.7+quic1 \
    LIBRESSL_TAG=v3.6.1 \
    LIBSLZ_TAG=v1.2.1 \
    LUA_VERSION=5.4.4 \
    LUA_SHA256=164c7849653b80ae67bec4b7473b884bf5cc8d2dca05653475ec2ed27b9ebf61 \
    HAPROXY_VERSION=2.6.7

RUN set -ex; \
    apk add --no-cache --virtual .build-deps \
    autoconf \
    xz \
    libtool \
    automake \
    curl \
    g++ \
    gcc \
    clang \
    git \
    libc-dev \
    linux-headers \
    make \
    patch \
    file \
    gnupg \
    pcre2-dev \
    perl \
    readline-dev \
    tar \
    --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main

RUN set -x \
#
# OpenSSL library (with QUIC support)
#
  && mkdir -p /usr/src/openssl \
  && curl --location https://github.com/quictls/openssl/archive/refs/tags/${OPENSSL_QUIC_TAG}.tar.gz | tar xz -C /usr/src/openssl --strip-components=1 \
#
# LibreSSL
#
  && mkdir /usr/src/libressl \
  && curl --location https://github.com/libressl-portable/portable/archive/refs/tags/${LIBRESSL_TAG}.tar.gz | tar xz -C /usr/src/libressl --strip-components=1 \
#
# LUA
#
  && curl --location --output /usr/src/lua.tar.gz https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz \
  && cd /usr/src \
  && echo "$LUA_SHA256 *lua.tar.gz" | sha256sum -c \
  && mkdir -p /usr/src/lua \
  && tar -xzf /usr/src/lua.tar.gz -C /usr/src/lua --strip-components=1 \
  && rm /usr/src/lua.tar.gz \
#
# libslz
#
  && mkdir -p /usr/src/libslz \
  && curl --location https://github.com/wtarreau/libslz/archive/refs/tags/${LIBSLZ_TAG}.tar.gz | tar xz -C /usr/src/libslz --strip-components=1 \
#
# HAProxy
#
  && mkdir -p /usr/src/haproxy \
  && curl --location http://www.haproxy.org/download/$(echo ${HAPROXY_VERSION} | cut -f 1-2 -d .)/src/haproxy-${HAPROXY_VERSION}.tar.gz | tar xz -C /usr/src/haproxy --strip-components=1 \
#
# OpenSSL+quic1
#
  && cd /usr/src/openssl \
  && if [ "${SSL_LIBRARY}" = "openssl" ]; then ./Configure no-shared no-tests linux-generic64; fi \
  && if [ "${SSL_LIBRARY}" = "openssl" ]; then make -j$(getconf _NPROCESSORS_ONLN) && make install_sw; fi \
#
# LibreSSL
#
  && cd /usr/src/libressl \
  && if [ "${SSL_LIBRARY}" = "libressl" ]; then ./autogen.sh; fi \
  && if [ "${SSL_LIBRARY}" = "libressl" ]; then CC=/usr/bin/clang CXX=/usr/bin/clang++ ./configure \
      --disable-shared \
      --disable-tests \
      --enable-static; fi \
  && if [ "${SSL_LIBRARY}" = "libressl" ]; then make -j$(getconf _NPROCESSORS_ONLN) install; fi \
#
# Compile LUA
#
  && cd /usr/src/lua \
  && make CC=clang -j "$(getconf _NPROCESSORS_ONLN)" linux \
#
# Compile libslz
#
  && cd /usr/src/libslz \
  && make CC=clang static
#
# Compile HAProxy
#
RUN  cd /usr/src/haproxy \
  && make -j "$(getconf _NPROCESSORS_ONLN)" \
       TARGET=linux-musl \
       CPU=generic \
       CC=clang \
       CXX=clang \
#		CFLAGS="-static -Wno-unused-function -Wno-sign-compare -Wno-unused-parameter -Wno-address-of-packed-member -Wno-missing-field-initializers -Wno-unused-label" \
#		LDFLAGS="-static" \
       LUA_INC=/usr/src/lua/src \
       LUA_LIB=/usr/src/lua/src \
       SLZ_INC=/usrc/src/libslz/src \
       SLZ_LIB=/usr/src/libslz \
       USE_ACCEPT4=1 \
       USE_CPU_AFFINITY=1 \
       USE_DL=1 \
       USE_EPOLL=1 \
       USE_FUTEX=1 \
       USE_GETADDRINFO=1 \
       USE_LIBCRYPT=1 \
       USE_LINUX_SPLICE=1 \
       USE_LINUX_TPROXY=1 \
       USE_LUA=1 \
       USE_NETFILTER=1 \
       USE_NS=1 \
       USE_OPENSSL=1 \
       USE_PCRE2_JIT=1 \
       USE_PCRE2=1 \
       USE_POLL=1 \
       USE_PRCTL=1 \
       USE_QUIC=1 && \
       USE_REGPARM=1 \
       USE_SLZ=1 \
       USE_STATIC_PCRE2=1 \
       USE_TFO=1 \
       USE_THREAD=1 \
       USE_TPROXY=1 \
       USE_VSYSCALL=1 \
       USE_ZLIB=0 \
       SUBVERS="lua-${LUA_VERSION} libslz-${LIBSLZ_TAG}" \
  && make \
       PREFIX=/usr \
       install-bin && \
     strip /usr/sbin/haproxy
