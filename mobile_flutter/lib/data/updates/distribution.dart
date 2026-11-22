/// Where this build is distributed, set with `--dart-define=NAMAO_CHANNEL=play`.
///
/// `github` (the default) turns on in-app updates: a refreshed downloader and a newer app, both
/// fetched from GitHub. Google Play forbids an app downloading code that runs, and forbids
/// installing other APKs, so a Play build must set another value: every update check and prompt is
/// then off. (Play builds would use Play's own In-App Updates API instead; see docs/updates.md.)
const String kDistributionChannel = String.fromEnvironment(
  'NAMAO_CHANNEL',
  defaultValue: 'github',
);

const bool kUpdatesEnabled = kDistributionChannel == 'github';

/// The repository whose latest release is the app's update source.
const String kReleaseRepo = 'rahmanmostafijur/namao-downloader';

/// The asset the release workflow publishes (and its `.sha256` companion).
const String kApkAssetName = 'namao-android.apk';
