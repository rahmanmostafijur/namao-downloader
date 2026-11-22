// Version parsing and ordering for the two things that update: the downloader (dated versions
// such as `2026.11.10`) and the app (`1.2.3`, tagged `v1.2.3`).

final RegExp _engineVersion = RegExp(
  r'^(\d{4})\.(\d{1,2})\.(\d{1,2})(?:\.(\d+))?$',
);
final RegExp _appVersion = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$');
final RegExp _installedApp = RegExp(r'^(\S+)\s+\((\d+)\)$');

List<int>? parseEngineVersion(String? text) {
  final match = _engineVersion.firstMatch(text?.trim() ?? '');
  if (match == null) return null;
  return [for (var i = 1; i <= 4; i++) int.tryParse(match.group(i) ?? '') ?? 0];
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// Whether [latest] should replace [installed]. An installed version that cannot be read counts as
/// older (the downloader is replaced), a latest one that cannot be read never wins.
bool isNewerEngineVersion(String latest, String? installed) {
  final wanted = parseEngineVersion(latest);
  if (wanted == null) return false;
  final current = parseEngineVersion(installed);
  return current == null || _compare(wanted, current) > 0;
}

/// The release date a downloader version stands for, or null when it is not a dated version.
DateTime? engineVersionDate(String? version) {
  final parts = parseEngineVersion(version);
  if (parts == null) return null;
  try {
    return DateTime(parts[0], parts[1], parts[2]);
  } on Object {
    return null;
  }
}

/// `v1.2.3` or `1.2.3` as "1.2.3"; null for anything else (a tag like `nightly` is not a release).
String? appVersionName(String? text) {
  final match = _appVersion.firstMatch(text?.trim() ?? '');
  if (match == null) return null;
  return '${match.group(1)}.${match.group(2)}.${match.group(3)}';
}

bool isNewerAppVersion(String latest, String installed) {
  final wanted = appVersionName(latest)?.split('.').map(int.parse).toList();
  final current = appVersionName(installed)?.split('.').map(int.parse).toList();
  if (wanted == null || current == null) return false;
  return _compare(wanted, current) > 0;
}

/// The app version as the native side reports it: "1.1.0 (3)".
typedef InstalledApp = ({String name, int code});

InstalledApp? parseInstalledApp(String? text) {
  final match = _installedApp.firstMatch(text?.trim() ?? '');
  if (match == null) return null;
  return (name: match.group(1)!, code: int.parse(match.group(2)!));
}
