#!/bin/bash
# Entrypoint of the upstreamyard Discourse image.
#   web            app server (default); with UNICORN_SIDEKIQS>0 it also supervises Sidekiq
#   sidekiq        standalone Sidekiq (background jobs and scheduled tasks)
#   migrate        run database migrations and exit
#   precompile-css compile CSS for all themes and exit (otherwise compiled on first request)
#   anything else  executed as-is, e.g. `rake admin:create` or `discourse backup`
#                  (rake, rails and discourse are wrappers in /usr/local/bin)
set -euo pipefail

cd /var/www/discourse

# jemalloc, as in Discourse's own image
export LD_PRELOAD="${RUBY_ALLOCATOR:-/usr/lib/libjemalloc.so}${LD_PRELOAD:+:$LD_PRELOAD}"

require_settings() {
  local missing=()
  [ -n "${DISCOURSE_DB_HOST:-}${DISCOURSE_DB_SOCKET:-}" ] || missing+=(DISCOURSE_DB_HOST)
  [ -n "${DISCOURSE_REDIS_HOST:-}" ] || missing+=(DISCOURSE_REDIS_HOST)
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required environment variables: ${missing[*]}" >&2
    echo "See https://github.com/upstreamyard/discourse#configuration" >&2
    exit 1
  fi
}

migrate() {
  echo "Running database migrations"
  bundle exec bin/rake db:migrate
}

case "${1:-web}" in
  web)
    require_settings
    if [ "${MIGRATE_ON_BOOT:-1}" = "1" ]; then
      migrate
    fi
    # Pitchfork treats TERM as an immediate shutdown and QUIT as a graceful one (finish
    # in-flight requests). Containers are stopped with TERM, so translate it.
    bundle exec pitchfork -E production -c config/pitchfork.conf.rb &
    pid=$!
    trap 'kill -QUIT "$pid" 2>/dev/null' TERM INT
    set +e
    wait "$pid"; status=$?
    # wait returns early when a trapped signal arrives; wait again for the actual exit
    while kill -0 "$pid" 2>/dev/null; do wait "$pid"; status=$?; done
    exit "$status"
    ;;
  sidekiq)
    require_settings
    # Same queues and weights Discourse uses for its supervised Sidekiq processes
    exec bundle exec sidekiq \
      -c "${DISCOURSE_SIDEKIQ_WORKERS:-5}" -t 5 \
      -q critical,8 -q default,4 -q low,2 -q ultra_low,1
    ;;
  migrate)
    require_settings
    migrate
    ;;
  precompile-css)
    require_settings
    exec bundle exec bin/rake assets:precompile:css
    ;;
  *)
    exec "$@"
    ;;
esac
