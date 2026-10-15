# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or deploying the image it publishes.

## Image facts

| Key | Value |
|---|---|
| Image | `upstreamyard/discourse` (Docker Hub), `ghcr.io/upstreamyard/discourse` |
| Tags | `<version>` (e.g. `2026.9.0`), `<year>.<month>` (e.g. `2026.9`), `latest` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Port | `3000` (HTTP, no TLS) |
| Probes | web: `GET /srv/status` returns `ok` (liveness, readiness, startup); sidekiq: exec `sidekiq-alive` (Sidekiq heartbeat in Redis) |
| User | non-root, UID/GID `10001`; needs a writable root filesystem |
| Entrypoint | `tini -- docker-entrypoint.sh`, default command `web` |
| Commands | `web`, `sidekiq`, `migrate`, `precompile-css`; `rake`, `rails`, `discourse` (also via `docker exec` / `kubectl exec`) |
| Required dependencies | PostgreSQL 18 with the pgvector extension (e.g. `pgvector/pgvector:pg18`), Redis 7 |
| Volumes | `/var/www/discourse/public/uploads`, `/var/www/discourse/public/backups` |
| Config | environment variables `DISCOURSE_<SETTING>` for every setting in Discourse's `config/discourse_defaults.conf` |
| Discourse project | https://github.com/discourse/discourse (GPL-2.0-or-later) |

## Deploying the image

Rules that avoid the common failures:

- **Database:** PostgreSQL 18 with pgvector is required. On a server without pgvector, migrations abort with `extension "vector" is not available` (the bundled Discourse AI plugin needs it). Set `DISCOURSE_DB_HOST`, `DISCOURSE_DB_PASSWORD`, and `DISCOURSE_DB_NAME`/`DISCOURSE_DB_USERNAME` if they differ from `discourse`.
- **Redis:** set `DISCOURSE_REDIS_HOST` (and `DISCOURSE_REDIS_PASSWORD`). Use persistence and no key eviction (`maxmemory-policy noeviction`).
- **Required at startup:** `DISCOURSE_DB_HOST` and `DISCOURSE_REDIS_HOST`; the container exits with a clear message otherwise. Also set `DISCOURSE_HOSTNAME` (used in links and emails) and `DISCOURSE_SECRET_KEY_BASE` (`openssl rand -hex 64`), the same value on every pod.
- **Email:** `DISCOURSE_SMTP_ADDRESS`, `DISCOURSE_SMTP_PORT`, `DISCOURSE_SMTP_USER_NAME`, `DISCOURSE_SMTP_PASSWORD`, `DISCOURSE_NOTIFICATION_EMAIL`. Emails are sent by Sidekiq, so a Sidekiq process must run (built into `web` by default).
- **First admin:** `rake admin:create` in a running container (`docker compose exec discourse rake admin:create`, `kubectl exec -it deploy/discourse -- rake admin:create`). It asks for email, password and confirmation.
- **Single container:** the default `web` command runs migrations, the web server and one Sidekiq process. Nothing else is needed.
- **Separate processes (Kubernetes):** run `migrate` as a Job once per release (with `SKIP_POST_DEPLOYMENT_MIGRATIONS=1` before the rollout, and again without it afterwards for the post-deployment migrations), web pods with `MIGRATE_ON_BOOT=0` and `UNICORN_SIDEKIQS=0`, and a `sidekiq` Deployment. Scheduled tasks run inside Sidekiq.
- **More than one web pod:** uploads must be on a shared volume (ReadWriteMany) or in S3-compatible storage (not covered by our tests yet).
- **TLS:** the image serves plain HTTP on port 3000. Terminate TLS in front and pass `X-Forwarded-Proto`.
- **Plugins:** only the plugins bundled with Discourse are included. Third-party plugins are not supported by this image yet.
- **Shutdown:** `SIGTERM` is graceful for `web` (finishes requests in flight) and `sidekiq`.

Ready-to-use manifests:

- Docker Compose: [`docker-compose.yml`](docker-compose.yml) (needs a `.env`, see README)
- Kubernetes: Helm chart `upstreamyard/discourse` from `https://upstreamyard.github.io/helm-charts` (also `oci://ghcr.io/upstreamyard/charts/discourse`), documented in https://github.com/upstreamyard/helm-charts/tree/main/charts/discourse

Verify a deployment:

```bash
curl -sf http://HOST:3000/srv/status   # prints ok
```

## Working on this repository

Layout:

- `Dockerfile`: builds the Discourse source code, which CI checks out into `./upstream/` (git-ignored)
- `docker-entrypoint.sh`: the commands (`web`, `sidekiq`, `migrate`, `precompile-css`)
- `bin/`: `rake`, `rails`, `discourse` wrappers, and the `healthcheck` / `sidekiq-alive` checks, installed into `/usr/local/bin`
- `scripts/smoke-test.sh`: the test CI runs before publishing; run it locally too
- `.github/workflows/build.yml`: resolves the Discourse version and base image, builds and smoke-tests on native amd64 and arm64 runners, then pushes, creates the multi-arch tags, signs and syncs the Docker Hub README

Build and test locally:

```bash
git clone --depth 1 --branch v2026.9.0 https://github.com/discourse/discourse.git upstream
docker build -t discourse:dev --build-arg DISCOURSE_VERSION=2026.9.0 .
./scripts/smoke-test.sh discourse:dev
docker rm -f -v discourse-smoke smoke-pg smoke-redis && docker network rm smoke
```

The build needs about 15 GB of free disk space.

Rules:

- Never push to `main`. Create a branch and open a pull request into `main`.
- Do not modify the Discourse source code. Fix packaging problems in the `Dockerfile` or the entrypoint, and report Discourse bugs at https://meta.discourse.org.
- Keep `node_modules` in the image: Discourse reads files from it at runtime (asset-processor digest, highlight.js languages, moment locales).
- Keep the image non-root with UID `10001`, and keep `HEALTHCHECK` and the OCI labels.
- When the port, the probe, the commands or the required environment variables change, update `README.md`, this file and `llms.txt` in the same pull request.
- The workflow must pass `actionlint` (`docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest`).
- `README.md` is also the Docker Hub description, so keep it under 25,000 characters.
