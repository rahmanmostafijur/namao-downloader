# The Android downloader engine

The Android app (`mobile_flutter/`) downloads on the phone. This page records which engine it uses, why, what
that means for the licence, how the engine is kept current, and what is not yet proven. The web and desktop
clients are unaffected: they still use the Python server.

## What runs on the phone

[youtubedl-android](https://github.com/yausername/youtubedl-android) 0.18.1 (`library` and `ffmpeg` artifacts):
a Python 3.12 runtime, a yt-dlp build, a QuickJS JavaScript runtime (YouTube needs one) and an FFmpeg build,
all packaged as native libraries. `LocalEngine.kt` starts them as processes; all decisions (yt-dlp options,
format list, progress, error wording) are in Dart (`lib/data/engine/`). The same quality rules and format
selectors as the Python server are used, so every client offers the same choices for a link.

## Why this engine

| Option | Verdict |
|---|---|
| **youtubedl-android 0.18.1** | **Used.** Last release Nov 2025 with a yt-dlp bump, and open issues as recent as Nov 2026, so it is alive but slow-moving. Ships a current Python (3.12, although its README still says 3.8: issue #362), QuickJS and FFmpeg, supports cancelling a process, and has done 16 KB-page-size work. The old native app in `android/` already embeds it. Cost: about 45 MB per ABI. |
| `ytdlp_flutter` (pub.dev) | Not used. v0.1.0, created Aug 2026, no stars, one author: too young to trust with the core feature. |
| Own Kotlin integration (Chaquopy + yt-dlp + an FFmpeg build) | Not used. Would reproduce most of what youtubedl-android already packages, plus the build and maintenance of the FFmpeg binaries. |
| A second backend on the phone | Excluded by the brief. |

## Licence: read this before distributing the APK

youtubedl-android is **GPL-3.0**. An app that bundles it and is distributed (for example the APK on GitHub
Releases) must itself be offered under terms compatible with GPL-3.0, with its source available. The pieces:

- yt-dlp: The Unlicense (public domain). FFmpeg: LGPL-2.1+/GPL-2+ depending on the build. Python: PSF.
  QuickJS: MIT. The Python packages inside the Python build keep their own licences.
- The repository is public, so the source is available, **but it currently has no `LICENSE` file**. Without
  one, nobody (including the GPL's recipients) has a clear grant. **Decision needed from the owner:** add a
  GPL-3.0-compatible licence (simplest: GPL-3.0 for the repository, or GPL-3.0 for `mobile_flutter/` only)
  before publishing a release that contains the engine. This was not done here because choosing the licence
  for the project is the owner's call.
- The app shows the required notices under **Settings > Open-source licenses** (`assets/licenses/`), including
  the full GPL-3.0 text.
- Google Play has its own policies for downloader apps; the project distributes through GitHub Releases.

## Keeping yt-dlp current

Sites change constantly, and the yt-dlp bundled in the library (2025.11.12) is already months old. So at
launch `LocalEngine.kt` downloads yt-dlp's latest release file directly from
`github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp`, checks it against the release's published
`SHA2-256SUMS`, and swaps it in atomically. It does this on a fresh install (waiting up to 60 s) and then at
most once a day in the background. If it fails, the last installed yt-dlp keeps working.

(Refresh policy, safety and rollback are described in [updates.md](updates.md).) The library's own updater was not used: it goes through the GitHub REST API, which allows 60 anonymous
requests per hour per address, and it failed in testing for that reason.

Limits: the checksum and the file come from the same GitHub release, so this guards against corruption and
truncation, not against a compromised release. The stable channel is used; switch `RELEASE_URL` to the
nightly builds if sites break faster than stable releases land.

## Known risks

- Python and QuickJS start slowly on the test emulator (about two minutes for the first link). Not measured
  on a physical device.
- 16 KB-page-size devices: upstream issue #365 (some WebP libraries inside the FFmpeg bundle are 4 KB-aligned)
  can crash FFmpeg's first use there. Check it before targeting Android 15+ devices with 16 KB pages.
- Swiping the app away stops a running download (it shows as Interrupted, with Retry).
- Only YouTube was exercised on a device. Other sites use the same engine but are untested.
- Size: per-ABI APKs are about 55 MB (armeabi-v7a), 62 MB (arm64-v8a) and 65 MB (x86_64); a universal APK is
  about 155 MB. The release workflow builds and publishes the arm64-v8a APK only
  (`flutter build apk --release --target-platform android-arm64`), so it will not install on 32-bit-only phones
  or x86 emulators; build those yourself from source if you need them.
