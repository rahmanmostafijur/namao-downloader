# Releasing the Android app

Releases are built by GitHub Actions ([`android-release.yml`](../.github/workflows/android-release.yml)) when a
version tag is pushed, and published as a GitHub Release with the signed APK and its SHA-256 checksum.

## Publish the next version

1. In `mobile_flutter/pubspec.yaml` set `version: X.Y.Z+N`. `X.Y.Z` is the version users see; **`N` is the
   Android build number and must be higher than the last release's** (Android refuses to update to a lower one).
2. Add `docs/release-notes/vX.Y.Z.md` (what changed, known limits). The workflow appends size and checksum itself.
   If the file is missing the release still works, with a one-line body.
3. Run locally: `cd mobile_flutter && flutter analyze && flutter test`.
4. Commit and push to `main`:
   ```bash
   git add -A && git commit -m "release: Android X.Y.Z" && git push origin main
   ```
5. Tag the **same commit** and push the tag:
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
6. Watch it: `gh run watch` (or the Actions tab). On success the release appears under Releases.

The workflow refuses to publish (and leaves no release) when: the tag is not on `main`; the tag differs from the
`pubspec.yaml` version; format, analysis or tests fail; a signing secret is missing; the APK is not verified by
`apksigner`; it is signed with the debug key; or its certificate differs from `ANDROID_CERT_SHA256`.

If a run fails after the tag was pushed, fix the problem on `main`, then move the tag **before any release exists**:
`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`, then tag again. (Never re-tag a version that was already released.)

## Signing key

Android installs an update only if it is signed with the same key as the installed app. **Losing the key means
users must uninstall and reinstall, and you cannot ever publish an in-place update.**

- The keystore was generated outside the repository. Its location and passwords are in
  `credentials.txt` next to it (`%USERPROFILE%\.namao-signing\` on the machine that created it).
  **Back both up** to a password manager or an offline drive. Never commit them.
- GitHub holds it as Actions secrets: `ANDROID_KEYSTORE_BASE64` (the `.jks`, base64), `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; and the *variable* `ANDROID_CERT_SHA256` (the public certificate fingerprint).
- Certificate: `CN=Namao`, RSA 4096, valid until 2054. SHA-256 fingerprint:
  `40:1F:F6:12:39:C7:48:0A:DB:91:6A:5A:94:D6:AC:23:E9:54:E5:12:47:A2:8A:CE:AC:14:94:9A:64:6F:46:C6`
- Local signed build (to verify before tagging):
  ```bash
  export NAMAO_KEYSTORE_PATH=... NAMAO_KEYSTORE_PASSWORD=... NAMAO_KEY_ALIAS=namao NAMAO_KEY_PASSWORD=...
  cd mobile_flutter && flutter build apk --release --target-platform android-arm64   # same as the workflow (arm64-v8a, ~62 MB)
  java -jar "$ANDROID_HOME/build-tools/<version>/lib/apksigner.jar" verify --print-certs build/app/outputs/flutter-apk/app-release.apk
  ```
  Without those variables (or `android/key.properties`) Gradle signs with the **debug** key. That is only for local testing and must never be published.
- To replace a leaked key you must publish under a new key; existing users will have to reinstall.

## Verify a published APK

```bash
sha256sum namao-android.apk          # Windows: certutil -hashfile namao-android.apk SHA256
apksigner verify --print-certs namao-android.apk   # certificate SHA-256 must equal the fingerprint above
```
