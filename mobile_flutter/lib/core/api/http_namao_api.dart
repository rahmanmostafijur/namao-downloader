import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/api_error.dart';
import '../models/job.dart';
import '../models/json_read.dart';
import '../models/video_metadata.dart';
import 'api_exception.dart';
import 'namao_api.dart';

const String _prefix = '/api/v1/downloads';
const String _authProbeId = 'connection-check';

/// Timeouts: metadata runs the extractor server-side, so it gets the long one.
class ApiTimeouts {
  const ApiTimeouts({
    this.metadata = const Duration(seconds: 75),
    this.standard = const Duration(seconds: 20),
    this.fileStart = const Duration(seconds: 30),
  });

  final Duration metadata;
  final Duration standard;
  final Duration fileStart;
}

class HttpNamaoApi implements NamaoApi {
  HttpNamaoApi({
    required String baseUrl,
    String? apiKey,
    http.Client? client,
    this.timeouts = const ApiTimeouts(),
  }) : _base = baseUrl,
       _apiKey = (apiKey == null || apiKey.isEmpty) ? null : apiKey,
       _client = client ?? http.Client();

  final String _base;
  final String? _apiKey;
  final http.Client _client;
  final ApiTimeouts timeouts;

  Map<String, String> _headers({String? idempotencyKey, bool json = false}) => {
    'Accept': 'application/json',
    if (json) 'Content-Type': 'application/json',
    'X-API-Key': ?_apiKey,
    'Idempotency-Key': ?idempotencyKey,
  };

  /// Redirects are never followed: Dart would forward X-API-Key to the redirect target. A server
  /// that redirects (for example http to https) gets a clear error instead.
  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(headers ?? _headers());
    if (body != null) request.body = body;
    return http.Response.fromStream(await _client.send(request));
  }

  Uri _uri(String path) => Uri.parse('$_base$path');

  String _jobPath(String id, [String suffix = '']) =>
      '$_prefix/${Uri.encodeComponent(id)}$suffix';

  @override
  Future<VideoMetadata> metadata(String url) async {
    final body = await _sendJson(
      () => _send(
        'POST',
        _uri('$_prefix/metadata'),
        headers: _headers(json: true),
        body: jsonEncode({'url': url}),
      ),
      timeouts.metadata,
    );
    return VideoMetadata.fromJson(body);
  }

  @override
  Future<Job> createDownload(
    String url,
    String quality,
    String idempotencyKey,
  ) async {
    final body = await _sendJson(
      () => _send(
        'POST',
        _uri(_prefix),
        headers: _headers(json: true, idempotencyKey: idempotencyKey),
        body: jsonEncode({'url': url, 'quality': quality}),
      ),
      timeouts.standard,
    );
    return _job(body);
  }

  @override
  Future<Job> getJob(String id) async {
    final body = await _sendJson(
      () => _send('GET', _uri(_jobPath(id))),
      timeouts.standard,
    );
    return _job(body);
  }

  @override
  Future<Job> cancel(String id) async {
    final body = await _sendJson(
      () => _send('POST', _uri(_jobPath(id, '/cancel'))),
      timeouts.standard,
    );
    return _job(body);
  }

  @override
  Future<FileDownload> openFile(String id) async {
    final request = http.Request('GET', _uri(_jobPath(id, '/file')))
      ..followRedirects = false
      ..headers.addAll(_headers());
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeouts.fileStart);
    } on Object catch (error) {
      throw _translate(error);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bytes = await _readAll(response);
      throw _errorFor(response.statusCode, bytes);
    }
    return FileDownload(
      bytes: response.stream,
      contentLength: response.contentLength,
    );
  }

  @override
  Future<ConnectionReport> checkConnection() async {
    final ready = await _probe(_uri('/health/ready'));
    final auth = await _probe(_uri(_jobPath(_authProbeId)));
    final failing = <String>[];
    final checks = readMap(ready.json?['checks']);
    if (checks != null) {
      for (final entry in checks.entries) {
        final value = readMap(entry.value);
        if (value != null && value['ok'] == false) failing.add(entry.key);
      }
    }
    return ConnectionReport(
      ready: ready.status == 200,
      authorized: auth.status != 401,
      failingChecks: failing,
    );
  }

  Future<({int status, Map<String, dynamic>? json})> _probe(Uri uri) async {
    final http.Response response;
    try {
      response = await _send('GET', uri).timeout(timeouts.standard);
    } on Object catch (error) {
      throw _translate(error);
    }
    return (status: response.statusCode, json: _decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> _sendJson(
    Future<http.Response> Function() send,
    Duration timeout,
  ) async {
    final http.Response response;
    try {
      response = await send().timeout(timeout);
    } on Object catch (error) {
      throw _translate(error);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFor(response.statusCode, response.bodyBytes);
    }
    final json = _decode(response.bodyBytes);
    if (json == null) throw const ApiException.badResponse('not a JSON object');
    return json;
  }

  Job _job(Map<String, dynamic> body) {
    final job = Job.fromJson(body);
    if (job == null) throw const ApiException.badResponse('invalid job record');
    return job;
  }

  Future<List<int>> _readAll(http.StreamedResponse response) async {
    try {
      final bytes = await response.stream.toBytes().timeout(timeouts.standard);
      return bytes;
    } on Object {
      return const <int>[];
    }
  }

  Map<String, dynamic>? _decode(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  ApiException _errorFor(int status, List<int> bytes) {
    final envelope = readMap(_decode(bytes)?['error']);
    if (envelope == null) {
      return ApiException(
        kind: ApiFailureKind.server,
        code: 'http_$status',
        message: status >= 300 && status < 400
            ? 'The server redirected the request (HTTP $status). Use its final address, for '
                  'example the https one, in Settings.'
            : 'Request failed (HTTP $status).',
        status: status,
        retryable: status == 429 || status >= 500,
      );
    }
    final body = ApiErrorBody.fromJson(envelope);
    return ApiException(
      kind: ApiFailureKind.server,
      code: body.code,
      message: body.message,
      status: status,
      retryable: body.retryable,
      detail: body.detail,
    );
  }

  ApiException _translate(Object error) {
    if (error is ApiException) return error;
    if (error is TimeoutException) return const ApiException.timeout();
    if (error is SocketException || error is http.ClientException) {
      return ApiException.network(error.toString());
    }
    if (error is HandshakeException || error is TlsException) {
      return ApiException.network('TLS: $error');
    }
    return ApiException.network(error.toString());
  }

  /// Releases the underlying connection pool.
  @override
  void close() => _client.close();
}
