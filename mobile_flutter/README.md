# Namao for Android (Flutter)

A standalone Android app for **Namao** (নামাও). Paste a link to a video on YouTube, Facebook, TikTok,
X/Twitter or Instagram, pick a quality the video really offers, and Namao downloads it **on the phone**
and saves it to `Download/Namao`. There is no server, address or account to set up: the downloader
(yt-dlp, FFmpeg and their runtime) is bundled inside the app. Internet is needed only to reach the
video's site.

- Package `namao_app`, Android `applicationId` `com.namao.flutter`, app name "Namao".
- Flutter 3.47.5 / Dart 3.13, Riverpod 3, Material 3 with a custom identity (shared with the web UI).
- `minSdk 29` (Android 10). Reason: scoped storage. `MediaStore.Downloads` lets the app write to
  `Download/Namao` with no storage permission. The only permissions are internet, a foreground service
  and notifications.
- The bundled downloader is GPL-3.0 software. See [../docs/android-engine.md](../docs/android-engine.md)
  for what that means, how the engine is kept current, and its limits.

## Run it

```bash
cd mobile_flutter
flutter pub get
flutter run            # device or emulator (x86_64, arm64-v8a or armeabi-v7a)
```

The first launch unpacks the downloader and fetches the latest yt-dlp, so the first link takes longer.
There is nothing to configure.

## Tests

```bash
flutter analyze        # clean
flutter test           # unit + widget tests (no phone needed)
```

The Dart tests cover the downloader logic with a fake engine (options, formats, progress, error
mapping, job states, file saving, history). The native side (the real yt-dlp and FFmpeg) can only be
checked on a device or emulator: see [Verification status](#verification-status).

For a build that accepts any link (for example a local test stream), add
`--dart-define=NAMAO_ALLOW_ANY_LINK=true`. It is off in normal builds, which only read the five
supported sites.

## Build a release APK and sign it

```bash
flutter build apk --release --target-platform android-arm64   # what the release workflow publishes (about 62 MB)
flutter build apk --release --split-per-abi   # one APK per ABI
flutter build apk --release                   # universal APK (about 155 MB: the engine is bundled per ABI)
```

Phones today are `arm64-v8a`; `armeabi-v7a` is for old 32-bit phones; `x86_64` is the emulator.
Output: `build/app/outputs/flutter-apk/`. R8 minification is on, with keep rules for the engine library in
`android/app/proguard-rules.pro` (without them the release app crashes the first time it starts the
engine).

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
  core/      NamaoApi (what the app asks of the downloader), models (Job, VideoMetadata, ...),
             error messages, job_view (status wording), job_poller, formatting, url_tools, licenses
  data/
    engine/  LocalNamaoApi (the downloader, as the job records the UI knows), LocalEngine (channel
             to the native runner), ytdlp_options, format_builder, progress_tracker, error_classifier
    ...      history store (shared_preferences), file_saver (verify -> MediaStore), native_media
  design/    tokens.dart (single source of truth), theme, type, reusable widgets
  features/  home/  downloads/  settings/  shell/
android/.../kotlin/com/namao/flutter/
  LocalEngine.kt     runs yt-dlp + FFmpeg, keeps each job's raw state, updates yt-dlp
  EngineChannel.kt   the MethodChannel in front of it
  MainActivity.kt    MediaStore saving, open/share, notification permission
  TransferService.kt foreground service (keeps a download alive in the background)
```

- **Decisions live in Dart, the phone only runs processes.** `LocalNamaoApi` builds every yt-dlp option
  (`ytdlp_options.dart`), turns the format list into quality choices (`format_builder.dart`, the same
  rules as the web client), computes progress (`progress_tracker.dart`) and classifies failures
  (`error_classifier.dart`). Kotlin starts the process, parses its progress lines and remembers the
  state; it has no policy. That keeps the logic unit-testable.
- **State** lives in Riverpod notifiers above the widget tree. `DownloadsController` owns tracking for
  every download, so switching tabs never cancels one. Rows watch only their own entry.
- **Progress** is real: bytes, speed and time left come from the running download. A video and its
  audio are two transfers; the percentage is combined so it only moves forward and stays below 100%
  until the file is finished.
- **Finishing**: the engine writes `media.<ext>` in an app-private job folder. The app checks its size,
  copies it into `MediaStore.Downloads` at `Download/Namao` (`IS_PENDING` while writing; any failure
  deletes the pending row), records the real name MediaStore gave it (`name (1).mp4` on duplicates), and
  only then deletes the working copy. A failed save keeps the file so **Retry save** works. Removing a
  history entry never deletes the saved file.
- **Restarts**: history is stored on the phone. On launch, a download that was running when the app
  closed is shown as **Interrupted** with Retry; one that had finished but was not saved yet is found on
  disk and saved; leftover working files are deleted.
- **Errors** are mapped to stable codes with plain wording ("Your internet connection was interrupted",
  "This video is unavailable", ...). The tool's own text is only logged (`developer.log`), never shown.
- **Design tokens** (identical to the web client), fonts (bundled **Inter** and **Bricolage Grotesque**,
  SIL OFL 1.1) and motion rules are unchanged from the first version; see `lib/design/tokens.dart`.

## Dependencies

| Package | Why |
|---|---|
| `flutter_riverpod` | App-level state that outlives widgets (downloads tracking). |
| `shared_preferences` | Theme and history (small, non-secret). |
| `cached_network_image` | Thumbnails with disk cache. |
| `io.github.junkfood02.youtubedl-android` `library` + `ffmpeg` 0.18.1 (Android) | The bundled yt-dlp runtime (Python 3.12, QuickJS) and FFmpeg. GPL-3.0. |

## Background behaviour (what is and is not true)

- While a download is running, a foreground notification ("Downloading 42%") keeps the app alive when
  you switch to another app. The download finishes and is saved while the app is in the background.
  Verified on an emulator: a download finished and was saved while the app was in the background.
- **It does not survive the app being swiped away from Recents**, which destroys the Flutter engine.
  The running download is stopped, and it shows as **Interrupted** (with Retry) on the next launch.
- Android 13+ asks for notification permission when the first download starts; if denied, downloads
  still work (only the notification is hidden).
- There is no push notification when a download finishes while the app is closed.

## Verification status

Run in this repository (Windows, Flutter 3.47.5) on 2026-11-20:

| Check | Result |
|---|---|
| `flutter analyze` | clean, 0 issues |
| `flutter test` | 305 passed (includes the new engine-layer tests) |
| Android emulator (API 36, x86_64, software GL), release APK, **no server running** | Fresh install; engine unpacks and updates itself (yt-dlp 2025.11 bundled, then 2026.10.26 downloaded and SHA-256 verified); real metadata for a Creative-Commons YouTube video (title, thumbnail, channel, duration, formats from 144p to 2160p60 with sizes); video download at 144p (separate video and audio streams merged by FFmpeg: `ffprobe` shows H.264 256x144 + AAC, 10:34, exact byte size, saved to `Download/Namao`); audio-only download (MP3, 14.5 MB); live progress with speed, time left and bytes; download finished and saved while the app was in the background; history survived a force-stop and relaunch; cancel mid-transfer (4%, 2.1 GB job) stopped the process, deleted the working folder and removed the notification; airplane mode gave the plain "internet connection was interrupted" message with Retry; no storage permission requested |

**Not verified / not claimed**

- No physical device; only an x86_64 emulator with software rendering. On it, the first link took about
  two minutes (starting Python and the JS runtime is slow there). Real phones should be much faster,
  but that was not measured.
- Only YouTube was run. Facebook, TikTok, X and Instagram go through the same engine but were not
  exercised, and they are the sites most likely to need login or change often.
- YouTube can refuse requests from some networks ("confirm you're not a bot"). Namao reports this
  plainly and does not try to get around it.
- 16 KB-page-size devices: the engine library has an open upstream issue (a few bundled WebP libraries
  are 4 KB-aligned) that can crash FFmpeg's first use on such devices. Untested here (the emulator uses
  4 KB pages).
- Several downloads at once (the code allows it) was not stress-tested.
- Release signing was the debug-key fallback; the production keystore path was not exercised.
- TalkBack, tablets and landscape were not re-run; widget tests cover layouts and semantics.

## Known limits

- Android 10+ only.
- yt-dlp is refreshed from its official release at most once a day, when the phone is online. If that
  fails (offline, blocked), the last installed version is used and sites may stop working until the
  next successful refresh.
- Honest product limits: personal use of videos you are allowed to download; no DRM or login bypass.
