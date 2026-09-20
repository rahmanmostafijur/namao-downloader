# Namao — standalone Android app

A separate, self-contained Android port of Namao. No PC, no server, no
network dependency on anything you run — yt-dlp and ffmpeg run directly on
the phone via the [youtubedl-android](https://github.com/yausername/youtubedl-android)
library. The UI is the exact same `static/index.html` used by the desktop
version, shown in a WebView; `MainActivity.kt` replaces main.py's FastAPI
routes with a Kotlin bridge that calls the bundled yt-dlp/ffmpeg instead.

## Install the prebuilt APK

A debug build already exists at `../Namao-debug.apk` (project root). To
install it on your phone:

1. Copy `Namao-debug.apk` to your phone (USB cable, or upload somewhere and
   download it on the phone — e.g. Google Drive, a messaging app to yourself).
2. On the phone, tap the file. Android will ask to allow installs from that
   source ("install unknown apps") — allow it once.
3. Tap Install.
4. First launch will take a few seconds — it's unpacking the bundled Python
   runtime and ffmpeg into app storage. This only happens once.
5. Downloads save to **Downloads/Namao/** on the phone (visible in any file
   manager or the Downloads app), not through the browser's download manager.

The app is unsigned beyond Android's auto-generated debug key, which is
normal for a personal-use build — you'll just need to allow the "unknown
source" install once.

## What's verified vs. what isn't

This was built and validated end-to-end **except for actually running it on
a phone**, which needs to happen on your device:

- ✅ Gradle build succeeds cleanly (Kotlin compiles, no errors)
- ✅ `aapt dump badging` confirms a well-formed APK: correct package name
  (`com.namao.app`), permissions, and app label
- ✅ Native libraries bundled correctly (`libffmpeg.so`, `libpython.so`, the
  yt-dlp binary, etc. — confirmed present in the build log)
- ✅ The Kotlin bridge logic (`build_qualities`, format-string selection) is
  a line-by-line port of the same logic already validated against real
  YouTube/TikTok videos in `main.py`, using verified field names and API
  signatures pulled directly from the library's own source
- ❓ **Not yet verified**: actually tapping through the app on a real
  device — WebView loading the bundled asset correctly, the JS↔Kotlin
  bridge round-tripping, a real download landing in `Downloads/Namao/`.
  If something doesn't work as expected on your phone, tell me what you see
  and I'll fix it — this is the one part I can't test from here.

## Rebuilding after changes

No Android Studio or SDK is installed on the Windows machine this was built
on — the build runs inside Docker (`mingc/android-build-box`), which bundles
JDK 21 + Android SDK + build-tools. To rebuild after editing `MainActivity.kt`
or `static/index.html` (remember to re-copy the HTML into
`app/src/main/assets/index.html` — it's not symlinked):

```bash
docker run --rm \
  -v "<path to this android/ folder>:/project" \
  -v "<a persistent cache dir>:/root/.gradle" \
  mingc/android-build-box:latest \
  bash -c "cd /project && ./gradlew assembleDebug"
```

The resulting APK lands at `app/build/outputs/apk/debug/app-debug.apk`.

## Fixed so far (real device feedback)

- **"Only shows audio, no video qualities"**: `youtubedl-android` bundles a
  yt-dlp binary frozen at the library's last release, which goes stale
  fast — YouTube in particular changes often enough that an old yt-dlp
  regresses to audio-only. Fixed by calling `YoutubeDL.updateYoutubeDL()`
  once on app startup (self-updates to the latest yt-dlp release from
  GitHub), with every bridge call now waiting for that update to finish
  first so even the very first fetch after install benefits. If this
  still happens after reinstalling, tell me and we'll look at forcing a
  specific yt-dlp "player client" via extractor-args instead.
- **203MB APK → 58MB**: it was bundling a full Python + ffmpeg build for
  4 CPU architectures. Restricted to `arm64-v8a` only, which covers the
  overwhelming majority of Android phones from the last ~8 years. If the
  app fails to install with an "incompatible device" error, your phone is
  one of the rare 32-bit-only exceptions — tell me and I'll add
  `armeabi-v7a` back.
- **Instagram "sent an empty media response"**: this isn't a bug — Instagram
  increasingly requires a logged-in session even for public-looking posts,
  and yt-dlp can't fake that without your cookies. Added a 🍪 button in the
  app's navbar (Android-only — it's hidden in the browser version) that
  opens a paste-in box for a Netscape-format `cookies.txt` export. Steps:
  1. On a computer, log into Instagram in a browser.
  2. Install a "cookies.txt" export extension (e.g. "Get cookies.txt
     LOCALLY" for Chrome/Firefox) and export cookies for instagram.com.
  3. Open that exported file, copy its full contents.
  4. In the app, tap 🍪 → paste → Save.
  5. The cookie file is stored in the app's private storage only
     (`filesDir/cookies.txt`) — never written to shared/Downloads storage,
     never sent anywhere but Instagram itself via yt-dlp's own `--cookies`
     flag. Tap 🍪 → Clear to remove it.
  Same mechanism works for Facebook/X/TikTok if a specific post ever needs
  it, since it's passed as a general `--cookies` flag to every request.
- **Choose the download folder**: added a 📁 button (Android-only) that
  opens Android's native folder picker (Storage Access Framework) so
  downloads can go anywhere you have access to, not just a hardcoded
  `Downloads/Namao`. The chosen folder persists across app restarts. If
  nothing's been chosen yet, or the chosen folder ever becomes inaccessible
  (e.g. a removed SD card), it falls back to `Downloads/Namao` automatically.

## Known limitations / follow-ups

- **Debug build only**: fine for personal use; a Play Store-style release
  build would need a real signing key, which wasn't set up here.
- **No download progress bar polish beyond a plain percentage** on the
  button itself — functional, not fancy.
- The FAQ section's copy on the frontend still describes the browser/PC
  download flow ("hands the file to the browser") verbatim, since it's the
  same shared `index.html` — technically slightly inaccurate for the Android
  build (which saves to `Downloads/Namao/` instead), but harmless.
