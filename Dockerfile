FROM php:8.0-fpm-alpine

# persistent dependencies
RUN set -eux; \
	apk add --no-cache \
# in theory, docker-entrypoint.sh is POSIX-compliant, but priority is a working, consistent image
		bash \
# BusyBox sed is not sufficient for some of our sed expressions
		sed \
# Ghostscript is required for rendering PDF previews
		ghostscript \
# Alpine package for "imagemagick" contains ~120 .so files, see: https://github.com/docker-library/wordpress/pull/497
		imagemagick \
	;

# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN set -ex; \
	\
	apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		freetype-dev \
		imagemagick-dev \
		libjpeg-turbo-dev \
		libpng-dev \
		libzip-dev \
	; \
	\
	docker-php-ext-configure gd \
		--with-freetype \
		--with-jpeg \
	; \
	docker-php-ext-install -j "$(nproc)" \
		bcmath \
		exif \
		gd \
		mysqli \
		zip \
	; \
	pecl install imagick-3.4.4; \
	docker-php-ext-enable imagick; \
	rm -r /tmp/pear; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-network --virtual .wordpress-phpexts-rundeps $runDeps; \
	apk del --no-network .build-deps

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
	docker-php-ext-enable opcache; \
	{ \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

ENV WP_CLI_URL=https://github.com/wp-cli/wp-cli/releases/download/v2.4.0/wp-cli-2.4.0.phar
ENV WP_CLI_MD5=dedd5a662b80cda66e9e25d44c23b25c

RUN { \
  set -e ; \
  sed -iEe '/^www-data:/{s,/sbin/nologin,/bin/sh,}' /etc/passwd* ; \
  mkdir /usr/local/share/wp-cli/ ; \
  curl -L -o /usr/local/share/wp-cli/wp-cli.phar "${WP_CLI_URL}" ; \
  if [[ "$(md5sum /usr/local/share/wp-cli/wp-cli.phar | cut -b0-32)" != ${WP_CLI_MD5} ]]; then \
    echo -e '\n\n' ; \
    echo '*** *** *** *** *** *** *** *** ***' ; \
    echo 'wp-cli.phar integrity check failed!' ; \
    echo '*** *** *** *** *** *** *** *** ***' ; \
    echo -e '\n\n' ; \
    exit 1 ; \
  fi ; \
  apk add --no-cache sudo less ; \
  echo 'export PAGER="less -R"' >/home/www-data/.profile; \
  echo 'export WP_CLI_CACHE_DIR=/tmp/wp-cli-cache' >>/home/www-data/.profile; \
  echo -e '#!/bin/sh\nsudo -u www-data -i -- php /usr/local/share/wp-cli/wp-cli.phar --path=/var/www/html "$@"' >/usr/local/bin/wp ; \
  chmod 755 /usr/local/bin/wp ; \
}
