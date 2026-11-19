/// Regression tests for the issues found in code review (each test names the failure it prevents).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/job_poller.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/history_entry.dart';
import 'package:namao_app/data/providers.dart';
import 'package:namao_app/features/downloads/downloads_state.dart';
import 'package:namao_app/features/home/home_controller.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

const ApiException _unreadable = ApiException(
  code: 'environment_unsupported',
  message: 'Not ready.',
  retryable: true,
);

HistoryEntry entryOn(String id, {JobStatus status = JobStatus.downloading}) =>
    HistoryEntry(
      jobId: id,
      sourceUrl: 'https://youtu.be/$id',
      title: 'T $id',
      qualityId: '720',
      qualityLabel: '720p',
      platform: 'youtube',
      createdAt: DateTime.utc(2026, 1, 1),
      job: makeJob(id: id, status: status),
    );

void main() {
  late TestHarness h;
  late ProviderContainer container;

  setUp(() async {
    h = await TestHarness.create();
    container = h.container();
  });

  tearDown(() => h.dispose());

  group('Download tap', () {
    Future<HomeController> readyHome() async {
      container.listen(downloadsProvider, (_, _) {});
      await eventually(() => container.read(downloadsProvider).isLoaded);
      final home = container.read(homeProvider.notifier);
      home.setInput('https://youtu.be/abc');
      await home.fetchFormats();
      return home;
    }

    test('re-selecting the same format after a failed tap does not crash', () async {
      h.api.hangJobs = true;
      final home = await readyHome();
      home.selectFormat('1080');
      h.api.createResult = _unreadable;
      await home.startDownload();
      expect(container.read(homeProvider).isStarting, isFalse);

      home.selectFormat('1080'); // the same row tapped again
      h.api.createResult = 'auto';
      await home.startDownload();
      expect(h.api.idempotencyKeys, ['key-1', 'key-2']);
      expect(container.read(homeProvider).addedJobId, isNotNull);
    });

    test('an unexpected local error resets the button instead of leaving it loading', () async {
      h.api.hangJobs = true;
      final home = await readyHome();
      home.selectFormat('1080');
      container.read(downloadsProvider); // start the controller
      h.api.createResult = StateError('boom'); // an Error, not an ApiException
      await home.startDownload();
      expect(container.read(homeProvider).isStarting, isFalse);
      expect(container.read(homeProvider).startError, isNotNull);
    });
  });

  group('retry', () {
    test(
      'a double tap creates one job (in-flight guard + deterministic key)',
      () async {
        await container.read(historyStoreProvider).save([
          entryOn('old', status: JobStatus.failed),
        ]);
        container.listen(downloadsProvider, (_, _) {});
        await eventually(() => container.read(downloadsProvider).isLoaded);
        h.api.createResult = makeJob(id: 'new', status: JobStatus.downloading);
        h.api.hangJobs = true;
        final first = container.read(downloadsProvider.notifier).retry('old');
        final second = container.read(downloadsProvider.notifier).retry('old');
        await Future.wait([first, second]);
        expect(h.api.calls.where((c) => c.startsWith('create')).length, 1);
      },
    );
  });

  group('a missing job versus a failure to read it', () {
    test('only a missing job or file means the download is gone', () {
      const missing = ApiException(code: 'not_found', message: 'x', status: 404);
      const expired = ApiException(code: 'expired', message: 'x', status: 410);
      expect(missing.isJobGone, isTrue);
      expect(expired.isJobGone, isTrue);
      expect(_unreadable.isJobGone, isFalse);
    });

    test('the poller treats a failure to read as transient, not as gone', () async {
      final api = FakeApi()..script('j', [_unreadable]);
      final losses = <PollLoss>[];
      await JobPoller(
        api: api,
        jobId: 'j',
        onJob: (_) {},
        onLost: (r, e) => losses.add(r),
        maxConsecutiveFailures: 2,
        delay: (_) async {},
      ).start();
      expect(losses, [PollLoss.unreachable]);
      api.dispose();
    });
  });

  group('poller', () {
    test('a throwing callback leaves the poller restartable', () async {
      final api = FakeApi()
        ..script('j', [makeJob(id: 'j', status: JobStatus.downloading)]);
      final poller = JobPoller(
        api: api,
        jobId: 'j',
        onJob: (_) => throw StateError('callback bug'),
        onLost: (r, e) {},
        delay: (_) async {},
      );
      await expectLater(poller.start(), throwsStateError);
      expect(poller.isRunning, isFalse);
      api.dispose();
    });
  });

  group('saving', () {
    test('an unexpected exception during a save ends in a recoverable failed state', () async {
      h.api.files['c'] = List.generate(8, (i) => i);
      h.api.script('c', [
        makeJob(
          id: 'c',
          status: JobStatus.completed,
          result: makeResult(sizeBytes: 8),
        ),
      ]);
      h.media.saveUnexpected = true;
      await container.read(historyStoreProvider).save([
        entryOn('c', status: JobStatus.completed).copyWith(
          job: makeJob(
            id: 'c',
            status: JobStatus.completed,
            result: makeResult(sizeBytes: 8),
          ),
        ),
      ]);
      container.listen(downloadsProvider, (_, _) {});
      await eventually(
        () =>
            container.read(downloadsProvider).entryFor('c')?.saveState ==
            SaveState.failed,
      );
      expect(
        container.read(downloadsProvider).entryFor('c')!.saveError,
        contains('unexpectedly'),
      );
      await eventually(
        () => h.media.events.where((e) => e == 'stopTransfer').length == 1,
        reason: 'the notification is stopped once nothing is active',
      );
      expect(h.api.hasWorkingFile('c'), isTrue, reason: 'kept so Retry save can work');
    });
  });
}
