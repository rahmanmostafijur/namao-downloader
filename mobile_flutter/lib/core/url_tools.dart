/// Platforms Namao supports (same hosts as the web client's `detectPlatform`). The downloader
/// only reads these sites, so a link to anything else is refused before any work starts.
enum SourcePlatform {
  youtube('YouTube', ['youtube.com', 'youtu.be', 'youtube-nocookie.com']),
  facebook('Facebook', ['facebook.com', 'fb.watch', 'fb.com']),
  tiktok('TikTok', ['tiktok.com']),
  twitter('X / Twitter', ['twitter.com', 'x.com']),
  instagram('Instagram', ['instagram.com']);

  const SourcePlatform(this.label, this.hosts);

  final String label;
  final List<String> hosts;

  /// Maps a `platform` string (e.g. "youtube") when it matches a known one.
  static SourcePlatform? fromName(String name) {
    final lower = name.toLowerCase();
    for (final platform in SourcePlatform.values) {
      if (platform.name == lower) return platform;
    }
    return null;
  }
}

const String unsupportedLinkMessage =
    "That link doesn't look like YouTube, Facebook, TikTok, X/Twitter or Instagram.";

const String incompleteLinkMessage = 'Paste a complete video link.';

/// Lower-cased host of [value], adding `https://` when the scheme is missing. Empty if none.
String hostOf(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  final withScheme = text.contains('://') ? text : 'https://$text';
  final uri = Uri.tryParse(withScheme);
  if (uri == null) return '';
  final host = uri.host.toLowerCase();
  return host.endsWith('.') ? host.substring(0, host.length - 1) : host;
}

SourcePlatform? detectPlatform(String value) {
  final host = hostOf(value);
  if (host.isEmpty) return null;
  for (final platform in SourcePlatform.values) {
    for (final domain in platform.hosts) {
      if (host == domain || host.endsWith('.$domain')) return platform;
    }
  }
  return null;
}

/// Outcome of checking a pasted video link before any request is made.
class VideoUrlCheck {
  const VideoUrlCheck({this.url, this.platform, this.error});

  /// The link to send (with a scheme). Null when [error] is set or the field is empty.
  final String? url;
  final SourcePlatform? platform;
  final String? error;

  bool get isValid => url != null && error == null;
}

/// Verification builds only (`--dart-define=NAMAO_ALLOW_ANY_LINK=true`): skip the platform check
/// (here and in the downloader's allow-list) so a local rights-free test stream can be used.
/// Always false in normal builds.
const bool kAllowAnyLink = bool.fromEnvironment('NAMAO_ALLOW_ANY_LINK');

VideoUrlCheck checkVideoUrl(String raw, {bool allowAnyHost = kAllowAnyLink}) {
  final text = raw.trim();
  if (text.isEmpty) return const VideoUrlCheck();
  if (text.contains(RegExp(r'\s'))) {
    return const VideoUrlCheck(error: incompleteLinkMessage);
  }
  final withScheme = text.contains('://') ? text : 'https://$text';
  final uri = Uri.tryParse(withScheme);
  final scheme = uri?.scheme;
  if (uri == null ||
      uri.host.isEmpty ||
      (!allowAnyHost && !uri.host.contains('.')) ||
      (scheme != 'http' && scheme != 'https')) {
    return const VideoUrlCheck(error: incompleteLinkMessage);
  }
  final platform = detectPlatform(withScheme);
  if (platform == null && allowAnyHost) return VideoUrlCheck(url: withScheme);
  if (platform == null) {
    return const VideoUrlCheck(error: unsupportedLinkMessage);
  }
  return VideoUrlCheck(url: withScheme, platform: platform);
}
