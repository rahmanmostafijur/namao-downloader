import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/api/http_namao_api.dart';
import 'package:namao_app/core/models/job_status.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> jobBody({String id = 'j1', String status = 'queued'}) => {
  'id': id,
  'status': status,
  'platform': 'youtube',
  'quality': '720',
  'progress': {'percent': 0},
  'attempt': 0,
  'max_attempts': 3,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

HttpNamaoApi apiWith(
  MockClient client, {
  String? key,
  ApiTimeouts timeouts = const ApiTimeouts(),
}) => HttpNamaoApi(
  baseUrl: 'http://10.0.2.2:8000',
  apiKey: key,
  client: client,
  timeouts: timeouts,
);

void main() {
  group('requests', () {
    test('metadata posts the url and parses formats', () async {
      late http.Request seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return json({
            'platform': 'youtube',
            'title': 'T',
            'uploader': 'U',
            'duration_seconds': 61,
            'thumbnail': 'https://img/x.jpg',
            'ffmpeg': true,
            'formats': [
              {
                'id': '1080',
                'label': '1080p',
                'kind': 'video',
                'height': 1080,
                'note': 'MP4',
                'size_bytes': 1000,
                'size_estimated': true,
                'needs_merge': true,
              },
              {'id': 'bogus', 'kind': 'video'},
              {'id': 'audio', 'label': 'Audio', 'kind': 'audio'},
            ],
          });
        }),
      );
      final metadata = await api.metadata('https://youtu.be/x');
      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'http://10.0.2.2:8000/api/v1/downloads/metadata',
      );
      expect(jsonDecode(seen.body), {'url': 'https://youtu.be/x'});
      expect(seen.headers['Content-Type'], contains('application/json'));
      expect(metadata.title, 'T');
      expect(metadata.durationSeconds, 61);
      expect(metadata.formats.map((f) => f.id), [
        '1080',
        'audio',
      ], reason: 'malformed formats are never shown');
      expect(metadata.formats.first.sizeEstimated, isTrue);
      expect(metadata.formats.first.needsMerge, isTrue);
    });

    test(
      'createDownload sends quality and the Idempotency-Key header',
      () async {
        late http.Request seen;
        final api = apiWith(
          MockClient((request) async {
            seen = request;
            return json(jobBody(), 202);
          }),
        );
        final job = await api.createDownload(
          'https://youtu.be/x',
          '720',
          'key-123',
        );
        expect(seen.headers['Idempotency-Key'], 'key-123');
        expect(jsonDecode(seen.body), {
          'url': 'https://youtu.be/x',
          'quality': '720',
        });
        expect(job.status, JobStatus.queued);
      },
    );

    test('a replayed key (200) is accepted the same way', () async {
      final api = apiWith(MockClient((_) async => json(jobBody(), 200)));
      expect((await api.createDownload('u', 'best', 'k')).id, 'j1');
    });

    test('getJob and cancel use the job path with an encoded id', () async {
      final seen = <String>[];
      final api = apiWith(
        MockClient((request) async {
          seen.add('${request.method} ${request.url.path}');
          return json(jobBody(id: 'a/b'));
        }),
      );
      await api.getJob('a/b');
      await api.cancel('a/b');
      expect(seen, [
        'GET /api/v1/downloads/a%2Fb',
        'POST /api/v1/downloads/a%2Fb/cancel',
      ]);
    });

    test('X-API-Key is sent when configured and never in the URL', () async {
      final requests = <http.Request>[];
      final api = apiWith(
        MockClient((request) async {
          requests.add(request);
          return json(jobBody());
        }),
        key: 's3cret',
      );
      await api.getJob('j1');
      await api.createDownload('u', 'best', 'k');
      for (final request in requests) {
        expect(request.headers['X-API-Key'], 's3cret');
        expect(request.url.toString(), isNot(contains('s3cret')));
      }
    });

    test('no X-API-Key header without a key', () async {
      late http.Request seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return json(jobBody());
        }),
      );
      await api.getJob('j1');
      expect(seen.headers.containsKey('X-API-Key'), isFalse);
      expect(seen.headers.containsKey('Idempotency-Key'), isFalse);
    });
  });

  group('errors', () {
    test('parses the error envelope', () async {
      final api = apiWith(
        MockClient(
          (_) async => json({
            'error': {
              'code': 'unsupported_platform',
              'message': 'That site isn\'t supported.',
              'retryable': false,
              'detail': 'x',
            },
          }, 400),
        ),
      );
      await expectLater(
        api.metadata('u'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'unsupported_platform')
              .having(
                (e) => e.message,
                'message',
                'That site isn\'t supported.',
              )
              .having((e) => e.status, 'status', 400)
              .having((e) => e.retryable, 'retryable', false)
              .having((e) => e.kind, 'kind', ApiFailureKind.server),
        ),
      );
    });

    test('retryable flag from the envelope is kept (429)', () async {
      final api = apiWith(
        MockClient(
          (_) async => json({
            'error': {
              'code': 'too_many_requests',
              'message': 'Slow down.',
              'retryable': true,
            },
          }, 429),
        ),
      );
      await expectLater(
        api.getJob('x'),
        throwsA(
          isA<ApiException>().having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('non-JSON error bodies become a generic HTTP error', () async {
      final api = apiWith(
        MockClient((_) async => http.Response('<html>Bad gateway</html>', 502)),
      );
      await expectLater(
        api.getJob('x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'http_502')
              .having((e) => e.message, 'message', contains('502'))
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('empty error body on 404 is not retryable', () async {
      final api = apiWith(MockClient((_) async => http.Response('', 404)));
      await expectLater(
        api.getJob('x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.isNotFound, 'isNotFound', true)
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('2xx with a non-JSON body is a bad response', () async {
      final api = apiWith(MockClient((_) async => http.Response('hello', 200)));
      await expectLater(
        api.getJob('x'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiFailureKind.badResponse,
          ),
        ),
      );
    });

    test(
      '2xx with an unknown job status is a bad response, never guessed',
      () async {
        final api = apiWith(
          MockClient((_) async => json(jobBody(status: 'paused'))),
        );
        await expectLater(
          api.getJob('x'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.kind,
              'kind',
              ApiFailureKind.badResponse,
            ),
          ),
        );
      },
    );

    test('connection failures are network errors', () async {
      final api = apiWith(
        MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      await expectLater(
        api.getJob('x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiFailureKind.network)
              .having((e) => e.isConnectivity, 'isConnectivity', true),
        ),
      );
    });

    test('a slow server times out', () async {
      final api = apiWith(
        MockClient((_) => Completer<http.Response>().future),
        timeouts: const ApiTimeouts(standard: Duration(milliseconds: 30)),
      );
      await expectLater(
        api.getJob('x'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiFailureKind.timeout,
          ),
        ),
      );
    });

    test('metadata has its own, longer timeout', () async {
      final api = apiWith(
        MockClient((_) => Completer<http.Response>().future),
        timeouts: const ApiTimeouts(
          metadata: Duration(milliseconds: 30),
          standard: Duration(hours: 1),
        ),
      );
      await expectLater(
        api.metadata('u'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiFailureKind.timeout,
          ),
        ),
      );
    });
  });

  group('openFile', () {
    test(
      'streams bytes with the API key header and exposes the length',
      () async {
        late http.BaseRequest seen;
        final client = MockClient.streaming((request, _) async {
          seen = request;
          return http.StreamedResponse(
            Stream.value([1, 2, 3]),
            200,
            contentLength: 3,
          );
        });
        final api = apiWith(client, key: 'k');
        final download = await api.openFile('j1');
        expect(seen.url.path, '/api/v1/downloads/j1/file');
        expect(seen.headers['X-API-Key'], 'k');
        expect(download.contentLength, 3);
        expect(await download.bytes.expand((c) => c).toList(), [1, 2, 3]);
      },
    );

    test('non-2xx maps the envelope', () async {
      final client = MockClient.streaming((request, _) async {
        final body = utf8.encode(
          jsonEncode({
            'error': {
              'code': 'expired',
              'message': 'Expired.',
              'retryable': false,
            },
          }),
        );
        return http.StreamedResponse(Stream.value(body), 410);
      });
      await expectLater(
        apiWith(client).openFile('j1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'expired')
              .having((e) => e.isNotFound, 'isNotFound', true),
        ),
      );
    });
  });

  group('checkConnection', () {
    test('ready and authorised', () async {
      final api = apiWith(
        MockClient((request) async {
          if (request.url.path == '/health/ready') {
            return json({'status': 'ready', 'checks': {}});
          }
          return json({
            'error': {
              'code': 'not_found',
              'message': 'Not found.',
              'retryable': false,
            },
          }, 404);
        }),
      );
      final report = await api.checkConnection();
      expect(report.ready, isTrue);
      expect(report.authorized, isTrue);
      expect(report.isHealthy, isTrue);
    });

    test('not ready lists the failing checks', () async {
      final api = apiWith(
        MockClient((request) async {
          if (request.url.path == '/health/ready') {
            return json({
              'status': 'degraded',
              'checks': {
                'ffmpeg': {'ok': false},
                'database': {'ok': true},
              },
            }, 503);
          }
          return http.Response('', 404);
        }),
      );
      final report = await api.checkConnection();
      expect(report.ready, isFalse);
      expect(report.failingChecks, ['ffmpeg']);
    });

    test('a 401 from the API means the key is rejected', () async {
      final api = apiWith(
        MockClient((request) async {
          if (request.url.path == '/health/ready') {
            return json({'status': 'ready'});
          }
          return json({
            'error': {
              'code': 'unauthorized',
              'message': 'no',
              'retryable': false,
            },
          }, 401);
        }),
      );
      final report = await api.checkConnection();
      expect(report.ready, isTrue);
      expect(report.authorized, isFalse);
    });

    test('unreachable server throws a network error', () async {
      final api = apiWith(
        MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        api.checkConnection(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiFailureKind.network,
          ),
        ),
      );
    });
  });
}
