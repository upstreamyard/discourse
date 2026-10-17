# Container image for Discourse (https://github.com/discourse/discourse)
# Maintained by upstreamyard. Builds the Discourse source code, checked out into ./upstream
# at the release tag selected by CI.
#
# Runtime libraries (Ruby, ImageMagick, libvips, oxipng, jemalloc, PostgreSQL client) come
# from Discourse's own base image. CI passes the base tag that Discourse's launcher uses
# at build time (templates/web.template.yml in discourse/discourse_docker).

ARG DISCOURSE_BASE=discourse/base:2.0.20260915-0028-runtime-deps
ARG NODE_IMAGE=node:22-trixie-slim

FROM ${NODE_IMAGE} AS node

FROM ${DISCOURSE_BASE} AS base

RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --home-dir /home/app --create-home --shell /usr/sbin/nologin app && \
    install -d -o app -g app /var/www/discourse

ENV RAILS_ENV=production \
    HOME=/home/app

WORKDIR /var/www/discourse

# -----------------------------
# Builder: gems, JS packages, precompiled assets
# -----------------------------
FROM base AS builder

# Same gem build dependencies as Discourse's own build image
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    make cmake g++ pkg-config patch libtool \
    libxslt-dev libcurl4-openssl-dev libssl-dev libyaml-dev libxml2-dev libreadline-dev libunwind-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY --chown=app:app upstream/ ./
# pnpm version pinned by Discourse's package.json ("packageManager")
RUN npm install -g "$(node -p "require('./package.json').packageManager")"

USER app

RUN bundle config set --local deployment true && \
    bundle config set --local path vendor/bundle && \
    bundle config set --local without 'test development' && \
    bundle install --jobs "$(nproc)" --retry 3 && \
    find vendor/bundle -name cache -not -path '*/gems/*' -type d -exec rm -rf {} + && \
    find vendor/bundle -name tmp -type d -exec rm -rf {} +

RUN CI=1 pnpm install --frozen-lockfile

# Ember build, Sprockets assets, compressed JS. CSS needs the database and is compiled
# on first request (or by the `precompile-css` command).
RUN SKIP_DB_AND_REDIS=1 bundle exec rake assets:precompile

# Discourse reads its version from git; keep it after .git is dropped (as Discourse's slim image does)
RUN printf '{"git_version":"%s","full_version":"%s","git_branch":"%s"}' \
      "$(git rev-parse HEAD)" "$(git describe --tags --match 'v[0-9]*' 2>/dev/null || true)" "" \
      > config/git-utils-overrides.json && \
    rm -rf .git && \
    find vendor/bundle -name libv8_monolith.a -delete && \
    mkdir -p tmp/pids tmp/sockets public/uploads public/backups log

# -----------------------------
# Runtime
# -----------------------------
FROM base AS final

ARG DISCOURSE_VERSION=unknown

USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder --chown=app:app /var/www/discourse /var/www/discourse
COPY --chown=root:root --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# rake, rails, discourse: run in the app directory with its gems, also via docker/kubectl exec;
# healthcheck, sidekiq-alive: health checks for the web and sidekiq commands
COPY --chown=root:root --chmod=0755 bin/ /usr/local/bin/
COPY upstream/LICENSE.txt upstream/COPYRIGHT.md /licenses/discourse/

# Defaults from Discourse's own web template, adapted to one process per container:
# the app server listens on 3000 and serves static assets itself (no nginx in the image).
ENV RAILS_LOG_TO_STDOUT=1 \
    UNICORN_BIND_ALL=true \
    UNICORN_PORT=3000 \
    UNICORN_WORKERS=3 \
    UNICORN_SIDEKIQS=1 \
    DISCOURSE_SERVE_STATIC_ASSETS=true \
    MIGRATE_ON_BOOT=1 \
    RUBY_GC_HEAP_GROWTH_MAX_SLOTS=40000 \
    RUBY_GC_HEAP_INIT_SLOTS=400000 \
    RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=1.5 \
    RUBY_GC_HEAP_FREE_SLOTS_MIN_RATIO=0.11 \
    RUBY_GC_HEAP_FREE_SLOTS_GOAL_RATIO=0.22

LABEL org.opencontainers.image.title="discourse" \
      org.opencontainers.image.description="Discourse community forum, one process per container. Community image by upstreamyard." \
      org.opencontainers.image.version="${DISCOURSE_VERSION}" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.vendor="upstreamyard" \
      org.opencontainers.image.url="https://github.com/upstreamyard/discourse" \
      org.opencontainers.image.documentation="https://github.com/upstreamyard/discourse#readme"

EXPOSE 3000

VOLUME ["/var/www/discourse/public/uploads", "/var/www/discourse/public/backups"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD ["healthcheck"]

USER 10001:10001

ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
CMD ["web"]
