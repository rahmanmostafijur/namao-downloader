# Testing

## Commands

```bash
pip install -r requirements-dev.txt
python -m pytest -p no:logging --cov=namao          # Python: unit + integration + e2e (needs ffmpeg/ffprobe on PATH)
node --test "tests/web/*.test.js"                   # web client logic
cd mobile && npm ci && npm run typecheck && npm test && npm run bundle
NAMAO_LIVE_TESTS=1 python -m pytest tests/test_live_youtube.py -rs     # opt-in: real YouTube
python scripts/export_openapi.py                    # regenerate docs/openapi.json after changing routes
```

CI (`.github/workflows/ci.yml`): backend + web tests with an 80 % coverage gate, Docker build + readiness, desktop
build matrix (Windows/macOS/Linux), mobile typecheck/tests/bundles. **The workflows have not been executed in this
environment**; their YAML parses and `docker compose config` validates, nothing more is claimed.

## Result of the last full run (2026-10-20, Windows, Python 3.12, FFmpeg 8.1.2, Node 24)

| Suite | Result |
|---|---|
| Python (`tests/`) | **364 passed**, 5 skipped (4 opt-in live tests; 1 symlink test that needs privileges on Windows); 93 % line coverage of `namao/` was measured on the earlier 362-test run (2026-10-20) and not re-measured after the two new `/health/live` tests |
| Python live (`NAMAO_LIVE_TESTS=1`) | 4 passed earlier the same day on the pinned nightly and on 2026.8.19; later runs from the same IPv4 address were throttled by YouTube (see download-reliability.md) |
| Web client (`node --test`) | **47 passed** (core/API client, history store incl. cross-tab adoption, action rules, a guard that no client script injects markup and every element id the controller uses exists). Browser-verified 2026-11-19 against a real API + worker with a scripted engine: download, live progress, cancel, retry (triple click → one job), orphaned job → 404 path, expired/cancelled/failed states, desktop save-to-folder (file verified on disk), light/dark/system themes, 390 px and 1280 px layouts, empty console. Lighthouse (snapshot) accessibility/best-practices/SEO 100 on Settings (desktop) and Downloads (mobile). |
| Mobile (`jest`) | 17 passed; strict `tsc` clean; Metro bundles for android + ios built; Android `expo prebuild` ok |
| Docker | image built; `api` + `worker` healthy; `/health/ready` ready with Deno 2.9.7, FFmpeg 5.1.9; real 360p download, graceful-stop → `interrupted`, drain/rebuild/resume exercised |
| Desktop (Windows) | `Namao.exe` built (28 MB, rebuilt after the final changes); `--check` ok; no-token 403 then token 303 + cookie; real merge of a local DASH stream through the frozen app; save-to-folder; 401/403 guards |
| Flutter Android (`mobile_flutter/`) | Standalone on-device downloader (2026-11-20). `flutter analyze` 0 issues; `flutter test` **305 passed** (Dart logic against a fake engine; the earlier server-client tests and the real-server integration tests were removed with the server client). Release APK (per-ABI: arm64-v8a 62 MB, armeabi-v7a 55 MB, x86_64 65 MB; universal about 160 MB) installed on an API 36 x86_64 emulator with **no server running** and driven by `adb`: engine unpack + self-update, real YouTube metadata, 144p video+audio merge (ffprobe: H.264 256x144 + AAC, 10:34), audio-only MP3, live progress, completion while backgrounded, history after force-stop, cancel mid-transfer (process killed, working files removed), offline error message. Not tested: physical device, Facebook/TikTok/X/Instagram, 16 KB-page devices, TalkBack. Release signing was the debug-key fallback. Details: `mobile_flutter/README.md`, [android-engine.md](android-engine.md). |
| Before the upgrade | **no Python tests existed**; Android unit tests were not runnable (no SDK) |

Not run: macOS/Linux desktop builds, iOS anything, Android native build/instrumented tests, GitHub Actions, any
Facebook/TikTok/Instagram download (no rights-cleared assets).

**Web verification limits.** The browser runs used a scripted engine (real API, store and worker; no network), not real
YouTube downloads. There is no automated browser test in CI: `main.js` (the controller) is covered by the manual checks
above and by an independent code review (whose findings on duplicate retries, two-tab history, desktop auto-save ordering,
outage recovery and focus handling were fixed), not by unit tests.

## What the Python suite covers

| File | Focus |
|---|---|
| `test_errors.py` | Real yt-dlp/OS messages → codes; retryable vs permanent; stale-engine upgrade of 403; redaction (URLs, userinfo, tokens, paths). |
| `test_security.py` | Allowlist, look-alike hosts, schemes/ports/userinfo, private/IPv6/NAT64/6to4 resolution, hostname charset, filename safety. |
| `test_formats.py` | Options per height, estimates flagged, exact-height selector (no `<=`, no `/b` fallback), quality parsing. |
| `test_store.py`, `test_cleanup.py` | Atomic claim under races, compare-and-set ownership, cancel/retry race, reaping, expiry, tolerant deletion, path safety. |
| `test_runner.py`, `test_worker_and_config.py` | Lifecycle order, bounded backoff, permanent errors never retried, cancel/timeout/shutdown, no success on empty/invalid output, disk caps, bounded concurrency, crash handling, drain, config validation. |
| `test_api.py`, `test_hardening.py` | Envelope, auth, quotas, idempotency, SSE caps, metadata timeout/cache, file delivery and traversal, proxy/IP handling, CSP, docs gating, schema drift. |
| `test_engine_integration.py` | **Real yt-dlp + FFmpeg + FFprobe** on a local DASH server (video-only and audio-only streams): merge, heights, MP3, progress monotonic, cancel, deadline, size/duration limits, broken segments, missing FFmpeg, generic extractor blocked, playlist/profile URLs refused, verification of bad files. |
| `test_pipeline_e2e.py` | HTTP → SQLite → worker → engine → file: success, unavailable height, missing source, cancel cleanup, expiry, concurrent jobs. |
| `test_desktop.py` | Host/header guards (strict Host regex), per-user token to HttpOnly cookie, folder validation (home-only, no hidden/AppData/Library), preferences, never-overwrite saves, concurrent saves, no-hardlink fallback, open-folder ignores client paths. |
| `test_engine_update.py` | Pin parsing/rewrite, promote/rollback, PyPI-only fetches, repo pins match the installed engine. |
| `test_live_youtube.py` | Opt-in real-platform smoke; a platform block of the network is a **skip with a reason**, never a pass or a regression. |

## Test assets

* Synthetic: a 4-second FFmpeg `testsrc2` + sine DASH stream served from localhost. No third-party content.
* Live: Blender's *Big Buck Bunny 60fps 4K* (CC-BY 3.0) at 144p / audio. Keep live runs infrequent and small:
  platforms rate-limit repeated automated access, as this project found out.

## Manual checks worth repeating after changes

1. Real browser: paste a link → formats → download → real progress → Save (done once with Chrome DevTools).
2. `docker compose stop worker` mid-download → job is `interrupted`, no leftover folder.
3. Drain/rebuild/resume with a job running.
4. A fresh desktop build: `Namao --check`, then a download and *Save*.
