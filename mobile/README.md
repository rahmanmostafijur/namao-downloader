# Namao mobile (iOS + Android)

A React Native / Expo (SDK 57) client for a **self-hosted Namao server**. The server downloads,
merges and verifies the media; this app pastes or receives a link, shows the real job state
(queued → … → completed), cancels or retries, then fetches the finished file onto the phone and
saves it to the media library or hands it to the share sheet.

It is a client of the same `/api/v1/downloads/*` contract as the web and desktop apps. It does **not**
run yt-dlp on the phone: yt-dlp, FFmpeg and a JS runtime cannot be run on iOS in a supportable way, and the
older standalone Android app in `../android` is a separate project (see `docs/architecture.md`).

## Verified here, and not

| Check | Result (2026-10-20, Windows, Node 24) |
|---|---|
| `npm run typecheck` (strict TypeScript against the real SDK 57 type definitions, including every `expo-*` call) | **passed** |
| `npm test` (17 tests: URL/share parsing, server-address rules, API client, job polling, naming) | **passed** |
| `npm run bundle` (Metro JS bundle, Hermes bytecode, for android **and** ios) | **passed** (641 / 643 modules) |
| `expo prebuild --platform android` (executes the config plugins) | **passed**: manifest contains the `ACTION_SEND text/*` share filter and only `READ_MEDIA_VIDEO` / `READ_MEDIA_AUDIO` / `READ_MEDIA_VISUAL_USER_SELECTED` |
| `expo prebuild --platform ios` (share extension, Info.plist) | **not possible on Windows** (Expo skips iOS prebuild off macOS/Linux): iOS native configuration is **unverified** |
| Native binaries (APK/IPA), running on a device or emulator, the share-sheet and media-library permission flows, background transfers | **not verified**: no Android SDK, Xcode or device available |
| App Store / Play Store publication | **not done** |

## Behaviour you should know about

* **Server-side jobs keep running** when the app is closed or the phone sleeps. Only the last hop
  (server → phone) runs on the device.
* **iOS** can continue that transfer in a background URL session, but if the app is terminated the
  JavaScript side is gone; reopen the app and tap *Save* again (the server keeps the file until it
  expires, one hour by default).
* **Android** ignores the background-session option; the transfer can pause when the system suspends
  the app. There is no notification yet (Android 13+ would need the runtime notification permission).
* **Saving**: *Save to Photos / device* uses the write-only media-library permission. Audio (MP3) is not
  a photo, so on iOS use **Share → Save to Files**.
* **Cleartext**: `http://` is accepted only for local-network servers (10.x, 172.16–31.x, 192.168.x,
  `localhost`, `*.local`); anything else must be `https://`. The API key is stored in the
  keychain/keystore and sent as a header, never in a URL.
* **Share intent** uses the community plugin `expo-share-intent`, which targets Expo SDK 57; that is why the app
  is pinned to SDK 57 rather than 58. Upgrade both together.

## Run it

```bash
cd mobile
npm install
npx expo start            # development build / Expo Go limits apply to native plugins
npm run typecheck && npm test
npm run bundle            # JS bundle for both platforms (no native toolchain needed)
```

Native builds need a development build or EAS (`eas build`), Xcode for iOS and the Android SDK for Android.
