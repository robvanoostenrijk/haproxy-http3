VERSION 0.6

clean:
	LOCALLY
	RUN rm -f -R ./dist

build:
	ARG --required SSL_LIBRARY
	FROM DOCKERFILE . --SSL_LIBRARY=$SSL_LIBRARY

package:
	ARG --required SSL_LIBRARY
	FROM +build --SSL_LIBRARY=$SSL_LIBRARY

	RUN set -x \
&&		mkdir -p /tmp/dist \
&&		tar -C /usr/sbin -zcvf /tmp/dist/haproxy.tar.gz haproxy

	SAVE ARTIFACT /tmp/dist/haproxy.tar.gz AS LOCAL ./dist/haproxy.tar.gz

all:
	ARG SSL_LIBRARY=openssl

	BUILD +clean
	BUILD +package --SSL_LIBRARY=$SSL_LIBRARY
