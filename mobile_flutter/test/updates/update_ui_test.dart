import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/updates/apk_installer.dart';
import 'package:namao_app/data/updates/engine_update_source.dart';

import '../support/harness.dart';
import '../support/pump_app.dart';
import '../support/update_fakes.dart';

const String _old = '2026.10.05';
const String _new = '2026.11.10';

EngineInfo _stale({bool auto = true}) => EngineInfo(
  version: _old,
  autoUpdate: auto,
  lastCheck: DateTime.now().subtract(const Duration(hours: 30)),
);

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Settings').last);
  await settle(tester);
}

Future<void> scrollToUpdates(WidgetTester tester) => tester.scrollUntilVisible(
  find.text('Check for updates'),
  300,
  scrollable: find.byType(Scrollable).first,
);

/// File writes finish on the real event loop; this lets them, then lets the app react.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(loadBundledFonts);

  group('Settings', () {
    testWidgets(
      'has an Updates section in plain words, with no technical names',
      (tester) async {
        final h = await TestHarness.create();
        addTearDown(h.dispose);
        await pumpNamao(tester, h);
        await openSettings(tester);
        await scrollToUpdates(tester);

        expect(find.text('UPDATES'), findsOneWidget);
        expect(find.text('Download support'), findsOneWidget);
        expect(find.text('Released 10 Nov 2026'), findsOneWidget);
        expect(
          find.text('Update download support automatically'),
          findsOneWidget,
        );
        expect(find.byType(Switch), findsOneWidget);
        final technical = RegExp(
          r'yt-?dlp|ffmpeg|python|backend',
          caseSensitive: false,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && technical.hasMatch(w.data ?? ''),
          ),
          findsNothing,
        );
      },
    );

    testWidgets('turning the switch off is saved', (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openSettings(tester);
      await scrollToUpdates(tester);

      await tester.tap(find.byType(Switch));
      await settle(tester);

      expect(h.engineUpdates.calls, contains('auto false'));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('Check for updates refreshes download support and says so', (
      tester,
    ) async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(latest: _new)
          ..current = EngineInfo(version: _old, lastCheck: DateTime.now()),
      );
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openSettings(tester);
      await scrollToUpdates(tester);

      await tester.tap(find.text('Check for updates'));
      await settle(tester);

      expect(
        find.textContaining("Namao's download support has been updated."),
        findsWidgets,
      );
      expect(
        find.textContaining('Download support last updated'),
        findsOneWidget,
      );
      expect(find.text('Released 10 Nov 2026'), findsOneWidget);
    });

    testWidgets(
      'Check for updates with nothing newer says everything is up to date',
      (tester) async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(latest: '2026.11.10'),
        );
        addTearDown(h.dispose);
        await pumpNamao(tester, h);
        await openSettings(tester);
        await scrollToUpdates(tester);

        await tester.tap(find.text('Check for updates'));
        await settle(tester);

        expect(find.text('Everything is up to date.'), findsOneWidget);
      },
    );

    testWidgets('a network failure shows a friendly message, not a log', (
      tester,
    ) async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(latest: _new)
          ..latestError = const EngineUpdateException(
            'network',
            'SocketException: ...',
          ),
      );
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openSettings(tester);
      await scrollToUpdates(tester);

      await tester.tap(find.text('Check for updates'));
      await settle(tester);

      expect(find.textContaining("Couldn't check for updates"), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
    });
  });

  group('launch', () {
    testWidgets('a refreshed downloader is announced once, in friendly words', (
      tester,
    ) async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(info: _stale(), latest: _new),
      );
      addTearDown(h.dispose);

      await pumpNamao(tester, h);

      expect(
        find.textContaining("Namao's download support has been updated."),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          "We've improved download compatibility and reliability.",
        ),
        findsOneWidget,
      );
      expect(h.engineUpdates.current.version, _new);
    });

    testWidgets(
      'nothing is announced when the downloader was checked recently',
      (tester) async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(latest: _new),
        );
        addTearDown(h.dispose);

        await pumpNamao(tester, h);

        expect(
          find.textContaining('download support has been updated'),
          findsNothing,
        );
        expect(
          h.engineUpdates.calls.any((c) => c.startsWith('install')),
          isFalse,
        );
      },
    );

    testWidgets('no prompt when the newest release is not newer', (
      tester,
    ) async {
      final h = await TestHarness.create(
        releases: FakeReleaseSource()..release = makeRelease(version: '1.0.0'),
      );
      addTearDown(h.dispose);

      await pumpNamao(tester, h);

      expect(find.textContaining('is available'), findsNothing);
    });

    testWidgets('a release dismissed earlier does not prompt again', (
      tester,
    ) async {
      final until = DateTime.now()
          .add(const Duration(days: 3))
          .millisecondsSinceEpoch;
      final h = await TestHarness.create(
        releases: FakeReleaseSource()..release = makeRelease(version: '9.9.9'),
        prefsValues: {
          'updates.app_snoozed_version': '9.9.9',
          'updates.app_snoozed_until_ms': until,
        },
      );
      addTearDown(h.dispose);

      await pumpNamao(tester, h);

      expect(h.releases.calls, 1);
      expect(find.text('Namao 9.9.9 is available'), findsNothing);
    });
  });

  group('app update prompt', () {
    testWidgets(
      'shows the version and notes; Remind me later closes it and is remembered',
      (tester) async {
        final h = await TestHarness.create(
          releases: FakeReleaseSource()
            ..release = makeRelease(
              version: '9.9.9',
              notes: '• Faster downloads',
            ),
        );
        addTearDown(h.dispose);

        await pumpNamao(tester, h);

        expect(find.text('Namao 9.9.9 is available'), findsOneWidget);
        expect(find.text('• Faster downloads'), findsOneWidget);
        expect(find.text('Update'), findsOneWidget);

        await tester.tap(find.text('Remind me later'));
        await settle(tester);

        expect(find.text('Namao 9.9.9 is available'), findsNothing);
        expect(h.prefs.getString('updates.app_snoozed_version'), '9.9.9');
        expect(h.installer.installedPaths, isEmpty);
      },
    );

    testWidgets(
      'only the person tapping Update starts the download and the Android install',
      (tester) async {
        final bytes = List<int>.generate(24, (i) => i + 1);
        final h = await TestHarness.create(
          releases: FakeReleaseSource()
            ..release = makeRelease(
              version: '9.9.9',
              sha256: crypto.sha256.convert(bytes).toString(),
              sizeBytes: bytes.length,
            ),
          apkBytes: FakeApkByteSource(bytes),
        );
        addTearDown(h.dispose);
        await pumpNamao(tester, h);

        expect(h.apkBytes.opened, 0);
        expect(h.installer.installedPaths, isEmpty);

        await tester.tap(find.text('Update'));
        await pumpUntil(tester, () => h.installer.installedPaths.isNotEmpty);

        expect(h.installer.installedPaths, hasLength(1));
        expect(
          File(h.installer.installedPaths.single).readAsBytesSync(),
          bytes,
        );
        expect(find.text('Almost there'), findsOneWidget);
        expect(
          find.textContaining('Confirm the installation on the next screen'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'when installing here cannot work, the person is shown how to do it by hand',
      (tester) async {
        final bytes = List<int>.generate(12, (i) => i);
        final release = makeRelease(
          version: '9.9.9',
          sha256: crypto.sha256.convert(bytes).toString(),
          sizeBytes: bytes.length,
        );
        final h = await TestHarness.create(
          releases: FakeReleaseSource()..release = release,
          apkBytes: FakeApkByteSource(bytes),
          installer: FakeApkInstaller()
            ..startResult = const InstallStart(
              InstallStartKind.rejected,
              reason: 'signature_mismatch',
            ),
        );
        addTearDown(h.dispose);
        await pumpNamao(tester, h);

        await tester.tap(find.text('Update'));
        await pumpUntil(
          tester,
          () => find.text("Couldn't update").evaluate().isNotEmpty,
        );

        expect(find.text("Couldn't update"), findsOneWidget);
        expect(find.textContaining('install it yourself'), findsOneWidget);
        expect(find.textContaining('signature'), findsNothing);

        await tester.tap(find.text('Open download page'));
        await settle(tester);
        expect(h.installer.openedLinks, [release.pageUrl]);
      },
    );
  });
}
