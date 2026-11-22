# Updates in the Android app

Two things update independently, and they never share a mechanism:

| | What | Needs a new APK? | Where it lives |
|---|---|---|---|
| **Download support** | the bundled downloader (yt-dlp), refreshed when sites change | no | `EngineUpdates.kt` (mechanics), `lib/data/updates/engine_*` + `lib/features/updates/engine_update_controller.dart` (policy) |
| **The app** | a newer Namao release from GitHub | yes, installed through Android | `lib/data/updates/app_release.dart`, `apk_*`, `lib/features/updates/app_update_controller.dart`, `AppUpdates.kt` |

People only ever see "download support" and "Namao"; no screen names the downloader, its version string, or its
tools. Technical detail goes to the developer log (`developer.log`, names `namao.update` / `namao.engine`; Logcat tag
`NamaoEngine` / `NamaoUpdate`).

## Download support (the downloader)

**One updater.** The library's own `updateYoutubeDL()` goes through the GitHub REST API (60 anonymous requests an hour
per address) and failed in testing, so the app always used its own direct download. That code was kept and
extended, not duplicated: `EngineUpdates.kt` is the former `LocalEngine.updateNow()` plus the guarantees below.

- **Stable only.** The newest version is read from the redirect of `github.com/yt-dlp/yt-dlp/releases/latest`
  (no API, no token). Nightly builds live in another repository and are never used.
- **When.** At launch, at most once every 24 hours, only if "Update download support automatically" is on (default
  on). A failed attempt is retried after 3 hours, not on every launch. "Check for updates" in Settings always runs.
  A fresh install updates once before the first link (existing behaviour, now also behind the switch).
- **Only newer.** The installed version is compared with the latest (dated versions); equal or older is "up to date"
  and nothing is downloaded.
- **Never during a download.** Every engine process (a download, a link lookup) holds the read side of one lock; the
  swap needs the write side, so it cannot happen under a running process (`busy`). Dart also refuses while the
  Downloads tab has active items. A download that starts during the (seconds-long) swap simply waits for it.
- **Safe swap.** The file is downloaded next to the old one, its SHA-256 is checked against the release's
  `SHA2-256SUMS`, the working engine is copied to `yt-dlp.previous`, and the new file replaces it atomically.
- **Verified.** The new engine must start and report the version that was asked for. Otherwise the previous file is
  copied back and the update reports a failure; the app keeps the engine that worked.
- **Interrupted updates.** On the next start, a half-downloaded file is removed, and if the installed engine does not
  start, `yt-dlp.previous` is restored (`EngineUpdates.recover()`).
- **Progress** is read while the update runs (download 0-90 %, swap and check the rest).
- **Messages.** Success: "Namao's download support has been updated. We've improved download compatibility and
  reliability." Failures are plain sentences (offline, downloads running, "kept the version that works").
  Automatic attempts that fail stay silent.

State (SharedPreferences `namao_engine`): `auto_update`, `last_check_ms`, `last_update_attempt_ms`, `last_update_ms`
(unchanged from earlier builds), `previous_version`.

## The app

- **Source.** The repository's latest GitHub Release (`api.github.com/repos/<repo>/releases/latest`), never a draft
  or pre-release. It must carry `namao-android.apk`; its checksum comes from `namao-android.apk.sha256` (published by
  the release workflow) or, failing that, the digest GitHub records for the asset. A checksum file that exists but
  cannot be read stops the update.
- **When.** At launch, at most once every 24 hours, and from "Check for updates".
- **Newer.** The release tag is compared with the installed version name. The version code and the minimum Android
  version are checked on the phone against the downloaded file (see below), because the release does not publish them.
- **Prompt.** New version, a few plain lines of release notes (headings, the download table and lines that name the
  internal technology are dropped), **Update** and **Remind me later**. Remind me later silences that release for 7
  days; a newer release prompts at once. Settings always offers the update.
- **Download.** HTTPS only, to `github.com` / `*.githubusercontent.com` only, every redirect re-checked; size and
  SHA-256 verified; a bad file is deleted and never reaches the installer. Cancelable.
- **Install.** Through Android's `PackageInstaller` session. It always shows Android's own confirmation screen
  (`USER_ACTION_REQUIRED`); nothing installs silently. First the app checks that the file is this app, has a higher
  version code, fits this Android version, and is signed by the same certificate (or a rotation of it). If the
  per-app "install unknown apps" switch is off, Android's switch screen opens and the person is told to come back.
- **Fallback.** If installing here cannot work (permission, a file Android would refuse, an installer failure) the
  prompt explains and offers **Open download page**, where the file can be downloaded and opened by hand.
- **Never during downloads.** Installing restarts the app, so it is refused while downloads are active, and checked
  again after the file arrives.
- **Data.** The same application ID and signing key keep history and settings. Update files live in `cache/updates`,
  emptied before every download.
- `REQUEST_INSTALL_PACKAGES` is the only permission added; Android requires it for this flow.

## Google Play

Google Play's policies forbid an app from downloading code that runs (the refreshed downloader is a Python script
run by the bundled interpreter) and from installing APKs outside the store. **A Play build must not ship this.**

- Build with `--dart-define=NAMAO_CHANNEL=play` (`lib/data/updates/distribution.dart`): every check, prompt and the
  Settings section are off. Note that the **first-run refresh and the downloader's own refresh are native**, so a Play
  flavour must also gate `EngineUpdates` on the same flag (not done: there is no Play flavour yet) and remove
  `REQUEST_INSTALL_PACKAGES` (`tools:node="remove"`). Without the refresh a Play build's downloader ages, so a Play
  release needs its own, policy-checked, approach (for example shipping new app builds), and Play's
  **In-App Updates API** for the app itself.
- Re-read the current policy before any Play submission; it was not re-checked for this change.

## Licences

The downloader is GPL-3.0 software and the app is GPL-3.0 (`LICENSE`). Refreshing the downloader replaces only the
yt-dlp script (Unlicense) with the official release; the notices shown in Settings > Open-source licenses
(`assets/licenses/`) are unchanged and still cover everything bundled.

## Known limits

- Refreshing the downloader relies on GitHub being reachable; where it is blocked, the bundled version is used.
- The error-wording heuristic "this downloader looks old" reads the version once per launch, so right after a refresh
  it can still judge by the old date until the app restarts.
- The "Remind me later" period (7 days) and the 24 h / 3 h intervals are constants in the controllers and
  `EngineUpdater`.
- Verified automatically: the policy and the Dart side (`mobile_flutter/test/updates/`, 81 tests; the whole suite is 386).
- Verified on an API 36 emulator with the real network: a fresh install refreshed the bundled downloader
  (2025.11.12 to 2026.10.26) and kept the old file as the way back; a deliberately corrupted engine was restored
  from that copy on the next start; **Check for updates** in Settings found and installed the newer downloader and
  showed the friendly message, and a second check said "Everything is up to date" (the app check ran against the
  real GitHub Releases API: 1.1.0 installed, 1.1.0 latest).
- **Not verified:** a physical phone; the Package Installer hand-off against a real newer release (needs a release
  newer than the installed app, signed with the release key); the "never swap under a running download" lock on a
  device (covered by reasoning and review, not by a test: there are no Kotlin tests in this project).
- An app update without a published checksum is not installed from inside the app (the person is sent to the
  release page); the release workflow always publishes one.
- Not done, by choice: the app-update lookup uses the unauthenticated GitHub API (60 requests an hour per address;
  a shared network can see a failed check, shown as "offline" and retried at the next launch); an APK download has
  no size cap when neither the release nor the server states one; the trusted-host rule is the GitHub hosts, not
  this repository's path.
