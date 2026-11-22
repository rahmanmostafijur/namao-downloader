import 'dart:async';
import 'dart:io';

import '../../core/url_tools.dart';

/// Why a short or share link could not be turned into the real video link. [code] is one of the
/// app's failure codes: `link_unresolved`, `auth_required` or `network_transient`.
class LinkResolveException implements Exception {
  const LinkResolveException(this.code);

  final String code;

  @override
  String toString() => 'LinkResolveException($code)';
}

/// Asks one URL where it redirects to. Abstract so the rules below are testable without a network.
abstract class RedirectFetcher {
  /// The `Location` of a 3xx answer, or null when the answer is not a redirect.
  Future<String?> locationOf(Uri url);
}

const String _browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/126.0.0.0 Mobile Safari/537.36';

/// One GET per hop with redirects switched off, so this code (not the HTTP client) decides
/// whether each hop is acceptable. The body is never read: the socket is closed straight after
/// the headers.
class HttpRedirectFetcher implements RedirectFetcher {
  const HttpRedirectFetcher({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  @override
  Future<String?> locationOf(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = _browserUserAgent;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      final response = await request.close().timeout(timeout);
      final isRedirect =
          response.statusCode >= 300 && response.statusCode < 400;
      return isRedirect
          ? response.headers.value(HttpHeaders.locationHeader)
          : null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Turns fb.watch and Facebook / Instagram "share" links into the canonical video link that
/// yt-dlp understands. The downloader itself never follows arbitrary redirects (its generic
/// "fetch any URL" extractor is disabled on purpose), so the few redirect-style links are
/// followed here, under strict rules: at most [maxHops] hops, HTTPS only, every hop must stay on
/// the same platform's own hosts with no embedded credentials or odd ports, and a hop to a
/// login page is reported as such rather than followed.
class LinkResolver {
  LinkResolver({RedirectFetcher? fetcher, this.maxHops = 5})
    : _fetcher = fetcher ?? const HttpRedirectFetcher();

  final RedirectFetcher _fetcher;
  final int maxHops;

  /// A resolved link is reused (the same link is read once to look it up, again to download it).
  final Map<String, String> _resolved = {};

  /// [url] unchanged when it is already a canonical link; otherwise the link it leads to.
  Future<String> resolve(String url) async {
    final start = Uri.tryParse(url);
    if (start == null || !needsRedirectResolution(start)) return url;
    final known = _resolved[url];
    if (known != null) return known;

    final platform = detectPlatform(url);
    var current = start;
    for (var hop = 0; hop < maxHops; hop++) {
      final String? location;
      try {
        location = await _fetcher.locationOf(current);
      } on SocketException {
        throw const LinkResolveException('network_transient');
      } on TimeoutException {
        throw const LinkResolveException('network_transient');
      } on HttpException {
        throw const LinkResolveException('network_transient');
      } on TlsException {
        throw const LinkResolveException('network_transient');
      }
      if (location == null || location.isEmpty) {
        throw const LinkResolveException('link_unresolved');
      }
      final next = _checkedHop(current, location, platform);
      if (_isLoginPage(next)) throw const LinkResolveException('auth_required');
      if (!needsRedirectResolution(next)) {
        final resolved = next.toString();
        _resolved[url] = resolved;
        return resolved;
      }
      current = next;
    }
    throw const LinkResolveException('link_unresolved');
  }

  /// The next hop, or a failure when it is not a safe place to go.
  Uri _checkedHop(Uri from, String location, SourcePlatform? platform) {
    final Uri target;
    try {
      target = from.resolve(location);
    } on FormatException {
      throw const LinkResolveException('link_unresolved');
    }
    final upgraded = target.scheme == 'http'
        ? target.replace(scheme: 'https')
        : target;
    final safe =
        upgraded.scheme == 'https' &&
        upgraded.userInfo.isEmpty &&
        (!upgraded.hasPort || upgraded.port == 443) &&
        detectPlatform(upgraded.toString()) == platform;
    if (!safe) throw const LinkResolveException('link_unresolved');
    return normalizeSourceUrl(upgraded);
  }

  bool _isLoginPage(Uri uri) {
    final path = uri.path;
    return path.startsWith('/login') ||
        path.startsWith('/accounts/login') ||
        path.startsWith('/checkpoint');
  }
}
