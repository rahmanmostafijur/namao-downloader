# Architecture

Namao is a self-hosted video downloader (YouTube, Facebook, TikTok, X/Twitter, Instagram). One server
exposes a job API; the web, desktop and mobile clients all use it. Background: [upgrade-audit.md](upgrade-audit.md).

```
 web (static/app.js) ─┐
 desktop (Namao.exe) ─┼─►  /api/v1/downloads/*  ──►  API (FastAPI)  ──►  SQLite  ◄──  worker(s)
 mobile (Expo app)  ──┘      /health/*               validate, queue,       jobs        claim, run,
                                                      report, serve file                  verify, clean
                                                                      │                      │
                                                              metadata pool            engine.download()
                                                              (bounded, timed)         yt-dlp + EJS + JS runtime
                                                                                        + FFmpeg/FFprobe
```

## Components

| Piece | Where | Responsibility |
|---|---|---|
| Engine boundary | `namao/engine/base.py` | `DownloadEngine` protocol: validate URL, metadata, download, verify output, diagnostics. Clients and the API depend only on this. |
| yt-dlp engine | `namao/engine/ytdlp.py` | The **only** module importing `yt_dlp`. Python API (no shell), single-video platform extractors only, explicit JS runtime, no runtime remote components, exact-height selection, FFprobe verification. |
| Toolchain probes | `namao/engine/tools.py` | Finds and *runs* `ffmpeg`, `ffprobe`, Deno/Node and checks versions. Searches `NAMAO_BIN_DIR` then `PATH` only. |
| Failures | `namao/errors.py` | One taxonomy (`ErrorCode`), safe messages, redaction of URLs/tokens/paths, `classify_exception`. |
| Input hardening | `namao/security.py` | Host allowlist, SSRF resolution check, safe filenames. |
| Job store | `namao/jobs/store.py` | SQLite (WAL). Atomic claim, compare-and-set ownership, retries, cancel, reaping, limits. |
| Runner | `namao/jobs/runner.py` | One job through the lifecycle; retries, cleanup, verification gate. |
| Worker | `namao/worker.py` | N job threads + heartbeat thread + maintenance thread; drain mode. |
| API | `namao/api/app.py` | v1 routes, health, rate limits, SSE, file delivery, error envelope. |
| Desktop mode | `namao/desktop.py`, `launcher.py` | Output-folder preference, save-to-folder, loopback guards, per-user token. |
| Ops | `namao/ops.py` | `status`, `drain`, `resume`. |

## Job lifecycle

```
queued → validating → fetching_metadata → downloading → merging → verifying → completed
   ▲                                    │
   └──── transient failure (backoff + jitter, bounded) ◄────┘          failed | cancelled | interrupted
```

* `completed` is only written after FFprobe confirms a non-empty, playable file with the expected streams and
  a plausible duration. A failed job never carries a result, and a partial file is never offered.
* **Retries** apply only to `network_transient` and `source_rate_limited`; everything else fails once with a
  specific code. A retry racing a cancel ends `cancelled`.
* **Cancel**: a queued job is cancelled immediately; a running job gets a flag its worker polls (about once a
  second, from yt-dlp's progress hooks). A cancel during the FFmpeg merge takes effect when the merge returns.
* **interrupted**: the worker stopped (graceful shutdown) or stopped heartbeating (crash). The client can
  start it again.
* Every worker write is compare-and-set on `(job id, worker id, non-terminal)`, so a worker that lost its job
  (cancelled, reaped) cannot overwrite the new state.

## API

Machine-readable contract: [`openapi.json`](openapi.json) (generated from the app; a test fails if it is stale).

| Route | Purpose |
|---|---|
| `POST /api/v1/downloads/metadata` | Title, duration, and the formats the source actually offers. |
| `POST /api/v1/downloads` | Create a job (`quality`: `best`, `audio` or an exact height such as `1080`). `202`, or `200` for a replayed `Idempotency-Key`. |
| `GET  /api/v1/downloads/{id}` | Job state. |
| `GET  /api/v1/downloads/{id}/progress` | Server-sent events of the same job object. |
| `POST /api/v1/downloads/{id}/cancel` | Cancel. |
| `GET  /api/v1/downloads/{id}/file` | The verified file (`attachment`, `nosniff`, Range supported). |
| `GET  /health/live`, `/health/ready` | Process alive / dependencies ready (engine, FFmpeg, FFprobe, JS runtime, EJS, database, disk, worker). |

All errors, HTTP and per-job, share one shape: `{"error": {"code", "message", "retryable", "detail?"}}`.
`detail` (sanitized engine text) is omitted unless `NAMAO_EXPOSE_ERROR_DETAIL=1`.
The previous `/api/info` and `/api/download` routes were removed: the old client was their only consumer.

**Access control.** Job ids are 144-bit random capability tokens; there is no list endpoint. Optional
`NAMAO_API_KEY` protects `/api/v1/*`. Rate limits are per client address (rightmost trusted
`X-Forwarded-For` hop only, IPv6 by /64), with a separate cap for reads, SSE streams, open jobs per client and
the global queue. Idempotency keys are scoped to the client.

## Why these choices

* **SQLite, no Redis/Postgres.** There was no database, the target scale is a few concurrent downloads on one
  host, and WAL gives concurrent API reads with atomic `BEGIN IMMEDIATE` claims. `JobStore` is the whole
  persistence contract: swap it for Postgres if Namao must span hosts.
* **No second download engine and no automatic fallback.** A second engine would hit the same platform
  restrictions and add a failure mode; the interface exists so one can be *evaluated* (same test cases)
  before ever being wired in.
* **Metadata in the API process, downloads in the worker.** Metadata is a few seconds of network; it runs on a
  dedicated bounded pool with a hard timeout and a 60-second cache. Anything involving media runs in the worker.
* **Polling is always correct, SSE is an optimisation.** Clients fall back to polling if the stream drops.
* **Mobile is a server client, not an embedded engine.** yt-dlp + FFmpeg + a JS runtime cannot be run on iOS
  in a supportable way, and one contract for every client is the point of this upgrade.
* **Desktop is the web UI plus a loopback server, packaged with PyInstaller**, not Tauri. A Tauri shell needs a
  Rust + platform toolchain (not available here) and would only add window chrome around the same UI plus a
  sidecar to package; revisit if a native window or auto-update channel becomes a requirement.

## Clients

| Client | Code | Status |
|---|---|---|
| Web | `static/` (`index.html`, `app.js`) | Job API, SSE with polling fallback, cancel/retry, 16 unit tests, exercised in a real browser. |
| Desktop (Windows/macOS/Linux) | `launcher.py`, `Namao.spec` | Windows exe built and run end to end. macOS/Linux builds are defined in CI, **not run here**. |
| Mobile (iOS/Android) | `mobile/` (Expo SDK 57) | Typecheck, 17 tests, JS bundles and Android prebuild verified; native builds and iOS prebuild **not verified**. |
| Android (native, legacy) | `android/` | Separate standalone app embedding its own yt-dlp (youtubedl-android 0.18.1, bundled Python 3.8). **Unchanged and unverified**: current yt-dlp requires Python ≥ 3.10, so its on-device engine freshness is unknown. Treat `mobile/` against a server as the supported Android path. |

## Security model

Untrusted: submitted URLs, redirects, extracted metadata and titles, filenames, media content, job ids, headers.

* URL: scheme http/https, no userinfo, default ports, strict hostname characters, parsed host must be an allowlisted
  platform domain, and must not resolve to a private/loopback/link-local/NAT64/6to4-embedded-private address.
* yt-dlp is restricted to single-video platform extractors (`allowed_extractors`): the generic "fetch any URL"
  extractor, playlists, channels and profiles are refused. File URLs are disabled and `remote_components` is empty:
  no code is downloaded at run time.
* Subprocesses use argument lists only. Binaries are resolved from `NAMAO_BIN_DIR`/`PATH`; a binary in the working
  directory is ignored.
* Files: per-job directory, fixed internal name (`media.<ext>`), display filename sanitized (reserved names,
  separators, controls, bidi), delivery checks the resolved path stays inside the job directory.
* Logs and stored errors pass through `redact` (URLs reduced to host, token-like pairs, bearer tokens, paths).
  The source URL's query string is erased from the database once the job's files are deleted.
* Desktop mode (a local server every website the user visits can reach): Host allowlist against DNS rebinding; desktop
  endpoints need a custom header (forces a CORS preflight, and no CORS headers are served); a per-user token kept in the
  user's own app-data folder is exchanged for an HttpOnly, SameSite=Strict cookie, so other accounts on the same machine
  cannot drive the app; the output folder must be inside the home folder (not hidden, not AppData/Library); saves never
  overwrite.
* Containers: non-root, read-only root filesystem, no capabilities, resource limits.
* CI: the job that installs and runs unreviewed upstream code (engine candidate) has read-only permissions and no stored
  credentials; a separate job that can write only runs this repository's script. Actions are pinned by commit SHA.

**Residual risks (accepted, documented):**

1. *Egress.* Only the entry URL is validated. yt-dlp's own downstream fetches (media/manifest URLs returned by an
   extractor) are not IP-checked per hop, and DNS rebinding between the check and the fetch is possible for a
   name an attacker controls. Mitigation is network-level: run the worker with egress limited to the public
   internet (block private ranges and cloud metadata addresses) or behind a filtering proxy.
2. *Hung FFmpeg.* Cancel and timeout are enforced from yt-dlp's hooks; a hung FFmpeg is not killed. Its job stops
   being heartbeated after the deadline plus a grace period and is reported `interrupted`, but the worker thread
   stays occupied until the process ends.
3. *Cancel latency with concurrent fragments.* yt-dlp may finish in-flight fragment requests before a cancel is
   honoured; a many-fragment source can take longer than a second to stop. Not measured.
4. *Best-quality size.* `best` picks the highest resolution; if its estimated size exceeds the limit the job
   fails with `file_too_large` rather than silently choosing a smaller one. Pick an explicit height instead.
5. *Platform restrictions.* See [download-reliability.md](download-reliability.md).
