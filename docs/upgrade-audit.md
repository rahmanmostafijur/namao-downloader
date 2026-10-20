# Namao upgrade audit

Date of audit: 2026-10-20. Baseline commit: `ef0467b` (branch `main`).

This document separates **confirmed** findings (reproduced or measured here)
from **hypotheses** (plausible, not verified in this environment).

## 1. What exists today

| Area | Finding |
|---|---|
| Backend | Single file `main.py` (FastAPI). No package structure, no database, no worker, no tests. |
| Engine | `yt-dlp` called through its Python API (`yt_dlp.YoutubeDL`). `requirements.txt` is unpinned: `fastapi`, `uvicorn[standard]`, `yt-dlp`. |
| Installed in `venv/` | Python 3.12.10, yt-dlp **2026.07.04**, FastAPI 0.139.0. **`yt-dlp-ejs` not installed**, **no Deno**. |
| FFmpeg | Real `ffmpeg`/`ffprobe` 8.1.2 exist on this machine's PATH (winget). Not guaranteed elsewhere; the app only does `shutil.which("ffmpeg")`. |
| JS runtimes on this machine | Node 24.13.0 present (supported by yt-dlp ≥ 22, but **not enabled by default** — only Deno is). Deno absent. |
| Metadata vs download | Separate: `POST /api/info` (`extract_info`, `download=False`) and `GET /api/download` (second, independent extraction). |
| Where downloads run | **Inside the HTTP request handler**: `GET /api/download` blocks on `ydl.download()`, then streams the file and deletes the temp dir afterward. |
| Concurrency | Starlette's threadpool (default 40 threads). No limit on simultaneous downloads, disk, duration or size. |
| Cancellation | None server-side. A closed browser tab leaves the thread downloading; temp dir is only removed if the request finishes normally. |
| Progress | None. Browser shows an indeterminate link-click; no job state. |
| Retries | `_download_with_retry`: 3 attempts, delays 1.5s then 4.5s (no jitter), transient detection by substring match on the exception text. |
| Error handling | Every extraction error becomes HTTP 422 with the raw yt-dlp text embedded in the message ("may be private, deleted, age-restricted..."). Everything is guessed to be "the video". No error codes. |
| Output validation | Picks `max(files, key=getsize)` — no check that the file is non-empty, playable, or the right resolution. |
| Format selection | `bv*[height<=N]+ba/b[height<=N]/b` — the trailing `/b` **silently falls back to any "best" format** if the requested resolution is missing. |
| Storage | `tempfile.mkdtemp` per request, no quota, no free-space check, no expiry sweep for crashed requests. |
| Clients | Web: `static/index.html` (single 1291-line file; vanilla JS, calls `/api/info` & `/api/download`; ~130 lines of **dead** `window.NamaoBridge` code from the old WebView Android app). Android: separate **native Compose** app under `android/` that embeds its own yt-dlp via `youtubedl-android 0.18.1` and does **not** talk to the FastAPI server. Desktop: PyInstaller single-file `Namao.exe` (Windows only) via `launcher.py`. iOS: none. |
| Tests | Python: **none** (`pytest` collects 0 tests). Android: 2 unit-test files (`DownloadStatusTest`, `EngineTest`), not runnable here (see §5). |
| Deployment | No Dockerfile/Compose, no `.env.example`, no CI. |

Platforms detected (`PLATFORM_PATTERNS`): YouTube, Facebook, TikTok, X/Twitter, Instagram.

## 2. Baseline test run

* `python -m pytest -q` → `no tests ran` (there is no Python test suite).
* Android unit tests: not run (no Android SDK; Docker Desktop daemon is not
  running on this machine).

So the baseline for "existing automated tests" is empty; the regression suite
added by this upgrade is new.

## 3. YouTube failure: evidence

Test asset (rights-cleared, CC-BY): Blender Foundation, *Big Buck Bunny 60fps 4K*,
`https://www.youtube.com/watch?v=aqz-KE-bpKQ`. Commands run on 2026-10-20 from
this Windows machine; downloads were 144p to keep traffic small.

| # | Stack | Result |
|---|---|---|
| 1 | Installed: yt-dlp 2026.07.04, no EJS, no runtime — **metadata only** | Works, but only through a fallback `android vr` client, with the warning *"No supported JavaScript runtime could be found … YouTube extraction without a JS runtime has been deprecated, and some formats may be missing."* |
| 2 | Same stack, **real download** (`bv*[height<=144]+ba`) | **`ERROR: unable to download video data: HTTP Error 403: Forbidden`** and an "older than 90 days" warning. Reproduced twice. |
| 3 | Old yt-dlp 2026.07.04 + `--js-runtimes node` | **Still 403** (format `394+258`). The runtime alone does not fix it. |
| 4 | yt-dlp **2026.8.19** (stable) + yt-dlp-ejs 0.8.0, Node enabled | Downloads, merges (`394+251`), valid MP4. |
| 5 | yt-dlp 2026.8.19 + ejs, **no** runtime | Downloads and merges (this video is served via a client that needs no challenge). Warning about the missing runtime remains. |
| 6 | yt-dlp **2026.10.10.233141.dev0** (nightly) + ejs 0.8.0 + Node | Downloads and merges. Emits a harmless `Unknown codec iamf.001.001.Opus` warning. |

### Confirmed root causes

1. **Stale extractor (confirmed).** yt-dlp 2026.07.04 gets a 403 on the actual
   media request while 2026.8.19 and the nightly succeed with the same video,
   network and FFmpeg (rows 2–4). The unpinned `requirements.txt` plus the
   README advice "run `pip install -U yt-dlp` if it breaks" means a deployed
   venv silently rots.
2. **Missing upstream-required components (confirmed present, impact on this
   test video not proven).** No `yt-dlp-ejs`, no enabled JS runtime. Upstream
   says YouTube extraction without them is deprecated and formats may be
   missing; row 5 shows some videos don't need them today. Videos that
   require a signature/`n` challenge are expected to fail without them — that
   specific failure was **not** reproduced with a test video, so treat that as
   upstream-documented, not locally measured.
3. **Dependency declaration ≠ installation (confirmed).** `requirements.txt`
   installs `yt-dlp` without the `default` extra, so `yt-dlp-ejs` is never
   pulled. Nothing in the app checks for it, a runtime, or FFmpeg at start-up.

### Not root causes (checked)

* FFmpeg: present and working (row 4/5 merges succeed). The Python package
  named `ffmpeg` is not involved.
* Network/regional blocks: none from this machine.

### Hypotheses (unverified)

* Datacenter/VPS IPs may be served "Sign in to confirm you're not a bot" or 403
  regardless of yt-dlp version. Not testable from this residential connection.
  The upgrade classifies this separately and does not claim to bypass it.
* Rate limiting under bulk use (no way to measure responsibly here).
* Age-restricted/members-only/private videos: need authentication; out of scope.

## 4. Other defects found in the existing code

| Severity | Finding |
|---|---|
| **High — security** | `detect_platform` uses unanchored `re.search`, so `https://evil.example/?x=youtube.com` is "valid", then handed to yt-dlp whose *generic* extractor fetches arbitrary URLs. This is an SSRF vector (internal hosts, cloud-metadata IPs). |
| High | Blocking, unbounded downloads in the request thread: no cancellation, no size/duration/disk limit → trivial resource exhaustion on a public host. |
| High | Silent quality fallback (`/b`) breaks "no silent downgrade". |
| Medium | Raw yt-dlp exception text echoed to clients (may include URLs/tokens/paths). |
| Medium | No output verification; a zero-byte/partial file could be served as success. |
| Medium | Per-request extraction runs twice (info, then download) with no shared state. |
| Low | Dead `NamaoBridge` code in the web client; README still describes a WebView Android app. |

## 5. Platform clients

* **Web** — works against the old API; will be moved to the job API.
* **Android (native Compose)** — standalone; embeds `youtubedl-android 0.18.1`.
  Source comments say it bundles **Python 3.8**; upstream yt-dlp now declares
  `requires-python = ">=3.10"` and exact `yt-dlp-ejs==0.8.0`. The app calls
  `updateYoutubeDL` at start. **Hypothesis (unverified, no device/SDK here):**
  YouTube may degrade on-device because a Python 3.8 runtime cannot run
  current yt-dlp and no JS runtime ships. This needs an on-device test before
  any claim either way.
* **iOS** — none exists. yt-dlp + FFmpeg cannot be run on-device on iOS in a
  supportable way, so iOS must be a client of the server API. iOS builds
  require macOS/Xcode, which this environment lacks.
* **Desktop** — Windows-only PyInstaller exe. Rust/Tauri toolchain is **not**
  installed here (`cargo` missing).

## 6. Environment capabilities for this work

| Capability | Available? |
|---|---|
| Python 3.12, pip, network to PyPI/YouTube | Yes |
| FFmpeg/FFprobe 8.1.2 (winget) | Yes |
| Node 24 | Yes (Deno: no) |
| Docker daemon | **No** (client installed, engine not running) |
| Android SDK / Gradle | No (project documents a Docker build) |
| Rust/Tauri, Xcode/macOS, Linux | No |

## 7. Recommended changes (implemented in this branch)

1. Package the backend; add an **engine interface** with a yt-dlp implementation
   that is the only module importing `yt_dlp`.
2. **Dependency chain**: pin yt-dlp + `yt-dlp-ejs` exact, require a JS runtime
   (Deno preferred, Node ≥ 22 supported), require FFmpeg/FFprobe, verify with
   real diagnostics at startup and in `/health/ready`.
3. **Durable job pipeline**: SQLite job table, separate worker process, bounded
   concurrency, progress from real yt-dlp hooks, cancellation, bounded
   backoff+jitter retries for transient errors only, cleanup, quotas.
4. **Failure taxonomy** with normalized, user-safe messages and retryable flags.
5. **Security**: strict host allowlist, DNS/SSRF check, yt-dlp
   `allowed_extractors` (no generic extractor), no shell, sanitized logs.
6. **No silent downgrade** of resolution; FFprobe verification of output.
7. Docker/Compose, `.env.example`, update-check/rollback tooling, docs, tests.
8. Web client on the job API; mobile and desktop addressed in a later phase
   with explicit limits stated.
