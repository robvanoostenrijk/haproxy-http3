
#!/bin/sh

# Retrieve latest version number tag from a github repository
get_latest_tag()
{
	curl -s "https://api.github.com/repos/${1}/tags" | jq -r --arg v "${2}" 'first(.[] | select(.name | startswith($v))).name' | tr -d -c '0-9.'
}

# Generate versions.env (shell env format)
cat <<- EOF > versions.env
	AWS_LC_TAG=v$(get_latest_tag aws/aws-lc v)
	LIBRESSL_TAG=v$(get_latest_tag libressl/portable v)
	OPENSSL_TAG=openssl-$(get_latest_tag openssl/openssl openssl)
	WOLFSSL_TAG=v$(get_latest_tag wolfSSL/wolfssl v)
	LIBSLZ_TAG=v$(get_latest_tag wtarreau/libslz v)
	HAPROXY_VERSION=3.3.3
EOF
