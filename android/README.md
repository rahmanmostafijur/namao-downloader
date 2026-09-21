# Namao — standalone Android app

A separate, self-contained Android port of Namao. No PC, no server, no
network dependency on anything you run — yt-dlp and ffmpeg run directly on
the phone via the [youtubedl-android](https://github.com/yausername/youtubedl-android)
library.

The app is a native Jetpack Compose UI (Home / Queue / History / Settings)
backed by a foreground `DownloadService` and a Room database, so downloads
keep running when the app is backgrounded, the screen locks, or the Activity
is recreated — they don't depend on a WebView or an open screen the way the
first Android build did.

## Architecture

```
Compose UI (Home / Queue / History / Settings)
        │  reads/writes via Room + DataStore, never drives a download directly
        ▼
DownloadRepository  ──────────────────────────────────────────────
        │                                                          │
        ▼                                                          │
DownloadService (foreground service, dataSync type)                │
   ├─ queue runner (respects Wi-Fi-only / concurrency settings)     │
   ├─ per-job worker: yt-dlp execute() → validate → FileStore.finalize()
   ├─ retry with exponential backoff (network/timeout failures only)│
   └─ NotificationManager (progress / completed / failed)           │
        ▼                                                          │
FileStore — SAF folder, else MediaStore (API 29+), else a plain     │
File (API ≤28) — never silently overwrites an existing file ────────
```

## Install the prebuilt APK

The `Namao-debug.apk` at the project root predates this rewrite and does not
reflect the current code. Build a fresh debug APK with the command below
before installing.

## What's verified vs. what isn't

This was built from a from-scratch rewrite of the Android download engine and
UI. Verification so far has been limited to what's possible without an
Android SDK, emulator, or physical device in this environment:

- Source-level review of every file against the `youtubedl-android` library's
  actual public API (`execute`, `getInfo`, `destroyProcessById`, exception
  types), fetched from the library's source.
- **Not yet verified**: a real Gradle build (compile + resource linking) in
  this environment, actually running on a device, the foreground service
  surviving a real backgrounding/lock/process-death cycle, notification
  behavior, and the Compose UI rendering correctly. Treat this as an
  unverified rewrite until it's been built and exercised on a real device.

## Rebuilding after changes

No Android Studio or SDK is installed on the Windows machine this was built
on — the build runs inside Docker (`mingc/android-build-box`), which bundles
JDK 21 + Android SDK + build-tools:

```bash
docker run --rm \
  -v "<path to this android/ folder>:/project" \
  -v "<a persistent cache dir>:/root/.gradle" \
  mingc/android-build-box:latest \
  bash -c "cd /project && ./gradlew assembleDebug"
```

The resulting APK lands at `app/build/outputs/apk/debug/app-debug.apk`.

For a release build (minified, shrunk resources — see `app/proguard-rules.pro`):

```bash
./gradlew bundleRelease   # .aab for Play Store
./gradlew assembleRelease # .apk, needs a real signing config first
```

`assembleRelease`/`bundleRelease` will fail until a real signing key is
configured in `app/build.gradle.kts` — none is set up in this repo, since a
Play Store-style release key wasn't part of this pass.

## Known limitations / follow-ups

- **No true HTTP byte-range "pause"**: pausing a job stops the underlying
  process and keeps its partial file; resuming re-invokes yt-dlp against the
  same output path, which continues via yt-dlp's own default `--continue`
  behavior when the server supports range requests. This is not a custom
  resume implementation — it only works as well as yt-dlp's own resume support
  does for that specific URL.
- **Foreground notification is a single summary notification**, not one fully
  interactive notification per concurrent download; completed/failed jobs
  each get their own notification, but a running job's notification doesn't
  have its own inline cancel button (cancel is done from the Queue screen).
- **No "recent URLs" list** on the Home screen.
- **Debug build only has no signing story**: fine for personal use; see
  above for what a release build needs.
- The FAQ-style copy in the shared `static/index.html` describes the
  browser/desktop download flow and is not used by this native Android UI at
  all anymore (the WebView was removed).
