import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/job_poller.dart';
import 'package:namao_app/core/models/api_error.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/history_entry.dart';
import 'package:namao_app/data/native_media.dart';
import 'package:namao_app/data/providers.dart';
import 'package:namao_app/features/downloads/downloads_controller.dart';
import 'package:namao_app/features/downloads/downloads_state.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

HistoryEntry seeded(
  String id, {
  JobStatus status = JobStatus.downloading,
  SaveState save = SaveState.none,
  String? savedUri,
}) => HistoryEntry(
  jobId: id,
  sourceUrl: 'https://youtu.be/$id',
  title: 'Title $id',
  qualityId: '720',
  qualityLabel: '720p',
  platform: 'youtube',
  createdAt: DateTime.utc(2026, 1, 1),
  job: makeJob(
    id: id,
    status: status,
    result: status == JobStatus.completed
        ? makeResult(id: id, sizeBytes: 8)
        : null,
  ),
  saveState: save,
  savedUri: savedUri,
  savedName: savedUri == null ? null : 'Title.mp4',
  savedBytes: savedUri == null ? null : 8,
);

void main() {
  late TestHarness h;
  late ProviderContainer container;

  Future<void> boot([List<HistoryEntry> history = const []]) async {
    if (history.isNotEmpty) {
      await container.read(historyStoreProvider).save(history);
    }
    container.listen(downloadsProvider, (_, _) {});
    await eventually(
      () => container.read(downloadsProvider).isLoaded,
      reason: 'history restore',
    );
  }

  DownloadsController controller() =>
      container.read(downloadsProvider.notifier);
  DownloadsState state() => container.read(downloadsProvider);

  setUp(() async {
    h = await TestHarness.create();
    container = h.container();
  });

  tearDown(() => h.dispose());

  group('starting and tracking', () {
    test('start adds an Active entry, polls real progress, auto-saves on completion', () async {
      await boot();
      h.api.files['job1'] = List.generate(8, (i) => i);
      h.api.script('job1', [
        makeJob(id: 'job1', status: JobStatus.queued),
        makeJob(
          id: 'job1',
          status: JobStatus.downloading,
          progress: const JobProgress(
            percent: 50,
            totalBytes: 100,
            downloadedBytes: 50,
          ),
        ),
        makeJob(
          id: 'job1',
          status: JobStatus.completed,
          result: makeResult(sizeBytes: 8),
        ),
      ]);

      final entry = await controller().start(
        sourceUrl: 'https://youtu.be/x',
        metadata: sampleMetadata,
        format: sampleMetadata.formats[1],
        idempotencyKey: 'key-a',
      );

      expect(entry.jobId, 'job1');
      expect(entry.qualityLabel, '1080p');
      expect(entry.title, 'Sample video title');
      expect(h.api.idempotencyKeys, ['key-a']);
      expect(state().entryFor('job1')!.tab, DownloadsTab.active);

      await eventually(
        () => state().entryFor('job1')!.isSaved,
        reason: 'auto-save',
      );
      final saved = state().entryFor('job1')!;
      expect(saved.tab, DownloadsTab.completed);
      expect(saved.savedUri, 'content://media/downloads/1');
      expect(
        h.media.events,
        containsAllInOrder([
          'startTransfer',
          'save Video.mp4 video/mp4 8',
          'stopTransfer',
        ]),
      );
      expect(h.temp.listSync(), isEmpty);
    });

    test('history is persisted as the state changes', () async {
      await boot();
      h.api.script('job1', [
        makeJob(id: 'job1', status: JobStatus.downloading),
      ]);
      await controller().start(
        sourceUrl: 'https://youtu.be/x',
        metadata: sampleMetadata,
        format: sampleMetadata.formats[0],
        idempotencyKey: 'k',
      );
      final stored = container.read(historyStoreProvider).load();
      expect(stored.single.jobId, 'job1');
      expect(stored.single.sourceUrl, 'https://youtu.be/x');
      expect(stored.single.qualityId, 'best');
    });

    test('a replayed job id does not duplicate the entry', () async {
      await boot();
      h.api.fixedCreateId = 'same';
      h.api.script('same', [
        makeJob(id: 'same', status: JobStatus.downloading),
      ]);
      for (final key in ['k1', 'k1']) {
        await controller().start(
          sourceUrl: 'https://youtu.be/x',
          metadata: sampleMetadata,
          format: sampleMetadata.formats[1],
          idempotencyKey: key,
        );
      }
      expect(state().entries.length, 1);
    });

    test('a failed server job ends in the Failed tab with its error', () async {
      await boot();
      const error = ApiErrorBody(code: 'video_unavailable', message: 'Gone.');
      h.api.script('job1', [
        makeJob(id: 'job1', status: JobStatus.failed, error: error),
      ]);
      await controller().start(
        sourceUrl: 'https://youtu.be/x',
        metadata: sampleMetadata,
        format: sampleMetadata.formats[1],
        idempotencyKey: 'k',
      );
      await eventually(
        () => state().entryFor('job1')!.tab == DownloadsTab.failed,
      );
      expect(state().entryFor('job1')!.job!.error!.message, 'Gone.');
      expect(
        h.media.events,
        isEmpty,
        reason: 'nothing is saved for a failed job',
      );
    });

    test('create errors propagate to the caller and add nothing', () async {
      await boot();
      h.api.createResult = const ApiException(
        kind: ApiFailureKind.server,
        code: 'queue_full',
        message: 'Busy.',
        status: 503,
        retryable: true,
      );
      await expectLater(
        controller().start(
          sourceUrl: 'https://youtu.be/x',
          metadata: sampleMetadata,
          format: sampleMetadata.formats[1],
          idempotencyKey: 'k',
        ),
        throwsA(isA<ApiException>()),
      );
      expect(state().entries, isEmpty);
    });
  });

  group('restore on launch', () {
    test('active jobs resume polling and reach completion', () async {
      h.api.files['j1'] = List.generate(8, (i) => i);
      h.api.script('j1', [
        makeJob(
          id: 'j1',
          status: JobStatus.completed,
          result: makeResult(id: 'j1', sizeBytes: 8),
        ),
      ]);
      await boot([seeded('j1')]);
      await eventually(
        () => state().entryFor('j1')!.isSaved,
        reason: 'restored job to finish and save',
      );
    });

    test('a job the server forgot is marked expired, not successful', () async {
      await boot([seeded('gone')]); // no script -> 404
      await eventually(
        () => state().entryFor('gone')!.serverGone,
        reason: 'expiry detection',
      );
      expect(state().entryFor('gone')!.tab, DownloadsTab.failed);
    });

    test('a saved entry is never re-polled and stays saved even if the server forgot it', () async {
      await boot([
        seeded(
          's',
          status: JobStatus.completed,
          save: SaveState.saved,
          savedUri: 'content://x',
        ),
      ]);
      expect(h.api.calls.where((c) => c.startsWith('get')), isEmpty);
      expect(state().entryFor('s')!.tab, DownloadsTab.completed);
    });

    test(
      'an interrupted device transfer is detected and offers Retry save',
      () async {
        h.api.script('t', [
          makeJob(
            id: 't',
            status: JobStatus.completed,
            result: makeResult(id: 't', sizeBytes: 8),
          ),
        ]);
        await boot([
          seeded(
            't',
            status: JobStatus.completed,
            save: SaveState.transferring,
          ),
        ]);
        final entry = state().entryFor('t')!;
        expect(entry.saveState, SaveState.failed);
        expect(entry.saveError, interruptedTransferMessage);
        expect(entry.needsSave, isTrue);
        // It was not auto-restarted: the user decides.
        expect(h.media.events, isEmpty);

        h.api.files['t'] = List.generate(8, (i) => i);
        controller().saveToDevice('t');
        await eventually(
          () => state().entryFor('t')!.isSaved,
          reason: 'retry save',
        );
      },
    );

    test('stale temp files from a killed transfer are removed', () async {
      File('${h.temp.path}/namao_dead.part').writeAsStringSync('partial');
      await boot();
      await eventually(
        () => h.temp.listSync().isEmpty,
        reason: 'stale file cleanup',
      );
    });

    test('completed on the server but never saved starts the save', () async {
      h.api.files['c'] = List.generate(8, (i) => i);
      h.api.script('c', [
        makeJob(
          id: 'c',
          status: JobStatus.completed,
          result: makeResult(id: 'c', sizeBytes: 8),
        ),
      ]);
      await boot([seeded('c', status: JobStatus.completed)]);
      await eventually(
        () => state().entryFor('c')!.isSaved,
        reason: 'auto-save on restore',
      );
    });
  });

  group('cancel, retry, remove', () {
    test('cancel calls the server and applies its answer', () async {
      h.api.script('j1', [makeJob(id: 'j1', status: JobStatus.downloading)]);
      await boot([seeded('j1')]);
      h.api.cancelResult = makeJob(id: 'j1', status: JobStatus.cancelled);
      await controller().cancel('j1');
      expect(h.api.calls, contains('cancel j1'));
      expect(state().entryFor('j1')!.status, JobStatus.cancelled);
      expect(state().entryFor('j1')!.tab, DownloadsTab.failed);
    });

    test(
      'cancel racing completion (409) refreshes instead of erroring',
      () async {
        h.api.script('j1', [makeJob(id: 'j1', status: JobStatus.failed)]);
        await boot([seeded('j1', status: JobStatus.failed)]);
        h.api.cancelResult = const ApiException(
          kind: ApiFailureKind.server,
          code: 'conflict',
          message: 'No.',
          status: 409,
        );
        await controller().cancel('j1');
        expect(h.api.calls, contains('get j1'));
      },
    );

    test('other cancel errors are rethrown for the UI', () async {
      await boot([seeded('j1')]);
      h.api.cancelResult = const ApiException.network();
      await expectLater(
        controller().cancel('j1'),
        throwsA(isA<ApiException>()),
      );
    });

    test('retry creates a NEW job with its own idempotency key and replaces the failed record', () async {
      h.api.script('old', [makeJob(id: 'old', status: JobStatus.failed)]);
      await boot([seeded('old', status: JobStatus.failed)]);
      h.api.createResult = makeJob(id: 'new', status: JobStatus.queued);
      h.api.script('new', [makeJob(id: 'new', status: JobStatus.downloading)]);

      final entry = await controller().retry('old');

      expect(entry.jobId, 'new');
      expect(entry.sourceUrl, 'https://youtu.be/old');
      expect(entry.qualityId, '720');
      expect(h.api.calls, contains('create https://youtu.be/old 720'));
      expect(h.api.idempotencyKeys.single, 'retry:old');
      expect(state().entryFor('old'), isNull);
      expect(state().entryFor('new')!.tab, DownloadsTab.active);
    });

    test('remove deletes only the record, never the saved file', () async {
      await boot([
        seeded(
          's',
          status: JobStatus.completed,
          save: SaveState.saved,
          savedUri: 'content://x',
        ),
      ]);
      controller().remove('s');
      expect(state().entries, isEmpty);
      expect(container.read(historyStoreProvider).load(), isEmpty);
      expect(
        h.media.events,
        isEmpty,
        reason: 'no file deletion call exists or is made',
      );
    });

    test('clearFinished keeps running downloads', () async {
      h.api.script('run', [makeJob(id: 'run', status: JobStatus.downloading)]);
      await boot([
        seeded('run'),
        seeded('f', status: JobStatus.failed),
        seeded(
          's',
          status: JobStatus.completed,
          save: SaveState.saved,
          savedUri: 'content://x',
        ),
      ]);
      controller().clearFinished();
      expect(state().entries.map((e) => e.jobId), ['run']);
    });
  });

  group('saving to the phone', () {
    test('saving is idempotent: a saved job is not saved twice', () async {
      h.api.files['c'] = List.generate(8, (i) => i);
      h.api.script('c', [
        makeJob(
          id: 'c',
          status: JobStatus.completed,
          result: makeResult(id: 'c', sizeBytes: 8),
        ),
      ]);
      await boot([seeded('c', status: JobStatus.completed)]);
      await eventually(() => state().entryFor('c')!.isSaved);
      controller().saveToDevice('c');
      controller().saveToDevice('c');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.media.events.where((e) => e.startsWith('save')).length, 1);
      expect(h.api.calls.where((c) => c.startsWith('file')).length, 1);
    });

    test(
      'a short file fails the save and Retry save can succeed later',
      () async {
        h.api.files['c'] = [1, 2, 3]; // server says 8 bytes, body has 3
        h.api.fileContentLengthOverride = 8;
        h.api.script('c', [
          makeJob(
            id: 'c',
            status: JobStatus.completed,
            result: makeResult(id: 'c', sizeBytes: 8),
          ),
        ]);
        await boot([seeded('c', status: JobStatus.completed)]);
        await eventually(
          () => state().entryFor('c')!.saveState == SaveState.failed,
          reason: 'save failure',
        );
        final failed = state().entryFor('c')!;
        expect(failed.isSaved, isFalse);
        expect(failed.saveError, contains("didn't transfer completely"));
        expect(h.media.events.where((e) => e.startsWith('save')), isEmpty);

        h.api.files['c'] = List.generate(8, (i) => i);
        h.api.fileContentLengthOverride = null;
        controller().saveToDevice('c');
        await eventually(
          () => state().entryFor('c')!.isSaved,
          reason: 'retry save',
        );
      },
    );

    test('a file that expired on the server marks the entry expired', () async {
      h.api.fileError = const ApiException(
        kind: ApiFailureKind.server,
        code: 'expired',
        message: 'Expired.',
        status: 410,
      );
      h.api.script('c', [
        makeJob(
          id: 'c',
          status: JobStatus.completed,
          result: makeResult(id: 'c', sizeBytes: 8),
        ),
      ]);
      await boot([seeded('c', status: JobStatus.completed)]);
      await eventually(
        () => state().entryFor('c')!.serverGone,
        reason: 'expiry',
      );
      expect(state().entryFor('c')!.tab, DownloadsTab.failed);
    });

    test(
      'removing an entry mid-transfer cancels it and leaves nothing behind',
      () async {
        h.api.files['c'] = List.generate(400, (i) => i % 256);
        h.api.chunkDelay = const Duration(milliseconds: 4);
        h.api.script('c', [
          makeJob(
            id: 'c',
            status: JobStatus.completed,
            result: makeResult(id: 'c', sizeBytes: 400),
          ),
        ]);
        await boot([seeded('c', status: JobStatus.completed)]);
        await eventually(
          () => state().entryFor('c')?.saveState == SaveState.transferring,
          reason: 'transfer start',
        );
        controller().remove('c');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(state().entries, isEmpty);
        expect(h.media.events.where((e) => e.startsWith('save')), isEmpty);
        expect(h.temp.listSync(), isEmpty);
      },
    );
  });

  group('open and share', () {
    Future<void> bootSaved() async {
      await boot([
        seeded(
          's',
          status: JobStatus.completed,
          save: SaveState.saved,
          savedUri: 'content://media/downloads/9',
        ),
      ]);
      h.media.existing['content://media/downloads/9'] = true;
    }

    test('open passes the content URI and the MIME type', () async {
      await bootSaved();
      expect(await controller().openSaved('s'), FileActionResult.ok);
      expect(
        h.media.events.single,
        'open content://media/downloads/9 video/mp4',
      );
    });

    test('share uses the same URI', () async {
      await bootSaved();
      expect(await controller().shareSaved('s'), FileActionResult.ok);
      expect(
        h.media.events.single,
        startsWith('share content://media/downloads/9'),
      );
    });

    test(
      'a file deleted outside the app is reported and offers Retry save',
      () async {
        await bootSaved();
        h.media.existing['content://media/downloads/9'] = false;
        expect(await controller().openSaved('s'), FileActionResult.fileMissing);
        final entry = state().entryFor('s')!;
        expect(entry.isSaved, isFalse);
        expect(entry.saveState, SaveState.failed);
        expect(entry.saveError, contains('moved or deleted'));
      },
    );

    test('no app to open is distinguished from other failures', () async {
      await bootSaved();
      h.media.openError = const NativeMediaException(
        NativeMediaFailure.noAppToOpen,
        'none',
      );
      expect(await controller().openSaved('s'), FileActionResult.noAppFound);
    });

    test('open on an unsaved entry fails safely', () async {
      await boot([seeded('x')]);
      expect(await controller().openSaved('x'), FileActionResult.failed);
    });
  });

  group('lifecycle and connectivity', () {
    test('pausing stops polling; resuming restarts it', () async {
      h.api.script('j1', [makeJob(id: 'j1', status: JobStatus.downloading)]);
      await boot([seeded('j1')]);
      await eventually(
        () => h.api.calls.where((c) => c == 'get j1').length >= 2,
        reason: 'polling',
      );
      controller().onAppPaused();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final pausedCount = h.api.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        h.api.calls.length,
        pausedCount,
        reason: 'no requests while backgrounded',
      );

      await controller().onAppResumed();
      await eventually(
        () => h.api.calls.length > pausedCount,
        reason: 'resumed polling',
      );
    });

    test('repeated network failure flags the job as unreachable without changing its state', () async {
      h.api.script('j1', [const ApiException.network()]);
      await boot([seeded('j1')]);
      await eventually(
        () => state().lost['j1'] == PollLoss.unreachable,
        timeout: const Duration(seconds: 10),
        reason: 'loss',
      );
      expect(state().entryFor('j1')!.status, JobStatus.downloading);
      expect(state().entryFor('j1')!.serverGone, isFalse);

      // refresh() recovers when the server is back.
      h.api.script('j1', [
        makeJob(
          id: 'j1',
          status: JobStatus.downloading,
          progress: const JobProgress(percent: 10, totalBytes: 100),
        ),
      ]);
      await controller().refresh('j1');
      expect(state().lost.containsKey('j1'), isFalse);
    });

    test('a rejected API key is flagged separately', () async {
      h.api.script('j1', [
        const ApiException(
          kind: ApiFailureKind.server,
          code: 'unauthorized',
          message: 'no',
          status: 401,
        ),
      ]);
      await boot([seeded('j1')]);
      await eventually(
        () => state().lost['j1'] == PollLoss.unauthorized,
        reason: 'unauthorized',
      );
    });
  });

  test('tab providers count and order entries', () async {
    h.api.script('run', [makeJob(id: 'run', status: JobStatus.downloading)]);
    await boot([
      seeded('run'),
      seeded('f', status: JobStatus.failed),
      seeded(
        's',
        status: JobStatus.completed,
        save: SaveState.saved,
        savedUri: 'content://x',
      ),
    ]);
    expect(container.read(tabCountsProvider), (
      active: 1,
      completed: 1,
      failed: 1,
    ));
    expect(container.read(tabIdsProvider(DownloadsTab.failed)).ids, ['f']);
    expect(const IdList(['a']), const IdList(['a']));
    expect(const IdList(['a']) == const IdList(['b']), isFalse);
  });
}
