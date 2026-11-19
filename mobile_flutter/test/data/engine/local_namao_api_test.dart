import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/engine/local_engine.dart';
import 'package:namao_app/data/engine/local_namao_api.dart';
import 'package:namao_app/data/engine/progress_tracker.dart';

class FakeEngine implements LocalEngine {
  final List<String> calls = [];
  final Map<String, List<String>> startedOptions = {};
  final Map<String, EngineStatus?> statuses = {};
  String version = '2026.11.01';
  String runOutput = '';
  Object? initError;
  Object? runError;
  Object? startError;
  int initCount = 0;
  int statusCalls = 0;
  List<String>? lastRunOptions;
  Set<String>? lastKeep;

  @override
  Future<String> init() async {
    initCount++;
    final error = initError;
    if (error != null) throw error;
    return version;
  }

  @override
  Future<String> run(String url, List<String> options) async {
    calls.add('run $url');
    lastRunOptions = options;
    final error = runError;
    if (error != null) throw error;
    return runOutput;
  }

  @override
  Future<void> start(String jobId, String url, List<String> options) async {
    calls.add('start $jobId');
    final error = startError;
    if (error != null) throw error;
    startedOptions[jobId] = options;
  }

  @override
  Future<EngineStatus?> status(String jobId) async {
    statusCalls++;
    return statuses[jobId];
  }

  @override
  Future<void> cancel(String jobId) async => calls.add('cancel $jobId');

  @override
  Future<void> release(String jobId) async => calls.add('release $jobId');

  @override
  Future<void> cleanup(Set<String> keep) async {
    calls.add('cleanup');
    lastKeep = keep;
  }
}

String infoLines({bool live = false, int duration = 100}) {
  final info = {
    'title': 'Big Buck Bunny',
    'uploader': 'Blender',
    'duration': duration,
    'thumbnail': 'https://i.ytimg.com/vi/x/max.jpg',
    'is_live': live,
  };
  final formats = [
    {'format_id': '137', 'height': 1080, 'fps': 30.0, 'vcodec': 'avc1', 'acodec': 'none', 'tbr': 4000.0, 'filesize': 1000},
    {'format_id': '22', 'height': 720, 'fps': 30.0, 'vcodec': 'avc1', 'acodec': 'mp4a', 'tbr': 1500.0, 'filesize': 500},
    {'format_id': '140', 'vcodec': 'none', 'acodec': 'mp4a', 'abr': 128.0, 'filesize': 100},
  ];
  return '${jsonEncode(info)}\n${jsonEncode(formats)}\n';
}

void main() {
  late FakeEngine engine;
  late LocalNamaoApi api;
  late Directory temp;
  var ids = 0;

  setUp(() {
    engine = FakeEngine();
    ids = 0;
    temp = Directory.systemTemp.createTempSync('namao_local_api');
    api = LocalNamaoApi(
      engine: engine,
      newId: () => 'job-${++ids}',
      now: () => DateTime(2026, 11, 20),
      allowAnyLink: false,
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<ApiException> thrown(Future<Object?> pending) async {
    try {
      await pending;
    } on ApiException catch (error) {
      return error;
    }
    fail('expected an ApiException');
  }

  group('engine preparation', () {
    test('initialises the engine once, however many callers ask', () async {
      await Future.wait([api.prepare(), api.prepare(), api.prepare()]);
      await api.prepare();
      expect(engine.initCount, 1);
    });

    test('a failure is reported plainly and a later call tries again', () async {
      engine.initError = const LocalEngineException('init_failed', 'python: cannot unpack');
      final error = await thrown(api.prepare());
      expect(error.code, 'environment_unsupported');
      expect(error.retryable, isTrue);
      expect(error.message, isNot(contains('python')), reason: 'technical text stays internal');

      engine.initError = null;
      await api.prepare();
      expect(engine.initCount, 2);
    });
  });

  group('metadata', () {
    test('reads a link into the formats the user can pick', () async {
      engine.runOutput = infoLines();

      final metadata = await api.metadata('https://youtu.be/abc');

      expect(metadata.title, 'Big Buck Bunny');
      expect(metadata.platform, 'youtube');
      expect(metadata.formats.map((f) => f.id), ['1080', '720', 'audio']);
      expect(metadata.durationSeconds, 100);
      expect(engine.initCount, 1, reason: 'the engine is prepared on first use');
      expect(engine.lastRunOptions, contains('--use-extractors'));
    });

    test('unreadable output is a plain failure, not a crash', () async {
      engine.runOutput = 'garbage';
      final error = await thrown(api.metadata('https://youtu.be/abc'));
      expect(error.code, 'metadata_failed');
    });

    test('live streams are refused', () async {
      engine.runOutput = infoLines(live: true);
      final error = await thrown(api.metadata('https://youtu.be/abc'));
      expect(error.code, 'unsupported_content');
    });

    test("the tool's own error text is classified, never shown", () async {
      engine.runError = const LocalEngineException(
        'run_failed',
        'ERROR: [youtube] abc: Video unavailable',
      );
      final error = await thrown(api.metadata('https://youtu.be/abc'));
      expect(error.code, 'video_unavailable');
      expect(error.message, isNot(contains('ERROR')));
      expect(error.message, isNot(contains('youtube]')));
    });

    test('an engine that cannot run says so plainly', () async {
      engine.runError = const LocalEngineException('unavailable', 'no channel');
      final error = await thrown(api.metadata('https://youtu.be/abc'));
      expect(error.code, 'environment_unsupported');
    });
  });

  group('starting a download', () {
    test('a height selects exactly that height', () async {
      final job = await api.createDownload('https://youtu.be/abc', '720', 'k1');

      expect(job.id, 'job-1');
      expect(job.status, JobStatus.fetchingMetadata);
      expect(engine.startedOptions['job-1']!.join(' '), contains('bv*[height=720]+ba/b[height=720]'));
    });

    test('audio-only asks for MP3', () async {
      await api.createDownload('https://youtu.be/abc', 'audio', 'k1');
      expect(engine.startedOptions['job-1']!.join(' '), contains('--audio-format mp3'));
    });

    test('the same tap (same key) returns the same job and starts nothing new', () async {
      final first = await api.createDownload('https://youtu.be/abc', '720', 'same');
      final second = await api.createDownload('https://youtu.be/abc', '720', 'same');

      expect(second.id, first.id);
      expect(engine.calls.where((c) => c.startsWith('start')).length, 1);
    });

    test('a different tap starts a different job', () async {
      final first = await api.createDownload('https://youtu.be/abc', '720', 'a');
      final second = await api.createDownload('https://youtu.be/abc', '720', 'b');
      expect(second.id, isNot(first.id));
    });

    test('an invalid quality is refused before anything starts', () async {
      final error = await thrown(api.createDownload('https://youtu.be/abc', '720; rm -rf', 'k'));
      expect(error.code, 'invalid_quality');
      expect(error.status, 400);
      expect(engine.calls.where((c) => c.startsWith('start')), isEmpty);
    });

    test('an engine that fails to start is reported without technical text', () async {
      engine.startError = const LocalEngineException('engine_error', 'Cannot run program libpython.so');
      final error = await thrown(api.createDownload('https://youtu.be/abc', '720', 'k'));
      expect(error.message, isNot(contains('libpython')));
    });
  });

  group('job progress', () {
    Future<String> started({String quality = '1080'}) async {
      engine.runOutput = infoLines();
      await api.metadata('https://youtu.be/abc');
      return (await api.createDownload('https://youtu.be/abc', quality, 'k')).id;
    }

    test('before the first byte it is "preparing", with no invented percentage', () async {
      final id = await started();
      engine.statuses[id] = const EngineStatus(state: EngineJobState.running);

      final job = await api.getJob(id);

      expect(job.status, JobStatus.fetchingMetadata);
      expect(job.progress.percent, 0);
    });

    test('downloading reports real bytes, speed and time left', () async {
      final id = await started(); // 1080: needs a merge, announced as 1100 bytes
      engine.statuses[id] = const EngineStatus(
        state: EngineJobState.running,
        streams: [StreamProgress(downloaded: 550, total: 1000, done: false)],
        speed: 2048,
        eta: 14,
      );

      final job = await api.getJob(id);

      expect(job.status, JobStatus.downloading);
      expect(job.progress.downloadedBytes, 550);
      expect(job.progress.percent, closeTo(50, 1));
      expect(job.progress.speedBps, 2048);
      expect(job.progress.etaSeconds, 14);
    });

    test('progress only moves forward across the video and audio transfers', () async {
      final id = await started();
      final seen = <double>[];
      for (final streams in [
        [const StreamProgress(downloaded: 500, total: 1000, done: false)],
        [const StreamProgress(downloaded: 1000, total: 1000, done: true)],
        [
          const StreamProgress(downloaded: 1000, total: 1000, done: true),
          const StreamProgress(downloaded: 10, total: 100, done: false),
        ],
      ]) {
        engine.statuses[id] = EngineStatus(state: EngineJobState.running, streams: streams);
        seen.add((await api.getJob(id)).progress.percent);
      }
      expect(seen, orderedEquals([...seen]..sort()));
      expect(seen.last, lessThan(100));
    });

    test('a download whose formats were never listed still shows steady progress', () async {
      // No metadata call first (for example a retry after the app restarted): the stream count is unknown.
      final id = (await api.createDownload('https://youtu.be/abc', '720', 'k2')).id;
      engine.statuses[id] = const EngineStatus(
        state: EngineJobState.running,
        streams: [StreamProgress(downloaded: 800, total: 1000, done: false)],
      );

      final job = await api.getJob(id);

      expect(job.progress.percent, closeTo(80, 1), reason: 'not capped at 50% waiting for a second stream');
    });

    test('merging or converting is the "finishing" stage', () async {
      final id = await started();
      engine.statuses[id] = const EngineStatus(
        state: EngineJobState.running,
        processing: true,
        streams: [StreamProgress(downloaded: 1, total: 1, done: true)],
      );

      expect((await api.getJob(id)).status, JobStatus.merging);
    });

    test('a finished download names the file after the video and keeps its extension', () async {
      final id = await started();
      final file = File('${temp.path}/media.mp4')..writeAsBytesSync([1, 2, 3]);
      engine.statuses[id] = EngineStatus(
        state: EngineJobState.completed,
        title: 'Big Buck Bunny: the/movie?',
        path: file.path,
        size: 3,
        duration: 596,
      );

      final job = await api.getJob(id);

      expect(job.status, JobStatus.completed);
      expect(job.result!.sizeBytes, 3);
      expect(job.result!.filename, 'Big Buck Bunny the movie.mp4');
      expect(job.result!.durationSeconds, 596);
    });

    test('a "completed" job with no usable file is a failure, not a success', () async {
      final id = await started();
      engine.statuses[id] = const EngineStatus(state: EngineJobState.completed, size: 0);

      final job = await api.getJob(id);

      expect(job.status, JobStatus.failed);
      expect(job.error!.code, 'output_invalid');
    });

    test('a failure is classified and carries no technical text', () async {
      final id = await started();
      engine.statuses[id] = const EngineStatus(
        state: EngineJobState.failed,
        error: 'ERROR: [youtube] abc: HTTP Error 429: Too Many Requests\nTraceback ...',
      );

      final job = await api.getJob(id);

      expect(job.status, JobStatus.failed);
      expect(job.error!.code, 'source_rate_limited');
      expect(job.error!.retryable, isTrue);
      expect(job.error!.message, isEmpty, reason: 'wording comes from the app, not the tool');
      expect(job.error!.detail, isNull);
    });

    test('a job the native side has never heard of is "interrupted" (the app was restarted)', () async {
      final job = await api.getJob('unknown-job');

      expect(job.status, JobStatus.interrupted);
      expect(job.error!.retryable, isTrue);
    });

    test('a finished job is remembered and the engine is not asked again', () async {
      final id = await started();
      engine.statuses[id] = const EngineStatus(
        state: EngineJobState.failed,
        error: 'ERROR: Video unavailable',
      );
      await api.getJob(id);
      final callsBefore = engine.statusCalls;

      final again = await api.getJob(id);

      expect(again.status, JobStatus.failed);
      expect(engine.statusCalls, callsBefore);
    });

    test('a cancelled job reads as cancelled', () async {
      final id = await started();
      engine.statuses[id] = const EngineStatus(state: EngineJobState.cancelled);
      expect((await api.getJob(id)).status, JobStatus.cancelled);
    });

    test('an engine that stops answering is a read failure, not a made-up state', () async {
      final id = await started();
      final broken = _ThrowingStatusEngine(engine);
      final failing = LocalNamaoApi(engine: broken, newId: () => id, allowAnyLink: false);
      final error = await thrown(failing.getJob(id));
      expect(error.isJobGone, isFalse);
      expect(error.retryable, isTrue);
    });
  });

  group('cancel', () {
    test('stops a running download', () async {
      final id = (await api.createDownload('https://youtu.be/abc', '720', 'k')).id;
      engine.statuses[id] = const EngineStatus(state: EngineJobState.running);

      final job = await api.cancel(id);

      expect(job.status, JobStatus.cancelled);
      expect(engine.calls, contains('cancel $id'));
      expect((await api.getJob(id)).status, JobStatus.cancelled);
    });

    test('a download that already finished is a conflict, not a cancel', () async {
      final id = (await api.createDownload('https://youtu.be/abc', '720', 'k')).id;
      engine.statuses[id] = const EngineStatus(state: EngineJobState.failed, error: 'x');

      final error = await thrown(api.cancel(id));

      expect(error.status, 409);
      expect(engine.calls, isNot(contains('cancel $id')));
    });
  });

  group('the finished file', () {
    test('is the file on disk once the job completed', () async {
      final file = File('${temp.path}/media.mp4')..writeAsBytesSync([1, 2, 3]);
      engine.statuses['j'] = EngineStatus(state: EngineJobState.completed, path: file.path, size: 3);

      final found = await api.finishedFile('j');

      expect(found.path, file.path);
    });

    test('is "gone" when the job is unknown, unfinished, or its file was deleted', () async {
      engine.statuses['running'] = const EngineStatus(state: EngineJobState.running);
      engine.statuses['deleted'] = EngineStatus(
        state: EngineJobState.completed,
        path: '${temp.path}/nope.mp4',
        size: 3,
      );
      for (final id in ['unknown', 'running', 'deleted']) {
        final error = await thrown(api.finishedFile(id));
        expect(error.isJobGone, isTrue, reason: id);
      }
    });
  });

  group('cleanup', () {
    test('release and cleanup go straight to the engine', () async {
      await api.release('j');
      await api.cleanup({'a', 'b'});

      expect(engine.calls, containsAll(['release j', 'cleanup']));
      expect(engine.lastKeep, {'a', 'b'});
    });

    test('a failing cleanup never breaks the app', () async {
      final broken = _ThrowingStatusEngine(engine);
      final failing = LocalNamaoApi(engine: broken, allowAnyLink: false);
      await failing.release('j');
      await failing.cleanup({});
    });
  });

  group('an old engine', () {
    test('is blamed (and retryable) when a site stops working', () async {
      engine.version = '2025.01.01'; // far older than the freshness limit
      engine.runError = const LocalEngineException('run_failed', 'ERROR: Unable to extract initial data');

      final error = await thrown(api.metadata('https://youtu.be/abc'));

      expect(error.code, 'engine_outdated');
      expect(error.retryable, isTrue);
    });

    test('a fresh engine is not blamed', () async {
      engine.runError = const LocalEngineException('run_failed', 'ERROR: Unable to extract initial data');

      final error = await thrown(api.metadata('https://youtu.be/abc'));

      expect(error.code, 'extractor_broken');
    });
  });

  test('verification builds can skip the site restriction', () async {
    final open = LocalNamaoApi(engine: engine, allowAnyLink: true);
    engine.runOutput = infoLines();

    await open.metadata('http://10.0.2.2:8080/manifest.mpd');

    expect(engine.lastRunOptions, isNot(contains('--use-extractors')));
  });
}

/// An engine whose status/release/cleanup calls fail like a dead channel.
class _ThrowingStatusEngine extends FakeEngine {
  _ThrowingStatusEngine(FakeEngine _);

  @override
  Future<EngineStatus?> status(String jobId) async =>
      throw const LocalEngineException('engine_error', 'channel closed');

  @override
  Future<void> release(String jobId) async =>
      throw const LocalEngineException('engine_error', 'channel closed');

  @override
  Future<void> cleanup(Set<String> keep) async =>
      throw const LocalEngineException('engine_error', 'channel closed');
}
