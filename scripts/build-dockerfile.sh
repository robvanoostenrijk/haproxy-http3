#!/bin/bash
# Generate Dockerfile
source versions.env

cat Dockerfile.head > Dockerfile

cat << EOF >> Dockerfile

ARG AWS_LC_TAG=${AWS_LC_TAG} \\
	LIBRESSL_TAG=${LIBRESSL_TAG} \\
	OPENSSL_TAG=${OPENSSL_TAG} \\
	WOLFSSL_TAG=${WOLFSSL_TAG} \\
	LIBSLZ_TAG=${LIBSLZ_TAG} \\
	HAPROXY_VERSION=${HAPROXY_VERSION}
EOF

cat Dockerfile.body >> Dockerfile
