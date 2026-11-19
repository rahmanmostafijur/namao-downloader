/// Regression tests for the issues found in code review (each test names the failure it prevents).
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/api/http_namao_api.dart';
import 'package:namao_app/core/job_poller.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/file_saver.dart';
import 'package:namao_app/data/history_entry.dart';
import 'package:namao_app/data/providers.dart';
import 'package:namao_app/features/downloads/downloads_state.dart';
import 'package:namao_app/features/downloads/entry_view.dart';
import 'package:namao_app/features/home/home_controller.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

HistoryEntry entryOn(
  String id,
  String? server, {
  JobStatus status = JobStatus.downloading,
}) => HistoryEntry(
  jobId: id,
  sourceUrl: 'https://youtu.be/$id',
  title: 'T $id',
  qualityId: '720',
  qualityLabel: '720p',
  platform: 'youtube',
  createdAt: DateTime.utc(2026, 1, 1),
  job: makeJob(id: id, status: status),
  serverUrl: server,
);

void main() {
  late TestHarness h;
  late ProviderContainer container;

  setUp(() async {
    h = await TestHarness.create();
    container = h.container();
  });

  tearDown(() => h.dispose());

  group('Download tap / idempotency key', () {
    Future<HomeController> readyHome() async {
      container.listen(downloadsProvider, (_, _) {});
      await eventually(() => container.read(downloadsProvider).isLoaded);
      final home = container.read(homeProvider.notifier);
      home.setInput('https://youtu.be/abc');
      await home.fetchFormats();
      return home;
    }

    test('re-selecting the same format after a failed tap reuses the key and does not crash', () async {
      h.api.hangJobs = true;
      final home = await readyHome();
      home.selectFormat('1080');
      h.api.createResult = const ApiException.network();
      await home.startDownload();
      expect(container.read(homeProvider).isStarting, isFalse);

      home.selectFormat('1080'); // the same row tapped again
      h.api.createResult = 'auto';
      await home.startDownload();
      expect(h.api.idempotencyKeys, ['key-1', 'key-1']);
      expect(container.read(homeProvider).addedJobId, isNotNull);
    });

    test('choosing a different format gets a different key', () async {
      h.api.hangJobs = true;
      final home = await readyHome();
      home.selectFormat('1080');
      h.api.createResult = const ApiException.network();
      await home.startDownload();
      home.selectFormat('720');
      h.api.createResult = 'auto';
      await home.startDownload();
      expect(h.api.idempotencyKeys, ['key-1', 'key-2']);
    });

    test(
      'a 503 (the job may exist already) keeps the key; a 400 refusal does not',
      () async {
        h.api.hangJobs = true;
        final home = await readyHome();
        home.selectFormat('1080');
        h.api.createResult = const ApiException(
          kind: ApiFailureKind.server,
          code: 'http_503',
          message: 'x',
          status: 503,
          retryable: true,
        );
        await home.startDownload();
        await home.startDownload();
        expect(h.api.idempotencyKeys, ['key-1', 'key-1']);

        h.api.createResult = const ApiException(
          kind: ApiFailureKind.server,
          code: 'invalid_quality',
          message: 'nope',
          status: 400,
        );
        await home.startDownload();
        h.api.createResult = const ApiException(
          kind: ApiFailureKind.server,
          code: 'invalid_quality',
          message: 'nope',
          status: 400,
        );
        await home.startDownload();
        expect(h.api.idempotencyKeys.sublist(2), [
          'key-1',
          'key-2',
        ], reason: 'the 400 dropped the key');
      },
    );

    test('an unexpected local error resets the button instead of leaving it loading', () async {
      h.api.hangJobs = true;
      final home = await readyHome();
      home.selectFormat('1080');
      h.api.createResult = 'auto';
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
          entryOn('old', null, status: JobStatus.failed),
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

  group('jobs belong to one server', () {
    test(
      'entries of another server are not polled, saved or marked expired',
      () async {
        await container.read(historyStoreProvider).save([
          entryOn('mine', 'http://10.0.2.2:8000'),
          entryOn('theirs', 'http://other.example:8000'),
          entryOn('legacy', null),
        ]);
        h.api.hangJobs = true;
        container.listen(downloadsProvider, (_, _) {});
        await eventually(() => container.read(downloadsProvider).isLoaded);
        await eventually(() => h.api.calls.contains('get legacy'));
        expect(h.api.calls, contains('get mine'));
        expect(h.api.calls, isNot(contains('get theirs')));

        final theirs = container.read(downloadsProvider).entryFor('theirs')!;
        final view = describeEntry(theirs, otherServer: true);
        expect(view.label, 'On another server');
        expect(view.message, contains('other.example:8000'));
        expect(view.canRemove, isTrue);
        expect(view.canCancel, isFalse);
      },
    );

    test('new downloads record the server they were created on', () async {
      container.listen(downloadsProvider, (_, _) {});
      await eventually(() => container.read(downloadsProvider).isLoaded);
      h.api.hangJobs = true;
      final entry = await container
          .read(downloadsProvider.notifier)
          .start(
            sourceUrl: 'https://youtu.be/x',
            metadata: sampleMetadata,
            format: sampleMetadata.formats[1],
            idempotencyKey: 'k-12345678',
          );
      expect(entry.serverUrl, 'http://10.0.2.2:8000');
      expect(
        container.read(historyStoreProvider).load().single.serverUrl,
        'http://10.0.2.2:8000',
      );
    });

    test('a bare proxy 404 does not mean the job expired; the server envelope does', () {
      const proxy = ApiException(
        kind: ApiFailureKind.server,
        code: 'http_404',
        message: 'x',
        status: 404,
      );
      const real = ApiException(
        kind: ApiFailureKind.server,
        code: 'not_found',
        message: 'x',
        status: 404,
      );
      const gone = ApiException(
        kind: ApiFailureKind.server,
        code: 'expired',
        message: 'x',
        status: 410,
      );
      expect(proxy.isJobGone, isFalse);
      expect(real.isJobGone, isTrue);
      expect(gone.isJobGone, isTrue);
    });

    test('the poller treats a proxy 404 as a transient failure', () async {
      final api = FakeApi()
        ..script('j', [
          const ApiException(
            kind: ApiFailureKind.server,
            code: 'http_404',
            message: 'x',
            status: 404,
          ),
        ]);
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
    });
  });

  group('transfers', () {
    test('an unexpected exception during a save ends in a recoverable failed state', () async {
      h.api.files['c'] = List.generate(8, (i) => i);
      h.api.script('c', [
        makeJob(
          id: 'c',
          status: JobStatus.completed,
          result: makeResult(id: 'c', sizeBytes: 8),
        ),
      ]);
      h.media.saveUnexpected = true;
      await container.read(historyStoreProvider).save([
        entryOn(
          'c',
          'http://10.0.2.2:8000',
          status: JobStatus.completed,
        ).copyWith(
          job: makeJob(
            id: 'c',
            status: JobStatus.completed,
            result: makeResult(id: 'c', sizeBytes: 8),
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
      expect(
        h.media.events.where((e) => e == 'stopTransfer').length,
        1,
        reason: 'the service is stopped',
      );
      expect(h.temp.listSync(), isEmpty);
    });

    test(
      'the foreground service is not started when nothing will transfer',
      () async {
        await container.read(historyStoreProvider).save([
          entryOn(
            'x',
            'http://other.example:8000',
            status: JobStatus.completed,
          ).copyWith(
            job: makeJob(
              id: 'x',
              status: JobStatus.completed,
              result: makeResult(id: 'x', sizeBytes: 8),
            ),
          ),
        ]);
        container.listen(downloadsProvider, (_, _) {});
        await eventually(() => container.read(downloadsProvider).isLoaded);
        container.read(downloadsProvider.notifier).saveToDevice('x');
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(h.media.events, isEmpty);
      },
    );

    test(
      'a cancelled token stops the save before anything reaches MediaStore',
      () async {
        final temp = Directory.systemTemp.createTempSync('namao_cancel');
        addTearDown(() => temp.deleteSync(recursive: true));
        final api = FakeApi()..files['j'] = [1, 2, 3];
        final saver = FileSaver(
          api: api,
          media: h.media,
          tempDirectory: () => temp,
        );
        final token = TransferToken()..cancel();
        await expectLater(
          saver.save(
            jobId: 'j',
            filename: 'a.mp4',
            expectedBytes: 3,
            token: token,
          ),
          throwsA(isA<TransferException>()),
        );
        expect(h.media.events, isEmpty);
      },
    );

    test('large transfers flush periodically (errors surface early) and still verify', () async {
      final temp = Directory.systemTemp.createTempSync('namao_flush');
      addTearDown(() => temp.deleteSync(recursive: true));
      final big = List<int>.filled(3 * 1024 * 1024 + 7, 9);
      final api = FakeApi()
        ..files['j'] = big
        ..chunkSize = 64 * 1024;
      final saver = FileSaver(
        api: api,
        media: h.media,
        tempDirectory: () => temp,
      );
      final saved = await saver.save(
        jobId: 'j',
        filename: 'a.mp4',
        expectedBytes: big.length,
      );
      expect(saved.sizeBytes, big.length);
    });
  });

  group(
    'HTTP client never follows redirects (the API key must not be forwarded)',
    () {
      test('requests are sent with followRedirects disabled and a 301 becomes a clear error', () async {
        final seen = <http.BaseRequest>[];
        final api = HttpNamaoApi(
          baseUrl: 'http://example.test',
          apiKey: 'secret',
          client: MockClient((request) async {
            seen.add(request);
            return http.Response(
              '',
              301,
              headers: {'location': 'https://elsewhere.example/'},
            );
          }),
        );
        await expectLater(
          api.getJob('x'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', 301)
                .having((e) => e.message, 'message', contains('redirected')),
          ),
        );
        expect(seen.single.followRedirects, isFalse);
      });

      test('openFile is not redirect-following either', () async {
        late http.BaseRequest seen;
        final client = MockClient.streaming((request, _) async {
          seen = request;
          return http.StreamedResponse(const Stream.empty(), 302);
        });
        final api = HttpNamaoApi(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          client: client,
        );
        await expectLater(api.openFile('x'), throwsA(isA<ApiException>()));
        expect(seen.followRedirects, isFalse);
      });
    },
  );
}
