# নামাও (Namao)

A self-hosted video downloader for YouTube, Facebook, TikTok, X (Twitter) and Instagram. Paste a link, pick a quality
the source really offers, watch real progress, save the file. Extraction is done by
[yt-dlp](https://github.com/yt-dlp/yt-dlp), merging and verification by FFmpeg/FFprobe. No paid downloading API.

## Download the Android app

[**Download Latest Android APK**](https://github.com/rahmanmostafijur/namao-downloader/releases/latest/download/namao-android.apk)
· [All releases and release notes](https://github.com/rahmanmostafijur/namao-downloader/releases)
· SHA-256: [`namao-android.apk.sha256`](https://github.com/rahmanmostafijur/namao-downloader/releases/latest/download/namao-android.apk.sha256)

**The app downloads on your phone.** There is no server to set up and nothing to configure: paste a link, pick a
quality, and the video is saved to `Download/Namao`. Everything it needs is inside the app, and it only needs an
internet connection to reach the video's site.

- **Requires Android 10 (API 29) or newer.**
- **Install:** open the downloaded `namao-android.apk` on your phone and allow *Install unknown apps* for your browser
  or file manager when Android asks. Then open **Namao** and paste a link. The first launch unpacks the downloader and
  fetches its latest site updates, so the first link can take longer than later ones.
- **Update:** install the newer `namao-android.apk` over the old one. History and settings are kept because every
  release is signed with the same key. Check the [releases page](https://github.com/rahmanmostafijur/namao-downloader/releases) for new versions; the app does not update itself.
- **Verify the download (recommended):** the SHA-256 is shown in each release's notes. On Windows run
  `certutil -hashfile namao-android.apk SHA256`; on Linux/macOS `sha256sum namao-android.apk`. The values must match.
  The signing certificate (`CN=Namao`) has the SHA-256 fingerprint
  `40:1F:F6:12:39:C7:48:0A:DB:91:6A:5A:94:D6:AC:23:E9:54:E5:12:47:A2:8A:CE:AC:14:94:9A:64:6F:46:C6`
  (check with `apksigner verify --print-certs namao-android.apk`).
- Tested on an Android 16 (API 36) emulator and with automated tests; not yet on a physical device. Maintainers: see
  [docs/releasing.md](docs/releasing.md). The app bundles open-source components under the GPL-3.0; see
  [docs/android-engine.md](docs/android-engine.md).

The server described below is for the web and desktop clients (and the Expo app). The Android app does not use it.

| Client | Where | Notes |
|---|---|---|
| Web | `static/` | Served by the server itself. |
| Desktop (Windows / macOS / Linux) | `launcher.py`, `Namao.spec` | One-file app with the worker built in; saves to a folder you choose. Windows build verified; macOS/Linux built in CI only. |
| Android (Flutter) | `mobile_flutter/` | Standalone Material 3 app: downloads on the phone with a bundled yt-dlp + FFmpeg, no server. Saves into `Download/Namao` via MediaStore (no storage permission). Android 10+. Verified on an emulator; see [mobile_flutter/README.md](mobile_flutter/README.md). |
| Mobile (iOS / Android) | `mobile/` | Expo app that controls your server and saves the result to the phone. Native builds not verified here. |

The older native Android app in `android/` is unchanged and superseded by the Flutter app above.

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
| [docs/releasing.md](docs/releasing.md) | Publishing a new Android version, the signing key, and verifying a published APK. |
| [docs/openapi.json](docs/openapi.json) | The API schema (generated; a test keeps it current). |
| [mobile/README.md](mobile/README.md) | The mobile client and its verification status. |

## Honest limits

* Platforms can throttle or bot-check a server's address (observed during this work). Namao reports it as
  `access_blocked` / `source_rate_limited`; updating or retrying does not overcome it, and Namao does not try to evade it.
* Single, public, non-live videos only. No DRM, login, cookie or CAPTCHA workarounds.
* Facebook, TikTok and Instagram extraction is enabled but was not exercised with real downloads (no rights-cleared test
  assets; these platforms often require login).
* Personal, authorized use. Check each platform's terms before offering this to other people.
