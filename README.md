# Discourse container image

Multi-arch (`amd64`, `arm64`), signed container images for [Discourse](https://github.com/discourse/discourse), the open-source community forum, built to run like any other app container: one process per container, configured by environment variables, with external PostgreSQL and Redis. Made for Kubernetes and Docker Compose.

> Community-maintained by **upstreamyard**. This is not an official Discourse image. Discourse is © Civilized Discourse Construction Kit, Inc. and licensed under GPL-2.0-or-later (license text and copyright notice in `/licenses/discourse/` inside the image); "Discourse" is a registered trademark of Civilized Discourse Construction Kit, Inc.

| Registry | Image |
|---|---|
| Docker Hub | `upstreamyard/discourse` |
| GitHub Container Registry | `ghcr.io/upstreamyard/discourse` |

**Tags:** `latest`, `<year>.<month>` (e.g. `2026.9`), `<version>` (e.g. `2026.9.0`, matching the [Discourse release tags](https://github.com/discourse/discourse/tags)). New Discourse releases are built automatically within 24 hours.

## At a glance

| | |
|---|---|
| Port | `3000` (HTTP; put your ingress or reverse proxy in front for TLS) |
| Probe | `GET /srv/status` returns `ok` (use it for liveness and readiness) |
| Requires | PostgreSQL 18 **with the pgvector extension**, e.g. `pgvector/pgvector:pg18`, and Redis 7 |
| Runs as | non-root UID `10001` |
| Processes | `web` (default; also runs Sidekiq unless `UNICORN_SIDEKIQS=0`), `sidekiq`, `migrate` |
| Migrations | on startup by default (`MIGRATE_ON_BOOT=1`), or as a one-off `migrate` container |
| Data | uploads in `/var/www/discourse/public/uploads`, backups in `/var/www/discourse/public/backups` |
| Plugins | the plugins bundled with Discourse (chat, AI, solved, reactions, …) |
| First admin | `rake admin:create` (see below) |

**AI agents and coding assistants:** read [`AGENTS.md`](https://github.com/upstreamyard/discourse/blob/main/AGENTS.md) for deployment rules, and [`llms.txt`](https://github.com/upstreamyard/discourse/blob/main/llms.txt) for an index of all docs.

## Quick start

```bash
curl -O https://raw.githubusercontent.com/upstreamyard/discourse/main/docker-compose.yml
cat > .env <<EOF
DISCOURSE_HOSTNAME=forum.example.com
DISCOURSE_SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
EOF
docker compose up -d
curl http://localhost:3000/srv/status
```

The first start runs the database migrations, which takes about half a minute on an empty database. Then create the first admin account:

```bash
docker compose exec discourse rake admin:create
```

Open `http://localhost:3000` (or your hostname behind your proxy) and log in. Discourse sends sign-up and notification emails, so configure SMTP (below) before you invite anyone.

Or with plain `docker run`, against your own PostgreSQL and Redis:

```bash
docker run -d -p 3000:3000 \
  -e DISCOURSE_HOSTNAME=forum.example.com \
  -e DISCOURSE_DB_HOST=your-postgres -e DISCOURSE_DB_PASSWORD=... \
  -e DISCOURSE_REDIS_HOST=your-redis \
  -e DISCOURSE_SECRET_KEY_BASE=$(openssl rand -hex 64) \
  -v discourse_uploads:/var/www/discourse/public/uploads \
  -v discourse_backups:/var/www/discourse/public/backups \
  upstreamyard/discourse:latest
```

## Configuration

Discourse reads every setting from [`config/discourse_defaults.conf`](https://github.com/discourse/discourse/blob/main/config/discourse_defaults.conf) as an environment variable: `DISCOURSE_` plus the setting name in upper case (`db_host` becomes `DISCOURSE_DB_HOST`). Forum settings (title, login options, categories, …) live in the database and are changed in the admin UI.

| Variable | Default | Notes |
|---|---|---|
| `DISCOURSE_HOSTNAME` | `www.example.com` | Public hostname, used in links and emails |
| `DISCOURSE_DB_HOST`, `DISCOURSE_DB_PORT` | – , `5432` | **Required.** PostgreSQL 18 with pgvector |
| `DISCOURSE_DB_NAME`, `DISCOURSE_DB_USERNAME`, `DISCOURSE_DB_PASSWORD` | `discourse`, `discourse`, – | |
| `DISCOURSE_REDIS_HOST`, `DISCOURSE_REDIS_PORT`, `DISCOURSE_REDIS_PASSWORD` | – , `6379`, – | **Required.** Redis 7. Enable persistence and don't let Redis evict keys |
| `DISCOURSE_SECRET_KEY_BASE` | generated and kept in Redis | Set it (`openssl rand -hex 64`) so sessions survive a Redis reset |
| `DISCOURSE_DEVELOPER_EMAILS` | – | Discourse makes accounts with these emails admins when they sign up (needs working email; our tests use `rake admin:create`) |
| `DISCOURSE_SMTP_ADDRESS`, `DISCOURSE_SMTP_PORT`, `DISCOURSE_SMTP_USER_NAME`, `DISCOURSE_SMTP_PASSWORD` | – , `25`, – , – | Outgoing mail. `DISCOURSE_SMTP_ENABLE_START_TLS` defaults to `true` |
| `DISCOURSE_NOTIFICATION_EMAIL` | `noreply@unconfigured.discourse.org` | Sender address; set it to an address your SMTP server may send from |
| `DISCOURSE_CDN_URL` | – | Optional CDN for assets and uploads |

Settings of this image:

| Variable | Default | Notes |
|---|---|---|
| `MIGRATE_ON_BOOT` | `1` | Run `db:migrate` before the web server starts. Concurrent runs are safe (advisory locks); set `0` when a `migrate` job does it |
| `UNICORN_WORKERS` | `3` | Web worker processes (the app server is Pitchfork; the variable keeps Discourse's name) |
| `UNICORN_SIDEKIQS` | `1` | Sidekiq processes supervised by `web`. Set `0` when you run a separate `sidekiq` container |
| `DISCOURSE_SIDEKIQ_WORKERS` | `5` | Threads per Sidekiq process |
| `DISCOURSE_SERVE_STATIC_ASSETS` | `true` | The app serves its own assets, since there's no nginx in the image |

### Commands

The container's command selects the process:

| Command | Does |
|---|---|
| `web` (default) | Migrations (if `MIGRATE_ON_BOOT=1`), then the web server on port 3000, plus `UNICORN_SIDEKIQS` Sidekiq processes |
| `sidekiq` | Standalone Sidekiq: background jobs (emails, notifications, …) and scheduled tasks |
| `migrate` | Run the database migrations and exit |
| `precompile-css` | Compile the CSS of all themes and exit. Optional: CSS is otherwise compiled on its first request |
| `rake …`, `rails …`, `discourse …` | Discourse's admin commands, e.g. `rake admin:create`, `discourse backup`, `rails runner '…'` |

`rake`, `rails` and `discourse` also work with `docker exec` and `kubectl exec`.

### Storage

Uploads and backups are written to the two volumes above. Mount them on persistent storage, and when you run more than one web container, use a shared (ReadWriteMany) volume for uploads or store uploads in S3-compatible object storage. Discourse's guide covers [S3-compatible storage for uploads](https://meta.discourse.org/t/configure-an-s3-compatible-object-storage-provider-for-uploads/148916); we haven't tested that path with this image yet.

### Plugins

The image contains the plugins that ship with Discourse (46 in 2026.9, including chat, Discourse AI, solved, reactions, templates and topic voting); enable them in the admin UI. Installing third-party plugins is not supported by this image yet.

## Kubernetes

The recommended way is the Helm chart ([`upstreamyard/helm-charts`](https://github.com/upstreamyard/helm-charts/tree/main/charts/discourse)):

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install discourse upstreamyard/discourse --set discourse.hostname=forum.example.com
```

Running it yourself:

1. Run migrations once per release as a Job with the `migrate` command, and set `MIGRATE_ON_BOOT=0` on the web pods.
2. Run web pods with `UNICORN_SIDEKIQS=0` and a separate `sidekiq` Deployment, so web and background jobs scale independently.
3. Probe `GET /srv/status` on port 3000 for liveness, readiness and startup.
4. Give the pods a shared uploads volume (or S3), and the same `DISCOURSE_SECRET_KEY_BASE`.

Stopping is graceful: on `SIGTERM` the web server finishes requests in flight before it exits. The container runs as non-root UID `10001` and is compatible with `runAsNonRoot: true`; it needs a writable root filesystem.

## Verifying images

Images are signed keylessly with [cosign](https://github.com/sigstore/cosign) and include an SBOM and SLSA provenance:

```bash
cosign verify upstreamyard/discourse:latest \
  --certificate-identity-regexp '^https://github.com/upstreamyard/discourse/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect upstreamyard/discourse:latest --format '{{ json .SBOM }}'
```

## How it's built

[`.github/workflows/build.yml`](https://github.com/upstreamyard/discourse/blob/main/.github/workflows/build.yml) checks out the Discourse release tag and builds [`Dockerfile`](https://github.com/upstreamyard/discourse/blob/main/Dockerfile) natively on amd64 and arm64 runners. Before publishing, [`scripts/smoke-test.sh`](https://github.com/upstreamyard/discourse/blob/main/scripts/smoke-test.sh) starts each image against PostgreSQL with pgvector and Redis, creates an admin, loads the app's CSS and JavaScript, and creates a topic through the API. Everything is public and reproducible.

- **Runtime libraries** (Ruby, ImageMagick, libvips, oxipng, jemalloc, PostgreSQL client) come from Discourse's own `discourse/base` runtime image, at the tag Discourse's launcher uses.
- **Frontend:** Discourse's build downloads the prebuilt JavaScript bundle that Discourse publishes for each release, and the rest of the assets are precompiled in the image.
- **Differences from Discourse's own image:** one process per container instead of nginx, the app server and Sidekiq under runit; no launcher or rebuild step; runs as non-root; Sidekiq can run separately; graceful shutdown on `SIGTERM`; `tini` as PID 1 and a built-in `HEALTHCHECK`.

## Support

Issues with the image: [open an issue here](https://github.com/upstreamyard/discourse/issues). Questions about using Discourse: [meta.discourse.org](https://meta.discourse.org).
