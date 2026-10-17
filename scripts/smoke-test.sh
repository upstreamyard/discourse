#!/usr/bin/env bash
# Smoke test for the Discourse image: starts PostgreSQL (with pgvector) and Redis, runs the
# image with migrations on boot, then checks the health endpoint, the home page and CSS.
# Usage: scripts/smoke-test.sh <image>   (containers are left running for log inspection;
#        remove them with: docker rm -f discourse-smoke smoke-pg smoke-redis; docker network rm smoke)
set -euo pipefail

IMAGE=${1:?usage: $0 <image>}
PORT=${PORT:-3000}

docker network create smoke >/dev/null
docker run -d --name smoke-pg --network smoke \
  -e POSTGRES_USER=discourse -e POSTGRES_PASSWORD=discourse -e POSTGRES_DB=discourse \
  pgvector/pgvector:pg18 >/dev/null
docker run -d --name smoke-redis --network smoke redis:7-alpine >/dev/null
for _ in $(seq 1 30); do docker exec smoke-pg pg_isready -U discourse -d discourse >/dev/null 2>&1 && break; sleep 2; done

docker run -d --name discourse-smoke --network smoke -p "$PORT:3000" \
  -e DISCOURSE_HOSTNAME=localhost \
  -e DISCOURSE_DB_HOST=smoke-pg \
  -e DISCOURSE_DB_PASSWORD=discourse \
  -e DISCOURSE_REDIS_HOST=smoke-redis \
  -e DISCOURSE_DEVELOPER_EMAILS=admin@example.com \
  -e DISCOURSE_SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  "$IMAGE" >/dev/null

echo "Waiting for /srv/status (migrations run first, this takes a few minutes)"
for _ in $(seq 1 180); do
  if [ "$(curl -s "http://localhost:$PORT/srv/status" || true)" = "ok" ]; then break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' discourse-smoke)" != "true" ]; then
    echo "Container exited"; docker logs discourse-smoke 2>&1 | tail -50; exit 1
  fi
  sleep 5
done
[ "$(curl -s "http://localhost:$PORT/srv/status")" = "ok" ] || { echo "Not healthy"; exit 1; }
echo "Health endpoint ok"

# First admin, the way the README documents it (rake wrapper, answers on stdin)
printf 'admin@example.com\nSmoke-Test-Passw0rd-1\nSmoke-Test-Passw0rd-1\nY\n' \
  | docker exec -i discourse-smoke rake admin:create | grep -q "Admin privileges" \
  || { echo "rake admin:create failed"; exit 1; }
echo "Admin created"

# The full app page (browsers get the Ember app, curl's default agent gets the crawler view)
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36'
home=$(curl -sf -A "$UA" "http://localhost:$PORT/")

fetch_first() { # $1 = regex for the attribute value, prints http code of the first match
  local ref
  ref=$(grep -oE "$1" <<<"$home" | head -1 | sed -E 's/^(src|href)="//; s/"$//' || true)
  [ -n "$ref" ] || { echo "none"; return; }
  case "$ref" in http*) ;; *) ref="http://localhost:$PORT$ref" ;; esac
  curl -s -o /dev/null -w '%{http_code}' -A "$UA" "$ref"
}
code=$(fetch_first 'href="[^"]*/stylesheets/[^"]+\.css[^"]*"')
[ "$code" = "200" ] || { echo "Stylesheet: $code"; exit 1; }
echo "Stylesheet ok (compiled on first request)"
code=$(fetch_first 'src="[^"]*/assets/[^"]+\.js"')
[ "$code" = "200" ] || { echo "JS asset: $code"; exit 1; }
echo "JS asset ok"

# Write path: API key, topic with Markdown (rendered server-side), background jobs
key=$(docker exec discourse-smoke rails runner \
  'u = User.find_by_email("admin@example.com"); puts ApiKey.create!(user: u, created_by: u, description: "smoke").key' | tail -1)
username=$(docker exec discourse-smoke rails runner 'puts User.find_by_email("admin@example.com").username' | tail -1)
category=$(curl -s -H "Api-Key: $key" -H "Api-Username: $username" "http://localhost:$PORT/categories.json" \
  | jq '[.category_list.categories[] | select(.slug == "general")][0].id')
cooked=$(curl -s -H "Api-Key: $key" -H "Api-Username: $username" -X POST "http://localhost:$PORT/posts.json" \
  -F title="Smoke test topic created through the API" -F category="$category" \
  -F raw='This post checks **Markdown** rendering in the container image.' | jq -r .cooked)
grep -q "<strong>Markdown</strong>" <<<"$cooked" || { echo "Post creation failed: $cooked"; exit 1; }
echo "Topic created, Markdown rendered"

for _ in $(seq 1 30); do
  processed=$(docker exec discourse-smoke rails runner 'require "sidekiq/api"; puts Sidekiq::Stats.new.processed' | tail -1)
  [ "${processed:-0}" -gt 0 ] && break
  sleep 2
done
[ "${processed:-0}" -gt 0 ] || { echo "Sidekiq processed no jobs"; exit 1; }
echo "Sidekiq processed $processed jobs"

echo "Smoke test passed"
