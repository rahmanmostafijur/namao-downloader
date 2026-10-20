# Deployment

## What you need

| | Minimum | Notes |
|---|---|---|
| Host | Linux x86-64 or arm64 with Docker + Compose v2 | Windows/macOS Docker Desktop works for testing. |
| CPU / RAM | 2 vCPU / 2 GB | Each running job can use a core while merging. Start at `NAMAO_WORKER_CONCURRENCY=2`. |
| Disk | 10 GB free for the volume | Finished files live for `NAMAO_RETENTION_SECONDS` (1 h); caps below. |
| Network | Outbound HTTPS to the platforms | Inbound only if you publish it. |
| Not free of hosting limits | | A host that cannot run Docker/long-running processes (typical shared PHP/"serverless" hosting) cannot run Namao: use a VPS, a home server or your own machine, or the desktop app. |

All software is free and open source; the only recurring cost is the machine and its bandwidth. Rough sizing: each
download moves the media size in (from the platform) **and** out (to the client), so a 100 MB video costs about
200 MB of traffic on a metered host; CPU and disk are only used while jobs run. There is no paid downloading API.

## Quick start (single host)

```bash
cp .env.example .env            # review the limits; optional
docker compose up -d --build
docker compose ps               # api and worker become "healthy"
curl -s http://127.0.0.1:8000/health/ready
```

Open `http://127.0.0.1:8000`. The image (~290 MB) contains Python 3.12, the pinned yt-dlp + yt-dlp-ejs, Deno 2.9.7
(SHA-256 verified at build time), FFmpeg/FFprobe, and runs as a non-root user with a read-only root filesystem.
The **api** and **worker** containers share one volume (`/data`: `namao.db` + job files). Both must run on the *same
host* (SQLite over a shared local volume); for several hosts replace `JobStore` with Postgres.

`/health/ready` must return `200` with `ready`; otherwise its `checks`/`problems` say which dependency is missing.

## Public deployment with TLS

```bash
# .env
NAMAO_DOMAIN=downloads.example.com
NAMAO_TRUST_PROXY=1
NAMAO_TRUSTED_PROXIES=1
NAMAO_API_KEY=<long random value>      # optional; the bundled web UI sends none: prefer proxy-level auth if you use this
docker compose --profile public up -d
```

Caddy obtains and renews certificates, disables buffering for the progress stream, hides `/health/ready`, and
appends the real client address. The Caddyfile passes `caddy validate`; its live behaviour (certificates, SSE, forwarded
headers) was **not** exercised here. Without `NAMAO_TRUST_PROXY` every request looks like it comes from the proxy. An
**empty** `NAMAO_API_KEY` is rejected at startup rather than silently disabling auth.

For a public service also: restrict the worker's outbound traffic to the public internet (block private ranges and
cloud metadata addresses; see *Residual risks* in [architecture.md](architecture.md)), keep `NAMAO_EXPOSE_*` off, and
read the platforms' terms first. Rate limits and quotas (`NAMAO_RATE_LIMIT_PER_MINUTE`, `NAMAO_MAX_OPEN_JOBS_PER_CLIENT`,
`NAMAO_MAX_QUEUE_LENGTH`) protect a small host; they are not a substitute for network controls.

## Limits and resource protection

Everything is configurable in `.env` (every variable is documented in [.env.example](../.env.example)):

| Concern | Variable (default) |
|---|---|
| Workers | `NAMAO_WORKER_CONCURRENCY` (2) |
| Job time / retries | `NAMAO_JOB_TIMEOUT_SECONDS` (1800), `NAMAO_MAX_ATTEMPTS` (3) |
| Per-job size / length | `NAMAO_MAX_OUTPUT_MB` (2048), `NAMAO_MAX_DURATION_SECONDS` (14400) |
| Disk | `NAMAO_MIN_FREE_MB` (1024), `NAMAO_MAX_STORAGE_MB` (20480) |
| Retention | `NAMAO_RETENTION_SECONDS` (3600) and a sweep every 60 s; orphaned job folders are removed after an hour |
| Queue | `NAMAO_MAX_QUEUE_LENGTH` (50), `NAMAO_MAX_OPEN_JOBS_PER_CLIENT` (5) |

Monitoring: `GET /health/ready` (engine version/channel/age, FFmpeg, FFprobe, JS runtime, EJS, database, free disk,
worker heartbeat) and structured JSON logs on stderr (`job.start`, `job.completed`, `job.failed` with the failure
code, `job.retry_scheduled`, `cleanup.sweep`, `worker.reaped`). `python -m namao.ops status` prints job/worker counts.

## Updating and rolling back

See *Release management* in [download-reliability.md](download-reliability.md): drain → rebuild → resume, and
`scripts/engine_update.py rollback`. **Never** swap dependencies under running jobs.

Stopping the worker (`docker compose stop worker`, up to 45 s grace) marks its running jobs `interrupted` and deletes
their partial files; clients see the state and can start again.

## Without Docker (development or a bare host)

```bash
python -m venv venv && venv/bin/pip install -r requirements.txt      # Windows: venv\Scripts\...
# install FFmpeg + FFprobe, and Deno >= 2.3 (or Node >= 22), onto PATH
NAMAO_EMBEDDED_WORKER=1 venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
# or two processes:  uvicorn main:app   and   python -m namao.worker
```

## Desktop app

`pyinstaller Namao.spec` (from a venv with `requirements-desktop.txt`) builds `dist/Namao[.exe]` **on the OS you
target**. Optional: put `ffmpeg`, `ffprobe` and `deno` (official releases, checksums verified by you) into
`desktop-bin/` first and they are bundled and preferred over `PATH`. `Namao --check` prints the dependency
diagnostics. Data lives in `%LOCALAPPDATA%\Namao`, `~/Library/Application Support/Namao` or `~/.local/share/Namao`, including a
random `desktop-token`: the launcher opens the browser with it once and the server turns it into a cookie, so other
user accounts on the same machine cannot use your instance.

Build status: **Windows built and run end to end** on this branch (frozen yt-dlp + EJS + FFmpeg downloaded and
merged a real stream; the desktop endpoints enforced their guards). **macOS and Linux builds are defined in
`.github/workflows/ci.yml` but have not been run.** The executables are unsigned: expect SmartScreen/Gatekeeper
warnings until you sign them.

## Mobile

See [../mobile/README.md](../mobile/README.md). The app needs a reachable server (https, or http on a local network).
Store publication is not done and needs your developer accounts, signing and review.

## Troubleshooting

| Symptom | Check |
|---|---|
| `/health/ready` is 503 | Read `checks`/`problems`. `worker.ok=false`: the worker container isn't running. `js_runtime`: Deno missing. |
| Jobs fail `access_blocked` / `source_rate_limited` | The platform is throttling this address. Wait, lower concurrency, use another egress. Updating will not help. |
| Jobs fail `engine_outdated` | yt-dlp older than `NAMAO_ENGINE_STALE_DAYS`: run the update procedure. |
| `storage_full` | `docker compose exec api python -m namao.ops status`; shorten retention; raise `NAMAO_MAX_STORAGE_MB`. |
| Jobs stay `queued` | No worker alive (`/health/ready`), or drain mode is on (`ops status` shows `draining`; `ops resume`). |
| Web UI loads but nothing works behind a proxy | Proxy buffering SSE (the UI falls back to polling), or `NAMAO_TRUST_PROXY` wrong so everyone shares one rate-limit bucket. |
