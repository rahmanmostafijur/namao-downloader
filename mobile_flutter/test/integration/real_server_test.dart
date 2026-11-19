/// Runs the app's real network stack against a REAL Namao server (yt-dlp + FFmpeg, local DASH
/// stream). Skipped unless both variables are set:
///
///   NAMAO_TEST_SERVER=http://127.0.0.1:8000
///   NAMAO_TEST_MEDIA_URL=http://localhost:PORT/manifest.mpd   (printed by tool/run_test_server.py)
///   NAMAO_TEST_API_KEY=...                                       (only if the server has one)
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/api/http_namao_api.dart';
import 'package:namao_app/core/job_poller.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/file_saver.dart';

import '../support/fakes.dart';

final String? _server = Platform.environment['NAMAO_TEST_SERVER'];
final String? _media = Platform.environment['NAMAO_TEST_MEDIA_URL'];
final String? _key = Platform.environment['NAMAO_TEST_API_KEY'];

Future<Job> _runToTerminal(HttpNamaoApi api, String id) async {
  Job? last;
  final poller = JobPoller(
    api: api,
    jobId: id,
    onJob: (job) => last = job,
    onLost: (reason, error) => fail('lost contact: $reason $error'),
    interval: const Duration(milliseconds: 250),
  );
  await poller.start().timeout(const Duration(seconds: 120));
  return last!;
}

void main() {
  final enabled = _server != null && _media != null;
  final skip = enabled
      ? false
      : 'set NAMAO_TEST_SERVER and NAMAO_TEST_MEDIA_URL';

  late HttpNamaoApi api;
  late Directory temp;

  setUp(() {
    api = HttpNamaoApi(baseUrl: _server ?? 'http://127.0.0.1:1', apiKey: _key);
    temp = Directory.systemTemp.createTempSync('namao_real');
  });

  tearDown(() {
    api.close();
    temp.deleteSync(recursive: true);
  });

  test('connection check reports a ready server', () async {
    final report = await api.checkConnection();
    expect(report.ready, isTrue, reason: report.failingChecks.join(','));
    expect(report.authorized, isTrue);
  }, skip: skip);

  test(
    'metadata -> create -> poll -> completed -> file -> verified save',
    () async {
      final metadata = await api.metadata(_media!);
      expect(metadata.formats, isNotEmpty);
      final heights = metadata.videoFormats
          .map((f) => f.height)
          .whereType<int>()
          .toList();
      expect(
        heights,
        contains(360),
        reason: 'the synthetic stream offers 360p and 180p',
      );
      final format = metadata.formats.firstWhere((f) => f.id == '360');

      final job = await api.createDownload(
        _media!,
        format.id,
        'flutter-it-${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(job.status.isTerminal, isFalse);

      final seen = <JobStatus>{};
      var last = job;
      final poller = JobPoller(
        api: api,
        jobId: job.id,
        onJob: (j) {
          seen.add(j.status);
          last = j;
        },
        onLost: (reason, error) => fail('lost contact: $reason $error'),
        interval: const Duration(milliseconds: 100),
      );
      await poller.start().timeout(const Duration(seconds: 120));

      expect(last.status, JobStatus.completed, reason: last.error?.message);
      expect(last.progress.percent, 100);
      expect(last.result, isNotNull);
      expect(last.result!.height, 360);

      final media = FakeNativeMedia();
      final saver = FileSaver(
        api: api,
        media: media,
        tempDirectory: () => temp,
      );
      final saved = await saver.save(
        jobId: job.id,
        filename: last.result!.filename,
        expectedBytes: last.result!.sizeBytes,
      );
      expect(saved.sizeBytes, last.result!.sizeBytes);
      expect(media.events.single, contains('video/mp4'));
      expect(temp.listSync(), isEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'audio quality completes with an audio file',
    () async {
      final job = await api.createDownload(
        _media!,
        'audio',
        'flutter-it-audio-${DateTime.now().microsecondsSinceEpoch}',
      );
      final done = await _runToTerminal(api, job.id);
      expect(done.status, JobStatus.completed, reason: done.error?.message);
      expect(
        done.result!.filename,
        anyOf(
          endsWith('.m4a'),
          endsWith('.mp3'),
          endsWith('.opus'),
          endsWith('.webm'),
          endsWith('.mp4'),
        ),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'an unavailable height fails with a classified error, never success',
    () async {
      final job = await api.createDownload(
        _media!,
        '2160',
        'flutter-it-4k-${DateTime.now().microsecondsSinceEpoch}',
      );
      final done = await _runToTerminal(api, job.id);
      expect(done.status, JobStatus.failed);
      expect(done.result, isNull);
      expect(done.error!.code, isNotEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('idempotent create returns the same job', () async {
    final key = 'flutter-it-idem-${DateTime.now().microsecondsSinceEpoch}';
    final first = await api.createDownload(_media!, '180', key);
    final second = await api.createDownload(_media!, '180', key);
    expect(second.id, first.id);
    await api.cancel(first.id);
  }, skip: skip);

  test(
    'cancel stops a job',
    () async {
      final job = await api.createDownload(
        _media!,
        '360',
        'flutter-it-cancel-${DateTime.now().microsecondsSinceEpoch}',
      );
      final cancelled = await api.cancel(job.id);
      final done = cancelled.status.isTerminal
          ? cancelled
          : await _runToTerminal(api, job.id);
      expect(done.status, anyOf(JobStatus.cancelled, JobStatus.completed));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'unknown job is a 404 and an invalid link is a server error envelope',
    () async {
      await expectLater(
        api.getJob('does-not-exist'),
        throwsA(
          isA<ApiException>().having((e) => e.isNotFound, 'isNotFound', true),
        ),
      );
      await expectLater(
        api.metadata('https://example.com/not-supported'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', isNotEmpty)),
      );
    },
    skip: skip,
  );
}
