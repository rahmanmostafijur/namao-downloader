/// Platforms the server accepts. The server is the authority; detection here is a UI hint
/// (same hosts as the web client's `detectPlatform`).
enum SourcePlatform {
  youtube('YouTube', ['youtube.com', 'youtu.be', 'youtube-nocookie.com']),
  facebook('Facebook', ['facebook.com', 'fb.watch', 'fb.com']),
  tiktok('TikTok', ['tiktok.com']),
  twitter('X / Twitter', ['twitter.com', 'x.com']),
  instagram('Instagram', ['instagram.com']);

  const SourcePlatform(this.label, this.hosts);

  final String label;
  final List<String> hosts;

  /// Maps the server's `platform` string (e.g. "youtube") when it matches a known one.
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

/// Verification builds only (`--dart-define=NAMAO_ALLOW_ANY_LINK=true`): skip the client-side
/// platform hint so a test server can be pointed at a local rights-free stream. The server stays the
/// authority on what it accepts. Always false in normal builds.
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

/// Result of normalising the user's server address.
class ServerUrlResult {
  const ServerUrlResult({this.url, this.error});

  final String? url;
  final String? error;

  bool get isValid => url != null;
}

/// Requires an explicit http/https scheme and a host, drops trailing slashes, and refuses
/// credentials, queries and fragments (the API key has its own field and never goes in a URL).
ServerUrlResult normalizeServerUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const ServerUrlResult(error: 'Enter the server address.');
  }
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return const ServerUrlResult(
      error: 'Start with http:// or https://, for example http://192.168.1.20:8000',
    );
  }
  if (uri.host.isEmpty) {
    return const ServerUrlResult(error: 'The address is missing a host name.');
  }
  if (uri.userInfo.isNotEmpty) {
    return const ServerUrlResult(
      error: 'Remove the user name or password from the address. Use the API key field instead.',
    );
  }
  if (uri.hasQuery || uri.hasFragment) {
    return const ServerUrlResult(
      error: 'Remove everything after the address (no "?" or "#" parts).',
    );
  }
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  final port = uri.hasPort ? ':${uri.port}' : '';
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return ServerUrlResult(url: '${uri.scheme}://$host$port$path');
}

/// True for loopback, RFC 1918, link-local, CGNAT-free local names and IPv6 ULA/link-local:
/// addresses where plain http is a normal LAN setup.
bool isPrivateHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.localhost')) {
    return true;
  }
  if (!h.contains('.') && !h.contains(':')) {
    return true; // single-label LAN name
  }
  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
      .firstMatch(h);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!);
    final b = int.parse(v4.group(2)!);
    return a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
  if (h.contains(':')) {
    return h == '::1' ||
        h.startsWith('fc') ||
        h.startsWith('fd') ||
        h.startsWith('fe80');
  }
  return false;
}

/// True when [serverUrl] is plain http to an address that is not on a private network.
bool needsCleartextWarning(String serverUrl) {
  final uri = Uri.tryParse(serverUrl);
  if (uri == null || uri.scheme != 'http') return false;
  return !isPrivateHost(uri.host);
}

/// "host:port" for messages that name the server.
String serverLabel(String serverUrl) {
  final uri = Uri.tryParse(serverUrl);
  if (uri == null || uri.host.isEmpty) return serverUrl;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}
