import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/models/api_error.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/history_entry.dart';
import 'package:namao_app/design/progress_bar.dart';
import 'package:namao_app/design/tokens.dart';

import '../support/harness.dart';
import '../support/pump_app.dart';
import 'downloads_screen_test.dart' show entry, prefsFor;

const _phone = Size(360, 640);

List<HistoryEntry> _mixedHistory() => [
  entry(
    'd',
    'A very long download title that needs to wrap across more than one line on a small phone screen',
    progress: const JobProgress(
      percent: 42,
      downloadedBytes: 21 * 1024 * 1024,
      totalBytes: 50 * 1024 * 1024,
      speedBps: 2 * 1024 * 1024,
      etaSeconds: 3725,
    ),
  ),
  entry(
    'f',
    'Failed video',
    status: JobStatus.failed,
    error: const ApiErrorBody(
      code: 'access_blocked',
      message: "The source site refused the request from this server's network. Retrying or updating may not help.",
      retryable: true,
    ),
  ),
  entry(
    's',
    'Saved video',
    status: JobStatus.completed,
    save: SaveState.saved,
    savedUri: 'content://media/1',
  ),
];

void main() {
  setUpAll(loadBundledFonts);

  group('text scale 1.5 produces no overflow', () {
    testWidgets('Home: idle, formats and the sticky Download bar', (
      tester,
    ) async {
      final h = await TestHarness.create();
      h.api.hangJobs = true;
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: _phone, textScale: 1.5);
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
      await settle(tester);
      await tester.tap(find.text('Get formats'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('1080p'));
      await settle(tester);
      await tester.tap(find.text('1080p'));
      await settle(tester);
      expect(find.text('Download 1080p'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Download 1080p'));
      await settle(tester);
      expect(find.text('Added to Downloads'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Downloads: every tab with rows in every state', (
      tester,
    ) async {
      final h = await TestHarness.create(
        prefsValues: prefsFor(_mixedHistory()),
      );
      h.api.hangJobs = true;
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: _phone, textScale: 1.5);
      await tester.tap(find.text('Downloads').last);
      await settle(tester);
      expect(tester.takeException(), isNull);
      for (final label in ['Completed, 1', 'Failed, 1', 'Active, 1']) {
        await tester.tap(find.bySemanticsLabel(label));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: label);
      }
    });

    testWidgets('Settings and setup', (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: _phone, textScale: 1.5);
      await tester.tap(find.text('Settings').last);
      await settle(tester);
      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('responsive navigation', () {
    testWidgets('narrow screens use a NavigationBar', (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: const Size(599, 800));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('>= 600dp uses a NavigationRail and still lays out cleanly', (
      tester,
    ) async {
      final h = await TestHarness.create(
        prefsValues: prefsFor(_mixedHistory()),
      );
      h.api.hangJobs = true;
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: const Size(840, 600));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text('Downloads').last);
      await settle(tester);
      expect(
        find.text(
          'A very long download title that needs to wrap across more than one line on a small phone screen',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('landscape phone works', (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: const Size(800, 360));
      await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('accessibility', () {
    testWidgets('primary controls have >= 48dp touch targets', (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h, size: _phone);
      await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
      await settle(tester);
      for (final finder in [
        find.widgetWithText(FilledButton, 'Get formats'),
        find.widgetWithText(OutlinedButton, 'Paste'),
        find.byTooltip('Clear'),
        find.byType(NavigationDestination).first,
      ]) {
        final size = tester.getSize(finder.first);
        expect(
          size.height,
          greaterThanOrEqualTo(NamaoLayout.touchTarget - 0.5),
          reason: '$finder',
        );
      }
    });

    testWidgets('key controls expose semantics labels', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await TestHarness.create();
      h.api.hangJobs = true;
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
      await settle(tester);
      expect(find.bySemanticsLabel('Detected YouTube'), findsOneWidget);
      await tester.tap(find.text('Get formats'));
      await settle(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^1080p')).first),
        matchesSemantics(
          isButton: true,
          isSelected: false,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
          hasSelectedState: true,
          hasEnabledState: false,
          label: '1080p, MP4, 30.0 MB',
        ),
      );
      handle.dispose();
    });

    testWidgets(
      'reduce motion: durations collapse to zero and bars stay static',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        late Duration resolved;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                resolved = NamaoMotion.of(context);
                return const Scaffold(body: NamaoProgressBar());
              },
            ),
          ),
        );
        expect(resolved, Duration.zero);
        expect(
          find.byType(LinearProgressIndicator),
          findsNothing,
          reason: 'no animated bar',
        );
      },
    );
  });
}
