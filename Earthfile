VERSION 0.6

clean:
	LOCALLY
	RUN rm -f -R ./dist

build:
	ARG --required SSL_LIBRARY
	FROM DOCKERFILE . --SSL_LIBRARY=$SSL_LIBRARY
	SAVE ARTIFACT /usr/sbin/haproxy

package:
	ARG --required PLATFORM
	ARG --required SSL_LIBRARY
	LOCALLY
	COPY +build/haproxy dist/haproxy
	RUN XZ_OPT=-9 tar -C dist -Jcvf dist/haproxy-http3-${SSL_LIBRARY}-${PLATFORM}.tar.xz haproxy \
	 && rm dist/haproxy

all:
	ARG SSL_LIBRARY=openssl

	BUILD +clean
	BUILD --platform=linux/amd64 +package --PLATFORM=amd64 --SSL_LIBRARY=$SSL_LIBRARY
	BUILD --platform=linux/arm64 +package --PLATFORM=arm64 --SSL_LIBRARY=$SSL_LIBRARY
