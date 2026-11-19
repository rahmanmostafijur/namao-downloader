import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/job_poller.dart';
import 'package:namao_app/core/models/api_error.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/history_entry.dart';
import 'package:namao_app/features/downloads/entry_view.dart';

import '../support/fakes.dart';
import '../support/harness.dart';
import '../support/pump_app.dart';

HistoryEntry entry(
  String id,
  String title, {
  JobStatus status = JobStatus.downloading,
  JobProgress progress = const JobProgress(),
  SaveState save = SaveState.none,
  String? savedUri,
  String? saveError,
  bool gone = false,
  ApiErrorBody? error,
  int attempt = 0,
}) => HistoryEntry(
  jobId: id,
  sourceUrl: 'https://youtu.be/$id',
  title: title,
  qualityId: '720',
  qualityLabel: '720p',
  platform: 'youtube',
  createdAt: DateTime.utc(2026, 1, 1),
  job: makeJob(
    id: id,
    status: status,
    progress: progress,
    attempt: attempt,
    error: error,
    result: status == JobStatus.completed
        ? makeResult(sizeBytes: 5 * 1024 * 1024)
        : null,
  ),
  saveState: save,
  savedUri: savedUri,
  savedName: savedUri == null ? null : '$title.mp4',
  savedBytes: savedUri == null ? null : 5 * 1024 * 1024,
  saveError: saveError,
  jobGone: gone,
);

Map<String, Object> prefsFor(List<HistoryEntry> entries) => {
  'history.v1': jsonEncode([for (final e in entries) e.toJson()]),
};

Future<TestHarness> harnessWith(List<HistoryEntry> entries) async {
  final h = await TestHarness.create(prefsValues: prefsFor(entries));
  h.api.hangJobs =
      true; // restored jobs show their persisted snapshot, no poll timers
  return h;
}

Future<void> openDownloads(WidgetTester tester) async {
  await tester.tap(find.text('Downloads').last);
  await settle(tester);
}

void main() {
  setUpAll(loadBundledFonts);

  final active = [
    entry('q', 'Queued video', status: JobStatus.queued),
    entry(
      'd',
      'Downloading video',
      progress: const JobProgress(
        percent: 42,
        downloadedBytes: 21 * 1024 * 1024,
        totalBytes: 50 * 1024 * 1024,
        speedBps: 2 * 1024 * 1024,
        etaSeconds: 14,
      ),
    ),
    entry('m', 'Merging video', status: JobStatus.merging),
    entry('v', 'Verifying video', status: JobStatus.verifying),
  ];

  testWidgets(
    'Active tab: real percentages, speed/ETA/bytes, indeterminate stages',
    (tester) async {
      final h = await harnessWith(active);
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openDownloads(tester);

      expect(find.text('Preparing your download…'), findsOneWidget);
      expect(find.text('Downloading 42%'), findsOneWidget);
      expect(
        find.text('2.0 MB/s · 14s left · 21.0 MB / 50.0 MB'),
        findsOneWidget,
      );
      expect(find.text('Finishing…'), findsNWidgets(2)); // merging and verifying

      // Exactly one determinate bar (the 42% one); queued/merging/verifying are indeterminate.
      final bars = tester.widgetList<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bars.where((b) => b.value != null).length, 1);
      expect(bars.where((b) => b.value == null).length, 3);
      expect(find.text('Cancel'), findsNWidgets(4));

      // Tab counts.
      expect(find.bySemanticsLabel('Active, 4'), findsOneWidget);
      expect(find.bySemanticsLabel('Completed, 0'), findsOneWidget);
      expect(find.bySemanticsLabel('Failed, 0'), findsOneWidget);
    },
  );

  testWidgets(
    'Completed tab: Saved shows Open/Share and a path; Retry save shows the error',
    (tester) async {
      final h = await harnessWith([
        entry(
          's',
          'Saved video',
          status: JobStatus.completed,
          save: SaveState.saved,
          savedUri: 'content://media/1',
        ),
        entry(
          'r',
          'Unsaved video',
          status: JobStatus.completed,
          save: SaveState.failed,
          saveError:
              'Not enough free space on this phone. Free some up and retry.',
        ),
      ]);
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openDownloads(tester);
      await tester.tap(find.bySemanticsLabel('Completed, 2'));
      await settle(tester);

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Downloads/Namao/Saved video.mp4'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.textContaining('Not enough free space'), findsOneWidget);
      expect(find.text('Retry save'), findsOneWidget);
      expect(find.text('5.0 MB'), findsWidgets);
    },
  );

  testWidgets(
    'Failed tab: failed, cancelled, interrupted and expired each have their own label',
    (tester) async {
      final h = await harnessWith([
        entry(
          'f',
          'Failed video',
          status: JobStatus.failed,
          error: const ApiErrorBody(
            code: 'video_unavailable',
            message: 'This video is unavailable. It may be private, deleted, or removed.',
          ),
        ),
        entry('c', 'Cancelled video', status: JobStatus.cancelled),
        entry(
          'i',
          'Interrupted video',
          status: JobStatus.interrupted,
          error: const ApiErrorBody(
            code: 'interrupted',
            message: 'The download was interrupted. Start it again.',
            retryable: true,
          ),
        ),
        entry('e', 'Expired video', gone: true),
      ]);
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openDownloads(tester);
      await tester.tap(find.bySemanticsLabel('Failed, 4'));
      await settle(tester);

      expect(find.text('Failed'), findsWidgets);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Interrupted'), findsOneWidget);
      expect(find.text('No longer available'), findsOneWidget);
      expect(
        find.textContaining('private, deleted, or removed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('interrupted. Start it again'),
        findsOneWidget,
      );
      expect(
        find.textContaining('no longer on this phone'),
        findsOneWidget,
      );
      // Failed (video_unavailable) is not retryable, the rest are.
      expect(find.text('Retry'), findsNWidgets(3));
    },
  );

  testWidgets('empty states per tab', (tester) async {
    final h = await harnessWith([]);
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    await openDownloads(tester);
    expect(find.text('Nothing downloading'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Completed, 0'));
    await settle(tester);
    expect(find.text('No saved videos yet'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Failed, 0'));
    await settle(tester);
    expect(find.text('No problems'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Active, 0'));
    await settle(tester);
    await tester.tap(find.text('Go to Home'));
    await settle(tester);
    expect(find.text('Get formats'), findsOneWidget);
  });

  testWidgets('removing a saved entry asks first and says the file stays', (
    tester,
  ) async {
    final h = await harnessWith([
      entry(
        's',
        'Saved video',
        status: JobStatus.completed,
        save: SaveState.saved,
        savedUri: 'content://media/1',
      ),
    ]);
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    await openDownloads(tester);
    await tester.tap(find.bySemanticsLabel('Completed, 1'));
    await settle(tester);

    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('Remove from history'));
    await settle(tester);
    expect(find.textContaining('stays in Downloads/Namao'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(
      find.text('Saved video'),
      findsOneWidget,
      reason: 'cancel keeps the entry',
    );

    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('Remove from history'));
    await settle(tester);
    await tester.tap(find.text('Remove'));
    await settle(tester);
    expect(find.text('Saved video'), findsNothing);
    expect(h.media.events, isEmpty, reason: 'the media file is never touched');
  });

  testWidgets('swiping a failed entry removes it without a dialog', (
    tester,
  ) async {
    final h = await harnessWith([
      entry('c', 'Cancelled video', status: JobStatus.cancelled),
    ]);
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    await openDownloads(tester);
    await tester.tap(find.bySemanticsLabel('Failed, 1'));
    await settle(tester);
    await tester.drag(find.text('Cancelled video'), const Offset(-500, 0));
    await settle(tester, frames: 12);
    expect(find.text('Cancelled video'), findsNothing);
  });

  testWidgets('Clear finished confirms and keeps running downloads', (
    tester,
  ) async {
    final h = await harnessWith([
      entry('run', 'Running video'),
      entry('c', 'Cancelled video', status: JobStatus.cancelled),
    ]);
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    await openDownloads(tester);
    await tester.tap(find.text('Clear finished'));
    await settle(tester);
    expect(find.textContaining('Running downloads keep going'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await settle(tester);
    expect(find.text('Running video'), findsOneWidget);
    expect(find.bySemanticsLabel('Failed, 0'), findsOneWidget);
  });

  group('describeEntry', () {
    test('lost contact adds a message and Refresh but keeps Cancel', () {
      final view = describeEntry(entry('d', 'x'), lost: PollLoss.unreachable);
      expect(view.message, contains("Can't update the progress"));
      expect(view.canRefresh, isTrue);
      expect(view.canCancel, isTrue);
    });

    test('finished, being moved into Downloads', () {
      final e = entry(
        't',
        'x',
        status: JobStatus.completed,
        save: SaveState.transferring,
      );
      final view = describeEntry(e);
      expect(view.label, 'Finishing…');
      expect(view.showProgress, isTrue);
      expect(view.progress, isNull, reason: 'indeterminate: no made-up percentage');
    });

    test('finished but not started saving says Ready, finishing', () {
      final view = describeEntry(entry('t', 'x', status: JobStatus.completed));
      expect(view.label, 'Ready');
      expect(view.message, 'Finishing…');
      expect(view.showProgress, isTrue);
    });

    test('saved wins over every server state', () {
      final view = describeEntry(
        entry(
          't',
          'x',
          status: JobStatus.completed,
          save: SaveState.saved,
          savedUri: 'u',
        ),
      );
      expect(view.label, 'Saved');
      expect(view.canRemove, isTrue);
      expect(view.isSaved, isTrue);
    });
  });
}
