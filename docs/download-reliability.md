# Download reliability

## The dependency chain (all must be present and compatible)

| Component | Pinned / tested | How it is verified |
|---|---|---|
| yt-dlp | `2026.10.10.233141.dev0` (nightly), known-good rollback `2026.8.19` | Exact pin in `requirements.txt`; `/health/ready` reports version, channel, age. |
| yt-dlp-ejs | `0.8.0` (yt-dlp pins it exactly) | `/health/ready` compares installed vs the version yt-dlp declares; the frozen app includes its data files. |
| JS runtime | Deno `2.9.7` in Docker (SHA-256 verified at build); Node 24 works for development | Executed (`--version`) and checked against the minimums upstream documents (Deno ≥ 2.3.0, Node ≥ 22). |
| FFmpeg + FFprobe | Debian 5.1.9 in Docker; 8.1.2 on the dev machine | Executed (`-version`). These are real binaries, **not** the Python package called `ffmpeg`. |
| Python | 3.12 | yt-dlp requires ≥ 3.10. |

Declaring a dependency proves nothing, so the Docker build fails unless Deno, FFmpeg, FFprobe and
`yt_dlp`/`yt_dlp_ejs` actually run, `/health/ready` re-checks them at run time, and the desktop app has
`Namao.exe --check`.

## What was actually wrong (evidence in [upgrade-audit.md](upgrade-audit.md))

1. **A stale yt-dlp** (2026.07.04): HTTP 403 on the media request for a video that 2026.8.19 and the nightly
   downloaded fine, same machine and network. Reproduced twice; a JS runtime alone did not fix it.
2. **Missing required components**: no `yt-dlp-ejs`, no enabled runtime (upstream: YouTube extraction without them
   is deprecated). Not the cause for the test video, but a real gap for videos that need the challenge solver.
3. **The packaged app could never have worked for those videos**: the old PyInstaller spec collected `yt_dlp` but
   not `yt_dlp_ejs`.
4. **Nothing checked any of it** at start-up.

A *fourth* failure mode was then observed rather than assumed: after heavy testing from one residential IPv4
address, YouTube answered HTTP 429 and then "Sign in to confirm you're not a bot" for **the same engine, video
and machine**, while a fresh IPv6 address worked (and forcing `-4` on the host reproduced the failure exactly).
That is per-IP throttling, not an extractor bug; updating or retrying does not overcome it. Namao classifies it
as `access_blocked` and says so.

## Failure codes

| Code | Meaning | Auto-retry | What to do |
|---|---|---|---|
| `network_transient` | Timeout, reset, DNS blip, HTTP 5xx | **yes** (bounded, backoff + jitter) | Usually nothing. |
| `source_rate_limited` | HTTP 429 / "try again later" | **yes** (bounded) | Wait; lower concurrency. |
| `access_blocked` | Bot check, IP/network refused, or HTTP 403 on a fresh engine | no (client may retry later) | Different egress IP/network. An update will not help. |
| `engine_outdated` | HTTP 403 or extractor/challenge failure **and** yt-dlp is older than `NAMAO_ENGINE_STALE_DAYS` | no | Run the update procedure below. |
| `extractor_broken` | Upstream site changed, engine is recent | no | Check for a newer yt-dlp; report upstream. |
| `js_runtime_missing` / `js_challenge_failed` | No runtime, or the challenge solver failed | no | `/health/ready`; install Deno; versions of yt-dlp/EJS/runtime. |
| `ffmpeg_missing` / `merge_failed` | No FFmpeg, or merging failed | no | Install FFmpeg; check disk. |
| `format_unavailable` | The chosen height isn't offered | no | Pick another option; **never silently downgraded**. |
| `video_unavailable` / `auth_required` / `geo_restricted` | Deleted/private; login, age or members-only; region | no | Not solvable by Namao (no cookie harvesting, no bypass). |
| `unsupported_platform` / `unsupported_content` | Not an allowed site; playlist, channel, profile, live | no | Use a single video link. |
| `file_too_large` / `duration_too_long` | Over `NAMAO_MAX_OUTPUT_MB` / `NAMAO_MAX_DURATION_SECONDS` | no | Raise limits or choose a smaller quality. |
| `output_invalid` | FFprobe rejected the file (empty, truncated, wrong streams) | no | Output is discarded. |
| `storage_full` | Below `NAMAO_MIN_FREE_MB` or over `NAMAO_MAX_STORAGE_MB` | no (client may retry) | Free space; shorten retention. |
| `timeout`, `interrupted`, `cancelled` | Job exceeded its time, worker stopped, user cancelled | no | Start again if wanted. |
| `download_failed`, `metadata_failed` | Unrecognised failure | no | Enable `NAMAO_EXPOSE_ERROR_DETAIL` and read the worker log. |

Not every failure is blamed on the library or the video: classification is by evidence, and an unrecognised error
stays `download_failed`.

## Release management

**Policy.** Upstream recommends the nightly channel for regular users, so a nightly is the default *candidate*. It
is never promoted untested, and production only ever runs an exact pin.

```bash
python scripts/engine_update.py check                         # pin vs latest stable / nightly
python scripts/engine_update.py candidate --channel nightly --venv .cand
NAMAO_ENGINE_CANDIDATE=1 NAMAO_LIVE_TESTS=1 .cand/Scripts/python -m pytest      # (bin/python on Linux/macOS)
python scripts/engine_update.py promote --version <version>   # rewrites the pin, saves the old one as known-good
python scripts/engine_update.py rollback                      # restores requirements-known-good.txt
```

`.github/workflows/engine-update.yml` does the first four steps weekly and opens a pull request; it never merges
and never touches a deployment. Live tests skip, with the reason `network is blocked`, when the runner's address is
bot-checked, and the PR says how many were skipped: **run the live tests from an unblocked network before
merging.** (Datacenter runner addresses are often blocked.)

**Deploying a new pin without breaking active jobs:**

```bash
docker compose exec api python -m namao.ops drain --wait 1800   # workers stop claiming; running jobs finish
docker compose up -d --build                                    # new image, new pin
docker compose exec api python -m namao.ops resume
curl -s http://127.0.0.1:8000/health/ready                      # engine version, channel, tools
```

**Rollback:** `python scripts/engine_update.py rollback`, rebuild, redeploy (same drain steps). Docker images are
immutable, so tagging each build (`docker tag namao:local namao:2026-10-20`) also gives an instant image-level rollback.

**Responding to an upstream extractor change.**
1. Symptom: a rise in `extractor_broken` / `engine_outdated` / `js_challenge_failed` in the worker log (`job.failed`
   events carry the code), or `/health/ready` warning that the engine is stale.
2. `python scripts/engine_update.py check`; test the newest nightly with the candidate procedure.
3. If the candidate passes, promote and deploy with the drain steps. If upstream has no fix yet, pin stays; say so
   to users rather than retrying.
4. If the candidate fails the suite, keep the known-good pin and look at the failing test before anything else.

## Evidence this was tested (2026-10-20)

* Real chain, no mocks, local synthetic DASH stream: separate H.264 video and AAC audio downloaded by yt-dlp,
  merged by FFmpeg, verified by FFprobe; exact-height selection; unavailable height fails instead of downgrading;
  audio → MP3; cancel and timeout; size/duration limits; truncated and garbage output rejected.
* API → SQLite → worker → file, including cancel, expiry and cleanup, concurrent jobs.
* Live YouTube (Big Buck Bunny, CC-BY): metadata + 144p merge + MP3 passed on the pinned nightly and on 2026.8.19,
  on Windows, and in the Linux Docker image with Deno (360p, then 720p/audio were blocked by the IP throttling described above).
* Facebook, TikTok and Instagram: **no rights-cleared public test assets were available**, and several of these
  platforms require login for most content. Their extractors are allowed and covered only by URL/classification tests,
  not by real downloads.

## Limits you should plan for

* Platforms may throttle or bot-check a server's address regardless of software versions; Namao reports this
  honestly and does not attempt to evade it. No cookie harvesting, no CAPTCHA or DRM circumvention.
* Only publicly accessible, single, non-live videos. Private, age-restricted, members-only and region-locked
  content needs authorized access Namao does not provide.
* Review each platform's terms before offering this as a service; YouTube's terms in particular restrict
  downloading outside provided features. Namao is documented and licensed for personal, authorized use only.
