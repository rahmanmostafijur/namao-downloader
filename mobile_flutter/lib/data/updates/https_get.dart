import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An update download or lookup failed. [code]: `network` (could not reach or complete the
/// transfer), `unreadable` (the answer was not what a release looks like) or `untrusted`.
class AppUpdateException implements Exception {
  const AppUpdateException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AppUpdateException($code, $message)';
}

const int _maxRedirects = 5;
const Duration _connectTimeout = Duration(seconds: 15);
const Duration _idleTimeout = Duration(seconds: 30);

/// Updates come from GitHub only, which serves release files from its own `githubusercontent.com` hosts.
bool isTrustedUpdateHost(String host) =>
    host == 'github.com' ||
    host == 'api.github.com' ||
    host == 'githubusercontent.com' ||
    host.endsWith('.githubusercontent.com');

/// Whether [uri] may be fetched for an update: HTTPS to a trusted host, nothing else.
bool isTrustedUpdateUri(Uri uri) =>
    uri.scheme == 'https' && isTrustedUpdateHost(uri.host);

/// An open response body; closing the stream (finishing or cancelling) closes the connection.
typedef HttpsBody = ({Stream<List<int>> bytes, int? length});

/// GETs [url], following redirects by hand so every hop is checked: HTTPS only, trusted hosts only.
Future<HttpsBody> openHttps(
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = _connectTimeout;
  try {
    var current = url;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (!isTrustedUpdateUri(current)) {
        throw AppUpdateException('untrusted', 'refusing to fetch $current');
      }
      final request = await client.getUrl(current)
        ..followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(_idleTimeout);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw const AppUpdateException(
            'network',
            'redirect without a target',
          );
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppUpdateException(
          'network',
          'HTTP ${response.statusCode} for $current',
        );
      }
      final length = response.contentLength >= 0
          ? response.contentLength
          : null;
      Stream<List<int>> body() async* {
        try {
          yield* response.timeout(_idleTimeout);
        } finally {
          client.close(force: true);
        }
      }

      return (bytes: body(), length: length);
    }
    throw const AppUpdateException('network', 'too many redirects');
  } on SocketException catch (error) {
    client.close(force: true);
    throw AppUpdateException('network', error.message);
  } on TimeoutException {
    client.close(force: true);
    throw const AppUpdateException('network', 'timed out');
  } on HttpException catch (error) {
    client.close(force: true);
    throw AppUpdateException('network', error.message);
  } on Object {
    client.close(force: true);
    rethrow;
  }
}

/// A small text answer (release information, a checksum file), capped so a wrong URL cannot flood memory.
Future<String> fetchHttpsText(
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  const limit = 1024 * 1024;
  final body = await openHttps(url, headers: headers);
  final bytes = <int>[];
  try {
    await for (final chunk in body.bytes) {
      bytes.addAll(chunk);
      if (bytes.length > limit) {
        throw const AppUpdateException('unreadable', 'answer too large');
      }
    }
  } on SocketException catch (error) {
    throw AppUpdateException('network', error.message);
  } on TimeoutException {
    throw const AppUpdateException('network', 'timed out');
  } on HttpException catch (error) {
    throw AppUpdateException('network', error.message);
  }
  return utf8.decode(bytes, allowMalformed: true);
}
