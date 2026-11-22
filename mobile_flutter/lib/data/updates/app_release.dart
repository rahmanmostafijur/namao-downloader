import 'dart:convert';

import 'distribution.dart';
import 'https_get.dart';
import 'versions.dart';

/// A published Namao release that has an APK.
class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.notes,
    required this.apkUrl,
    required this.pageUrl,
    this.sha256,
    this.sizeBytes,
  });

  /// "1.2.0" (the release tag without its `v`).
  final String versionName;

  /// A few plain-language lines for the update prompt.
  final String notes;
  final Uri apkUrl;

  /// The release page, for installing by hand when the in-app install cannot go ahead.
  final Uri pageUrl;

  /// Lower-case hex SHA-256 the release publishes for the APK, when it does.
  final String? sha256;
  final int? sizeBytes;
}

/// Where releases come from. Abstract so the update logic is testable without the network.
abstract class AppReleaseSource {
  /// The latest published release that has an APK, or null when there is none.
  Future<AppRelease?> latest();
}

typedef TextFetcher = Future<String> Function(Uri uri);

/// Reads the repository's latest GitHub Release (never a draft or pre-release).
class GithubReleaseSource implements AppReleaseSource {
  GithubReleaseSource({TextFetcher? fetch})
    : _fetch = fetch ?? ((uri) => fetchHttpsText(uri, headers: _headers));

  static const Map<String, String> _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Namao-Android',
  };

  final TextFetcher _fetch;

  static final Uri latestUri = Uri.https(
    'api.github.com',
    '/repos/$kReleaseRepo/releases/latest',
  );

  @override
  Future<AppRelease?> latest() async {
    final Object? json;
    try {
      json = jsonDecode(await _fetch(latestUri));
    } on FormatException {
      throw const AppUpdateException(
        'unreadable',
        'release information is not JSON',
      );
    }
    if (json is! Map) {
      throw const AppUpdateException('unreadable', 'unexpected release shape');
    }
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'] as String?;
    final versionName = appVersionName(tag);
    if (tag == null || versionName == null) return null;

    final assets = <String, Map<Object?, Object?>>{
      for (final asset in (json['assets'] as List?) ?? const [])
        if (asset is Map && asset['name'] is String)
          asset['name'] as String: asset,
    };
    final apk = assets[kApkAssetName];
    final apkUrl = Uri.tryParse(
      (apk?['browser_download_url'] as String?) ?? '',
    );
    if (apk == null || apkUrl == null || !isTrustedUpdateUri(apkUrl)) {
      return null; // a release without an APK is not an update for this app
    }
    return AppRelease(
      versionName: versionName,
      notes: summarizeNotes(json['body'] as String?),
      apkUrl: apkUrl,
      pageUrl: _pageUrl(json['html_url'] as String?, tag),
      sha256: await _checksum(assets),
      sizeBytes: (apk['size'] as num?)?.toInt(),
    );
  }

  Uri _pageUrl(String? given, String tag) {
    final uri = Uri.tryParse(given ?? '');
    if (uri != null && isTrustedUpdateUri(uri)) return uri;
    return Uri.https('github.com', '/$kReleaseRepo/releases/tag/$tag');
  }

  /// The published `.sha256` file wins; GitHub's own recorded digest of the asset is the fallback.
  /// A checksum file that exists but cannot be read stops the update rather than skipping the check.
  Future<String?> _checksum(Map<String, Map<Object?, Object?>> assets) async {
    final file = assets['$kApkAssetName.sha256'];
    if (file != null) {
      final url = Uri.tryParse((file['browser_download_url'] as String?) ?? '');
      if (url == null || !isTrustedUpdateUri(url)) {
        throw const AppUpdateException('untrusted', 'checksum file location');
      }
      final found = _hex.firstMatch((await _fetch(url)).trim())?.group(0);
      if (found == null) {
        throw const AppUpdateException(
          'unreadable',
          'checksum file is not a SHA-256',
        );
      }
      return found.toLowerCase();
    }
    final digest = assets[kApkAssetName]?['digest'] as String?;
    final fromDigest = digest != null && digest.startsWith('sha256:')
        ? digest.substring(7)
        : null;
    return fromDigest != null && _hexOnly.hasMatch(fromDigest)
        ? fromDigest.toLowerCase()
        : null;
  }

  static final RegExp _hex = RegExp(r'^[0-9a-fA-F]{64}');
  static final RegExp _hexOnly = RegExp(r'^[0-9a-fA-F]{64}$');
}

/// Lines that name the internal technology are dropped: people are told what got better, not how.
final RegExp _technical = RegExp(
  r'yt-?dlp|ffmpeg|python|backend|\bserver\b|quickjs',
  caseSensitive: false,
);

/// A few plain lines from release notes: headings, the download table and link URLs go.
String summarizeNotes(String? body, {int maxChars = 360}) {
  if (body == null) return '';
  var text = body.replaceAll('\r', '');
  final table = RegExp(
    r'^##\s+Download and verify',
    multiLine: true,
  ).firstMatch(text);
  if (table != null) text = text.substring(0, table.start);
  final lines = <String>[];
  for (final raw in text.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('|')) continue;
    line = line
        .replaceFirst(RegExp(r'^[-*]\s+'), '• ')
        .replaceAll('**', '')
        .replaceAll('`', '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
    if (_technical.hasMatch(line)) continue;
    lines.add(line);
  }
  final joined = lines.join('\n');
  return joined.length <= maxChars
      ? joined
      : '${joined.substring(0, maxChars).trimRight()}…';
}
