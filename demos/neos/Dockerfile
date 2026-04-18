# NOTE: this file is executed from the demos/neos/ directory
#
# We follow: https://frankenphp.dev/docs/docker/#how-to-install-more-caddy-modules
# to build FrankenPHP with the cbrotli module for Brotli compression.
FROM dunglas/frankenphp:1.9.1-builder-php8.4-trixie AS builder

# Copy xcaddy in the builder image
COPY --from=caddy:2.10.2-builder /usr/bin/xcaddy /usr/bin/xcaddy

# CGO must be enabled to build FrankenPHP
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=1 \
    XCADDY_SETCAP=1 \
    XCADDY_GO_BUILD_FLAGS="-ldflags='-w -s' -tags=nobadger,nomysql,nopgx" \
    CGO_CFLAGS=$(php-config --includes) \
    CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
    GOMODCACHE=/go/pkg/mod \
    GOCACHE=/root/.cache/go-build \
    xcaddy build v2.10.2 \
        --output /usr/local/bin/frankenphp \
        --with github.com/dunglas/frankenphp=./ \
        --with github.com/dunglas/frankenphp/caddy=./caddy/ \
        --with github.com/dunglas/caddy-cbrotli

################# Production image ##################################

FROM dunglas/frankenphp:1.9.1-php8.4-trixie

# Replace the official binary with the one containing cbrotli
COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp

# Install PHP extensions (simplified from neos-on-docker-kickstart — no vips, xsl, ffi, excimer)
RUN install-php-extensions \
    intl \
    bcmath \
    opcache \
    pdo \
    pdo_mysql \
    gd \
    redis

RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Run as www-data
ARG USER=www-data
RUN \
    useradd ${USER}; \
    chown -R ${USER}:${USER} /config/caddy /data/caddy && \
    touch /var/run/caretakerd.key && chown ${USER}:${USER} /var/run/caretakerd.key

# Copy deployment files (directory structure maps to filesystem paths)
ADD deployment/neos-root/ /

COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# Install caretakerd (process manager)
ARG TARGETARCH
RUN curl -SL "https://caretakerd.echocat.org/latest/download/caretakerd-linux-${TARGETARCH}.tar.gz" \
    | tar -xz --exclude caretakerd.html -C /usr/bin

# Copy application and install dependencies
ADD ./app /app
RUN --mount=type=cache,target=/root/.composer \
    composer install --working-dir /app/ --no-interaction --optimize-autoloader --no-dev

# Writable directories for Neos data and published resources
RUN mkdir -p /app/Data /app/Web/_Resources && \
    chown -R ${USER} /app/Data /app/Web/_Resources

WORKDIR /app
USER ${USER}

ENTRYPOINT ["/entrypoint.sh"]
