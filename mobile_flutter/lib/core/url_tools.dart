/// Platforms Namao supports (same hosts as the web client's `detectPlatform`). The downloader
/// only reads these sites, so a link to anything else is refused before any work starts.
enum SourcePlatform {
  youtube('YouTube', ['youtube.com', 'youtu.be', 'youtube-nocookie.com']),
  facebook('Facebook', ['facebook.com', 'fb.watch', 'fb.com']),
  tiktok('TikTok', ['tiktok.com']),
  twitter('X / Twitter', ['twitter.com', 'x.com']),
  instagram('Instagram', ['instagram.com', 'instagr.am']);

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

/// Shown only for a link whose host belongs to none of the supported sites. A supported site's
/// link that fails later is reported by what actually went wrong, never as "unsupported".
const String unsupportedLinkMessage = 'This link is not supported yet.';

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

final RegExp _leadingWrapper = RegExp(r'''^[<(\["']+''');
final RegExp _trailingPunctuation = RegExp(r'''[.,;:!?'")\]}>”’]+$''');

/// The link inside text pasted from a chat or caption: surrounding whitespace, wrapping quotes or
/// brackets and sentence punctuation after the link are dropped; the link itself (path, query,
/// fragment) is untouched.
String cleanLink(String raw) => raw
    .trim()
    .replaceFirst(_leadingWrapper, '')
    .replaceFirst(_trailingPunctuation, '');

bool _isHostOrSubdomain(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// Rewrites a recognised link to the form the downloader understands, changing nothing else
/// (query and fragment survive). Facebook's `/reels/<id>` is the reel page that `/reel/<id>`
/// serves; `instagr.am` is Instagram's retired short domain for the same paths.
Uri normalizeSourceUrl(Uri uri) {
  final host = uri.host.toLowerCase();
  if (_isHostOrSubdomain(host, 'instagr.am')) {
    return uri.replace(host: 'www.instagram.com');
  }
  if (_isHostOrSubdomain(host, 'facebook.com')) {
    final reel = RegExp(r'^/reels/(\d+)/?$').firstMatch(uri.path);
    if (reel != null) return uri.replace(path: '/reel/${reel.group(1)}');
  }
  return uri;
}

/// True for links that are HTTP redirects to the real video (fb.watch, Facebook and Instagram
/// "share" links). The downloader reads canonical pages only and never follows arbitrary
/// redirects itself, so these are resolved first (see `LinkResolver`).
bool needsRedirectResolution(Uri uri) {
  final host = uri.host.toLowerCase();
  if (_isHostOrSubdomain(host, 'fb.watch')) return true;
  final isShare = uri.path.startsWith('/share/');
  return isShare &&
      (_isHostOrSubdomain(host, 'facebook.com') ||
          _isHostOrSubdomain(host, 'instagram.com'));
}

/// Plain web links only: no embedded credentials and no unusual port (those are how look-alike
/// links disguise their real destination).
bool _hasSafeAuthority(Uri uri) =>
    uri.userInfo.isEmpty && (!uri.hasPort || uri.port == 80 || uri.port == 443);

VideoUrlCheck checkVideoUrl(String raw, {bool allowAnyHost = kAllowAnyLink}) {
  final text = cleanLink(raw);
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
      (scheme != 'http' && scheme != 'https') ||
      (!allowAnyHost && !_hasSafeAuthority(uri))) {
    return const VideoUrlCheck(error: incompleteLinkMessage);
  }
  final platform = detectPlatform(withScheme);
  if (platform == null && allowAnyHost) return VideoUrlCheck(url: withScheme);
  if (platform == null) {
    return const VideoUrlCheck(error: unsupportedLinkMessage);
  }
  final normalized = normalizeSourceUrl(uri);
  return VideoUrlCheck(
    url: identical(normalized, uri) ? withScheme : normalized.toString(),
    platform: platform,
  );
}
