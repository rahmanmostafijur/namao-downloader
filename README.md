# নামাও (Namao)

A self-hosted video downloader for YouTube, Facebook, TikTok, X (Twitter) and Instagram. Paste a link, pick a quality
the source really offers, watch real progress, save the file. Extraction is done by
[yt-dlp](https://github.com/yt-dlp/yt-dlp), merging and verification by FFmpeg/FFprobe. No paid downloading API.

One server, one API (`/api/v1/downloads/*`), three kinds of client:

| Client | Where | Notes |
|---|---|---|
| Web | `static/` | Served by the server itself. |
| Desktop (Windows / macOS / Linux) | `launcher.py`, `Namao.spec` | One-file app with the worker built in; saves to a folder you choose. Windows build verified; macOS/Linux built in CI only. |
| Mobile (iOS / Android) | `mobile/` | Expo app that controls your server and saves the result to the phone. Native builds not verified here. |

The older standalone Android app in `android/` is unchanged (it embeds its own engine); see
[docs/architecture.md](docs/architecture.md) for why the server-backed app is the supported path.

## Run it

**Docker (recommended)**

```bash
cp .env.example .env        # optional: review limits
docker compose up -d --build
curl -s http://127.0.0.1:8000/health/ready     # 200 + "ready" when yt-dlp, EJS, Deno, FFmpeg, DB and worker are fine
```

Open <http://127.0.0.1:8000>. Details, TLS and limits: [docs/deployment.md](docs/deployment.md).

**From source (Windows PowerShell shown)**

```powershell
python -m venv venv
venv\Scripts\pip install -r requirements.txt
# FFmpeg + FFprobe and Deno (or Node >= 22) must be on PATH
$env:NAMAO_EMBEDDED_WORKER = "1"
venv\Scripts\uvicorn main:app
```

**Desktop app**: `pip install -r requirements-desktop.txt; pyinstaller Namao.spec` → `dist\Namao.exe` (`--check` prints
diagnostics). See [docs/deployment.md](docs/deployment.md#desktop-app).

## What changed in 2.0

The old single-file app downloaded inside the HTTP request, with an unpinned yt-dlp and no checks. YouTube downloads
failed with HTTP 403 on its stale yt-dlp. Now: a pinned and *verified* dependency chain, an engine interface, durable
background jobs with real progress/cancel/retry, normalized failure codes, SSRF and input hardening, Docker, an update
and rollback procedure, and 362 + 16 + 17 automated tests (Python + web + mobile). Read the evidence in [docs/upgrade-audit.md](docs/upgrade-audit.md).

## Documentation

| | |
|---|---|
| [docs/upgrade-audit.md](docs/upgrade-audit.md) | What was wrong, with evidence, and what was changed. |
| [docs/architecture.md](docs/architecture.md) | Components, job lifecycle, API, security model, decisions, residual risks. |
| [docs/download-reliability.md](docs/download-reliability.md) | Dependency chain, failure codes, release management, upstream-change runbook. |
| [docs/deployment.md](docs/deployment.md) | Hosting, limits, TLS, updating, rollback, desktop, troubleshooting, costs. |
| [docs/testing.md](docs/testing.md) | How to run everything and what was actually run. |
| [docs/openapi.json](docs/openapi.json) | The API schema (generated; a test keeps it current). |
| [mobile/README.md](mobile/README.md) | The mobile client and its verification status. |

## Honest limits

* Platforms can throttle or bot-check a server's address (observed during this work). Namao reports it as
  `access_blocked` / `source_rate_limited`; updating or retrying does not overcome it, and Namao does not try to evade it.
* Single, public, non-live videos only. No DRM, login, cookie or CAPTCHA workarounds.
* Facebook, TikTok and Instagram extraction is enabled but was not exercised with real downloads (no rights-cleared test
  assets; these platforms often require login).
* Personal, authorized use. Check each platform's terms before offering this to other people.
