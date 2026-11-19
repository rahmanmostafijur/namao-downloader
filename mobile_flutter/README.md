# Namao for Android (Flutter)

A Flutter Android client for the self-hosted **Namao** (নামাও) video download server in this
repository. It is a *thin client* of `/api/v1/downloads/*`: it contains **no downloader and no
extractor**. It sends links to your server, shows the server's real job state, and then fetches the
finished file and saves it on the phone. Every number on screen (percent, speed, ETA, bytes, sizes)
comes from the server's job record; nothing is simulated.

- Package `namao_app`, Android `applicationId` `com.namao.flutter`, app name "Namao".
- Flutter 3.47.5 / Dart 3.13, Riverpod 3, Material 3 with a custom identity (shared with the web UI).
- `minSdk 29` (Android 10). Reason: scoped storage. `MediaStore.Downloads` lets the app write to
  `Download/Namao` with **no storage permission**, so the app never needs the legacy
  `WRITE_EXTERNAL_STORAGE`. (It also drops pre-Android-10 devices from the support matrix.)

## Run it

```bash
cd mobile_flutter
flutter pub get
flutter run                      # device or emulator
```

The server address is entered on first launch (Test connection calls the server's real
`/health/ready`). From the **Android emulator** the host machine is `http://10.0.2.2:8000`; from a
real phone use the server's LAN address, e.g. `http://192.168.1.20:8000`, or an https URL.
Cleartext http is allowed (self-hosted LAN servers are usually plain http) via
`res/xml/network_security_config.xml`; the app shows a warning whenever the address is plain http to a
non-private host. Redirects are never followed (so the API key can't be forwarded to another host).

### A real server to try it against

`tool/run_test_server.py` starts the **real** backend (yt-dlp + FFmpeg + FFprobe, embedded worker)
against a small synthetic DASH stream it generates with FFmpeg, so no internet or third-party content
is involved. Run it from the repository root with the repo's venv:

```bash
./venv/Scripts/python.exe mobile_flutter/tool/run_test_server.py --port 8000 [--seconds 60] [--api-key KEY]
```

It prints the DASH manifest URL (`http://localhost:PORT/manifest.mpd`). The real server only accepts
YouTube/Facebook/TikTok/X/Instagram hosts; this script enables the server's *test-only* escapes
(`NAMAO_ALLOW_GENERIC_EXTRACTOR`, `NAMAO_EXTRA_ALLOWED_HOSTS=localhost`,
`NAMAO_ALLOW_PRIVATE_NETWORKS`) in its own environment only. To type such a link into the app, the
app's client-side platform hint must be disabled; that exists only as a compile-time flag
(`--dart-define=NAMAO_ALLOW_ANY_LINK=true`) that is **off in normal builds** (a test asserts the
default is `false`). The server remains the authority on what it accepts.

## Test

```bash
flutter analyze                  # clean
dart format --set-exit-if-changed lib test
flutter test                     # unit + widget tests
flutter test --coverage          # writes coverage/lcov.info

# against a REAL server (skipped unless both variables are set):
NAMAO_TEST_SERVER=http://127.0.0.1:8000 \
NAMAO_TEST_MEDIA_URL=http://localhost:PORT/manifest.mpd \
flutter test test/integration
```

## Build a release APK and sign it

```bash
flutter build apk --release                   # universal APK
flutter build apk --release --split-per-abi   # smaller per-ABI APKs
```

Output: `build/app/outputs/flutter-apk/app-release.apk` (R8 minification is on, Flutter's default for
release).

Release signing reads `android/key.properties` (git-ignored) **or** environment variables:

```properties
# android/key.properties            (env equivalents: NAMAO_KEYSTORE_PATH, NAMAO_KEYSTORE_PASSWORD,
storeFile=C:/secure/namao-release.jks   #                 NAMAO_KEY_ALIAS, NAMAO_KEY_PASSWORD)
storePassword=...
keyAlias=namao
keyPassword=...
```

Keystores and `key.properties` are git-ignored and must never be committed. **With neither present
the release build is signed with the DEBUG key** (Gradle prints a warning). That is fine for local
verification and is not suitable for distribution.

## Architecture

```
lib/
  core/      api (HttpNamaoApi, ApiException), models (Job, VideoMetadata, ...), error mapping,
             job_view (status wording), job_poller (backoff/terminal/404), formatting, url_tools
  data/      history store (shared_preferences), settings (+ flutter_secure_storage for the key),
             file_saver (stream -> temp -> verify -> MediaStore), native_media (MethodChannel)
  design/    tokens.dart (single source of truth), theme, type, reusable widgets
  features/  home/  downloads/  settings/  setup/  shell/
android/.../kotlin/com/namao/flutter/   MainActivity.kt (MediaStore, open/share, permission),
                                        TransferService.kt (foreground service)
```

- **State** lives in Riverpod notifiers above the widget tree. `DownloadsController` owns tracking
  for every download, so switching tabs never cancels polling or a transfer. Rows watch only their own
  entry (`select`), keyed by job id, so a poll tick rebuilds just the rows that changed.
- **No list-jobs endpoint** exists on the server (job ids are capability tokens), so history is
  client-side: each record keeps the source URL, title, thumbnail, quality, platform, the last server
  job snapshot, the server it belongs to, and the local save info. On launch and on returning to the
  foreground, non-terminal jobs are re-polled; a job the server answers 404/410 for (with the Namao
  error envelope) becomes **Expired**, never "success". Records belonging to a different configured
  server are not polled and are labelled "On another server".
- **Polling**, not SSE (always correct): about 1 s while active, exponential backoff (capped 15 s) on
  errors, stops at a terminal state, 401 -> "API key rejected", repeated network failure ->
  "Lost contact" (the job's state is not changed: it may still be running).
- **Create** sends `Idempotency-Key`: one new UUID per tap, reused only to repeat a tap whose answer
  was lost (network/5xx/429), so a lost response can't create two jobs. **Retry** creates a new job with
  the key `retry:<old job id>` (double tap = one job).
- **Saving a finished file**: stream `GET /file` (with `X-API-Key`) to a temp file; the byte count
  must equal `result.size_bytes` exactly (a short or long file is a failure, never a success); then
  copy it into `MediaStore.Downloads` at `Download/Namao` with `IS_PENDING` while writing (the Kotlin
  side re-checks the size and deletes the pending row on any failure). MediaStore renames duplicates
  (`name (1).mp4`); the app records the **real** name it was given. The temp file is removed on every
  path, and stale temp files from a killed process are removed at launch. Open/Share use the
  MediaStore content URI with `FLAG_GRANT_READ_URI_PERMISSION`. Saving is idempotent (a saved job
  shows Open/Share; it is never saved twice). Removing history never deletes the saved file (the
  dialog says so).
- **Design tokens** (identical to the web client): dark `bg #0B0C0F`, `surface #121317`,
  `surfaceRaised #181A20`, `border #23262E`, `text #ECEDEF`, `textDim #9096A2`, accent `#F5A524`
  (content `#1A1203`), success `#3DD68C`, danger `#F87171`, info `#7AA2FF`; light `bg #F6F5F2`,
  `surface #FFFFFF`, `surfaceRaised #FBFAF8`, `border #E4E1DA`, `text #17181B`, `textDim #5F6470`,
  accent `#B45309` (content `#FFFFFF`), success `#15803D`, danger `#B91C1C`, info `#1D4ED8`. Radii
  10/14/20/999, spacing 4/8/12/16/20/24/32, motion 150-250 ms ease-out (zero with the system's
  reduce-motion setting). Fonts are bundled as assets (no runtime network loading): **Inter** (UI) and
  **Bricolage Grotesque** (wordmark, headings), variable TTFs from the official `google/fonts`
  repository, SIL OFL 1.1 (licences in `assets/fonts/`). Numbers use tabular figures. One icon family
  (Material rounded/outlined glyphs from the bundled Material Icons font).

## Dependencies (each justified)

| Package | Why |
|---|---|
| `flutter_riverpod` | App-level state that outlives widgets (downloads tracking). |
| `http` | The API client; `MockClient` makes it unit-testable. |
| `shared_preferences` | Server URL, theme, history (small, non-secret). |
| `flutter_secure_storage` | The API key (Android Keystore-backed), kept out of preferences. |
| `cached_network_image` | Thumbnails with disk cache; decoded at display size (`memCacheWidth`). |

MediaStore saving, opening, sharing, the version string and the transfer service are a ~250-line
Kotlin channel instead of extra plugins.

## Background behaviour (what is and is not true)

- The **server** does the downloading, so tracking a job needs no service. While the app is in the
  background, polling is paused (the OS would freeze it anyway); on return everything is refreshed
  and any job that finished is saved then.
- The **phone-side transfer** runs under an Android **foreground service** (type `dataSync`) with a
  progress notification, so it keeps going when you switch to another app. Verified on an emulator:
  the service was `isForeground=true` (`types=0x1`) with the progress notification while the app was
  in the background.
- **It does not survive the app being swiped away / back-pressed out**, because that destroys the
  Flutter engine. The service stops with the activity. The interrupted transfer is detected on the
  next launch and the entry shows **Retry save** (the server file stays available until it expires);
  stale temp files are cleaned. Verified on an emulator by force-stopping the app mid-transfer.
- Android 13+ notification permission is requested once, at the first save; if denied the transfer
  still works (only the notification is hidden).
- There is no push/notification when a job finishes while the app is closed.

## Verification status

Run in this repository (Windows, Flutter 3.47.5):

| Check | Result |
|---|---|
| `dart format` / `flutter analyze` | clean, 0 issues |
| `flutter test` | 262 passed, 7 skipped (the 7 are the real-server tests, which need the env vars) |
| Coverage (`flutter test --coverage`) | 93.5% of lines in the 48 Dart files the tests load (2339/2502); `lib/main.dart` (24 lines of startup wiring) is not exercised by tests and is not in that figure (about 92.6% if counted as 0%) |
| Real-server integration (`test/integration`) | 7/7 passed against the real backend: readiness, metadata (360p/180p/audio from the synthetic DASH), create, idempotent replay, poll to `completed`, byte-exact file download + verified save, audio job, an unavailable height failing cleanly (never success), cancel, 404 envelope |
| Android emulator (API 36, x86_64, `-no-window`) | App installed and driven by `adb`: setup + real `/health/ready` test, metadata, formats, download, real progress, auto-save into `Download/Namao`, duplicate renaming (`manifest (1).mp4`...), Open (plays in Photos), Share sheet, interrupted-transfer detection + Retry save, foreground service while backgrounded, dark/light/system theme, system font scale 1.5. The saved file was pulled with `adb` and probed with ffprobe (h264 + aac, 640x360, 8 s, exact byte size) |
| Release build | `flutter build apk --release` succeeds, R8 on; the release APK was installed and run on the emulator (see numbers below) |

Screenshots of the emulator runs (git-ignored) are in `verification/`.

**Not verified / not claimed**

- No physical device was used; only an x86_64 emulator with software GL.
- No real YouTube/Facebook/TikTok/X/Instagram download was run (the synthetic stream exercises the
  real server pipeline, not those sites' extractors). Thumbnails from real platforms were not seen
  on a device (the synthetic stream has none); the thumbnail widget is covered by code paths only.
- Tablet/landscape layouts are covered by widget tests (NavigationRail at >= 600 dp, 840x600 and
  800x360 sizes), not by a tablet emulator.
- Release signing was exercised only as the debug-signed fallback; the keystore path is not tested.
- The notification-permission flow was seen allowed (API 36); the denied path is untested on device.
- Predictive back: the manifest opt-in and the transition theme are set; the back gesture animation
  itself was not observed.
- TalkBack was not run; semantics labels, roles and 48 dp targets are asserted by widget tests.

## Known limits

- Android 10+ only (see `minSdk`).
- One transfer at a time (queued), by design.
- The server's file expires (`expires_at`): an unsaved job whose file is gone shows **Expired** and
  can be retried from the source.
- Honest product limits: personal use of videos you are allowed to download; no DRM or login
  bypass; sites change and the server's engine may need updating.
