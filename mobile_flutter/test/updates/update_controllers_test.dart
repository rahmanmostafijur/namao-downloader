import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/providers.dart';
import 'package:namao_app/data/updates/apk_installer.dart';
import 'package:namao_app/data/updates/engine_update_source.dart';
import 'package:namao_app/data/updates/engine_updater.dart';
import 'package:namao_app/data/updates/https_get.dart';
import 'package:namao_app/features/downloads/downloads_state.dart';
import 'package:namao_app/features/updates/app_update_controller.dart';
import 'package:namao_app/features/updates/engine_update_controller.dart';

import '../support/harness.dart';
import '../support/update_fakes.dart';

final DateTime _t0 = DateTime(2026, 11, 22, 12);
const String _old = '2026.10.05';
const String _new = '2026.11.10';

ProviderContainer _container(
  TestHarness h, {
  DateTime? now,
  int activeDownloads = 0,
}) {
  final container = ProviderContainer(
    overrides: [
      ...h.overrides,
      clockProvider.overrideWithValue(() => now ?? _t0),
      if (activeDownloads > 0)
        tabCountsProvider.overrideWithValue((
          active: activeDownloads,
          completed: 0,
          failed: 0,
        )),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

EngineInfo _engineInfo({
  Duration? checkedAgo,
  Duration? attemptedAgo,
  bool auto = true,
}) => EngineInfo(
  version: _old,
  autoUpdate: auto,
  lastCheck: checkedAgo == null ? null : _t0.subtract(checkedAgo),
  lastAttempt: attemptedAgo == null ? null : _t0.subtract(attemptedAgo),
);

void main() {
  group('download support updates', () {
    test(
      'the launch check refreshes a stale engine and counts one announcement',
      () async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(
            info: _engineInfo(checkedAgo: const Duration(hours: 30)),
            latest: _new,
          ),
        );
        addTearDown(h.dispose);
        final c = _container(h);

        await c.read(engineUpdateProvider.notifier).autoCheck();

        final state = c.read(engineUpdateProvider);
        expect(state.outcome?.kind, EngineUpdateKind.updated);
        expect(state.updatedCount, 1);
        expect(state.isBusy, isFalse);
        expect(h.engineUpdates.current.version, _new);
      },
    );

    test(
      'the launch check does nothing when one ended well within a day',
      () async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(
            info: _engineInfo(checkedAgo: const Duration(hours: 2)),
            latest: _new,
          ),
        );
        addTearDown(h.dispose);
        final c = _container(h);

        await c.read(engineUpdateProvider.notifier).autoCheck();

        expect(h.engineUpdates.calls, ['info']);
        expect(c.read(engineUpdateProvider).updatedCount, 0);
      },
    );

    test(
      'the launch check does nothing when automatic updates are switched off',
      () async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(
            info: _engineInfo(auto: false),
            latest: _new,
          ),
        );
        addTearDown(h.dispose);
        final c = _container(h);

        await c.read(engineUpdateProvider.notifier).autoCheck();

        expect(h.engineUpdates.calls, ['info']);
      },
    );

    test('a failed attempt is not retried on the very next launch', () async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(
          info: _engineInfo(attemptedAgo: const Duration(hours: 1)),
          latest: _new,
        ),
      );
      addTearDown(h.dispose);
      final c = _container(h);

      await c.read(engineUpdateProvider.notifier).autoCheck();

      expect(h.engineUpdates.calls, ['info']);
    });

    test('a manual check runs even right after an automatic one', () async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(
          info: _engineInfo(checkedAgo: const Duration(minutes: 5)),
          latest: _new,
        ),
      );
      addTearDown(h.dispose);
      final c = _container(h);

      await c.read(engineUpdateProvider.notifier).checkNow();

      expect(
        c.read(engineUpdateProvider).outcome?.kind,
        EngineUpdateKind.updated,
      );
      expect(c.read(engineUpdateProvider).info?.version, _new);
    });

    test(
      'a manual check with nothing newer says so and announces nothing',
      () async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(
            info: _engineInfo(),
            latest: _old,
          ),
        );
        addTearDown(h.dispose);
        final c = _container(h);

        await c.read(engineUpdateProvider.notifier).checkNow();

        final state = c.read(engineUpdateProvider);
        expect(state.outcome?.kind, EngineUpdateKind.upToDate);
        expect(state.updatedCount, 0);
      },
    );

    test('no update is attempted while a download is active', () async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(
          info: _engineInfo(),
          latest: _new,
        ),
      );
      addTearDown(h.dispose);
      final c = _container(h, activeDownloads: 1);
      final engine = c.read(engineUpdateProvider.notifier);

      await engine.autoCheck();
      await engine.checkNow();

      expect(c.read(engineUpdateProvider).outcome?.kind, EngineUpdateKind.busy);
      expect(
        h.engineUpdates.calls.where(
          (call) => call == 'latest' || call.startsWith('install'),
        ),
        isEmpty,
      );
      expect(h.engineUpdates.current.version, _old);
    });

    test(
      'a failed update is reported and the working engine is untouched',
      () async {
        final h = await TestHarness.create(
          engineUpdates: FakeEngineUpdateSource(
            info: _engineInfo(),
            latest: _new,
          )..installError = const EngineUpdateException('verify_failed', 'x'),
        );
        addTearDown(h.dispose);
        final c = _container(h);

        await c.read(engineUpdateProvider.notifier).checkNow();

        final state = c.read(engineUpdateProvider);
        expect(state.outcome?.kind, EngineUpdateKind.failed);
        expect(state.updatedCount, 0);
        expect(state.info?.version, _old);
      },
    );

    test('progress is shown while the update installs', () async {
      final gate = Completer<void>();
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(info: _engineInfo(), latest: _new)
          ..installGate = gate,
      );
      addTearDown(h.dispose);
      final c = _container(h);

      final running = c.read(engineUpdateProvider.notifier).checkNow();
      await eventually(
        () => c.read(engineUpdateProvider).phase == EngineUpdatePhase.updating,
        reason: 'the update to report progress',
      );
      expect(c.read(engineUpdateProvider).progress, 0.4);

      gate.complete();
      h.engineUpdates.installGate = null;
      await running;

      final state = c.read(engineUpdateProvider);
      expect(state.isBusy, isFalse);
      expect(state.progress, isNull);
      expect(state.outcome?.kind, EngineUpdateKind.updated);
    });

    test('the automatic-updates switch is saved and then respected', () async {
      final h = await TestHarness.create(
        engineUpdates: FakeEngineUpdateSource(
          info: _engineInfo(),
          latest: _new,
        ),
      );
      addTearDown(h.dispose);
      final c = _container(h);
      final engine = c.read(engineUpdateProvider.notifier);
      await engine.refresh();

      await engine.setAutoUpdate(false);
      await engine.autoCheck();

      expect(h.engineUpdates.calls, contains('auto false'));
      expect(c.read(engineUpdateProvider).info?.autoUpdate, isFalse);
      expect(
        h.engineUpdates.calls.any((call) => call.startsWith('install')),
        isFalse,
      );
    });
  });

  group('app updates', () {
    // FakeNativeMedia reports the installed app as 1.0.0 (1).
    test('a newer release is found and announced', () async {
      final h = await TestHarness.create(
        releases: FakeReleaseSource()..release = makeRelease(version: '1.2.0'),
      );
      addTearDown(h.dispose);
      final c = _container(h);

      await c.read(appUpdateProvider.notifier).checkNow();

      final state = c.read(appUpdateProvider);
      expect(state.release?.versionName, '1.2.0');
      expect(state.announce, isTrue);
      expect(state.upToDate, isFalse);
    });

    test('the same or an older release is not an update', () async {
      for (final version in ['1.0.0', '0.9.0']) {
        final h = await TestHarness.create(
          releases: FakeReleaseSource()
            ..release = makeRelease(version: version),
        );
        addTearDown(h.dispose);
        final c = _container(h);

        await c.read(appUpdateProvider.notifier).checkNow();

        final state = c.read(appUpdateProvider);
        expect(state.release, isNull, reason: version);
        expect(state.upToDate, isTrue, reason: version);
        expect(state.announce, isFalse, reason: version);
      }
    });

    test('with no release published there is nothing to offer', () async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      final c = _container(h);

      await c.read(appUpdateProvider.notifier).checkNow();

      expect(c.read(appUpdateProvider).release, isNull);
      expect(c.read(appUpdateProvider).upToDate, isTrue);
    });

    test('the launch check runs at most once a day', () async {
      final h = await TestHarness.create(
        releases: FakeReleaseSource()..release = makeRelease(version: '1.2.0'),
        prefsValues: {
          'updates.app_last_check_ms': _t0
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        },
      );
      addTearDown(h.dispose);

      await _container(h).read(appUpdateProvider.notifier).autoCheck();
      expect(h.releases.calls, 0);

      await _container(
        h,
        now: _t0.add(const Duration(hours: 23)),
      ).read(appUpdateProvider.notifier).autoCheck();
      expect(h.releases.calls, 1);
    });

    test(
      '"Remind me later" silences that release for a week, but not a newer one',
      () async {
        final h = await TestHarness.create(
          releases: FakeReleaseSource()
            ..release = makeRelease(version: '1.2.0'),
        );
        addTearDown(h.dispose);
        final first = _container(h);
        await first.read(appUpdateProvider.notifier).checkNow();
        await first.read(appUpdateProvider.notifier).remindLater();
        expect(first.read(appUpdateProvider).announce, isFalse);

        // Two days later, the daily check finds the same release: found, but no prompt.
        final later = _container(h, now: _t0.add(const Duration(days: 2)));
        await later.read(appUpdateProvider.notifier).autoCheck();
        expect(later.read(appUpdateProvider).release?.versionName, '1.2.0');
        expect(later.read(appUpdateProvider).announce, isFalse);

        // A newer release is news.
        h.releases.release = makeRelease(version: '1.3.0');
        final newer = _container(h, now: _t0.add(const Duration(days: 3)));
        await newer.read(appUpdateProvider.notifier).autoCheck();
        expect(newer.read(appUpdateProvider).announce, isTrue);

        // After the week, the reminder is due once more.
        h.releases.release = makeRelease(version: '1.2.0');
        final week = _container(h, now: _t0.add(const Duration(days: 8)));
        await week.read(appUpdateProvider.notifier).autoCheck();
        expect(week.read(appUpdateProvider).announce, isTrue);
      },
    );

    test('a check the person asks for ignores an earlier dismissal', () async {
      final h = await TestHarness.create(
        releases: FakeReleaseSource()..release = makeRelease(version: '1.2.0'),
      );
      addTearDown(h.dispose);
      final c = _container(h);
      final app = c.read(appUpdateProvider.notifier);
      await app.checkNow();
      await app.remindLater();

      await app.checkNow();

      expect(c.read(appUpdateProvider).announce, isTrue);
    });

    test(
      'a failed automatic check stays quiet; a failed manual one says why',
      () async {
        final h = await TestHarness.create(
          releases: FakeReleaseSource()
            ..error = const AppUpdateException('network', 'offline'),
        );
        addTearDown(h.dispose);
        final c = _container(h);
        final app = c.read(appUpdateProvider.notifier);

        await app.autoCheck();
        expect(c.read(appUpdateProvider).failure, isNull);

        await app.checkNow();
        expect(c.read(appUpdateProvider).failure, AppUpdateFailure.offline);
        expect(c.read(appUpdateProvider).isBusy, isFalse);
      },
    );
  });

  group('installing an app update', () {
    final bytes = List<int>.generate(24, (i) => i * 3);
    final goodSha = crypto.sha256.convert(bytes).toString();

    Future<(TestHarness, ProviderContainer, AppUpdateController)> ready({
      String? sha,
      int activeDownloads = 0,
    }) async {
      final h = await TestHarness.create(
        releases: FakeReleaseSource()
          ..release = makeRelease(
            version: '1.2.0',
            sha256: sha ?? goodSha,
            sizeBytes: bytes.length,
          ),
        apkBytes: FakeApkByteSource(bytes),
      );
      addTearDown(h.dispose);
      final c = _container(h, activeDownloads: activeDownloads);
      final app = c.read(appUpdateProvider.notifier);
      await app.checkNow();
      return (h, c, app);
    }

    test('finding an update installs nothing: the person has to ask', () async {
      final (h, c, _) = await ready();

      expect(c.read(appUpdateProvider).release, isNotNull);
      expect(h.apkBytes.opened, 0);
      expect(h.installer.installedPaths, isEmpty);
    });

    test('a verified file is handed to Android, which then asks the person to confirm', () async {
      final (h, c, app) = await ready();

      await app.install();

      expect(h.installer.installedPaths, hasLength(1));
      expect(File(h.installer.installedPaths.single).readAsBytesSync(), bytes);
      expect(c.read(appUpdateProvider).phase, AppUpdatePhase.awaitingInstaller);
    });

    test('if the person says no on Android\'s screen, nothing is reported as wrong', () async {
      final (h, c, app) = await ready();
      await app.install();

      h.installer.report('aborted');
      await pumpEventQueue();

      final state = c.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.idle);
      expect(state.failure, isNull);
      expect(state.release, isNotNull);
    });

    test('an installer failure offers the manual route', () async {
      final (h, c, app) = await ready();
      await app.install();

      h.installer.report('failed', message: 'INSTALL_FAILED_CONFLICT');
      await pumpEventQueue();

      final state = c.read(appUpdateProvider);
      expect(state.failure, AppUpdateFailure.installerFailed);
      expect(state.offersManualInstall, isTrue);
    });

    test(
      'a download that does not match its checksum is never handed to Android',
      () async {
        final (h, c, app) = await ready(sha: 'ee' * 32);

        await app.install();

        expect(c.read(appUpdateProvider).failure, AppUpdateFailure.corrupted);
        expect(h.installer.installedPaths, isEmpty);
        expect(Directory(await h.installer.downloadDir()).listSync(), isEmpty);
      },
    );

    test('when Android needs the install permission, the person is told what to do', () async {
      final (h, c, app) = await ready();
      h.installer.startResult = const InstallStart(
        InstallStartKind.needsPermission,
      );

      await app.install();

      expect(
        c.read(appUpdateProvider).failure,
        AppUpdateFailure.needsPermission,
      );
      expect(c.read(appUpdateProvider).isBusy, isFalse);
    });

    test('a file Android would refuse (wrong signature, not newer) offers the manual route', () async {
      final (h, c, app) = await ready();
      h.installer.startResult = const InstallStart(
        InstallStartKind.rejected,
        reason: 'signature_mismatch',
      );

      await app.install();

      final state = c.read(appUpdateProvider);
      expect(state.failure, AppUpdateFailure.rejected);
      expect(state.offersManualInstall, isTrue);
    });

    test('the manual route opens the release page', () async {
      final (h, _, app) = await ready();

      await app.openReleasePage();

      expect(h.installer.openedLinks, [makeRelease(version: '1.2.0').pageUrl]);
    });

    test(
      'no update is downloaded or installed while a download is active',
      () async {
        final (h, c, app) = await ready(activeDownloads: 2);

        await app.install();

        expect(
          c.read(appUpdateProvider).failure,
          AppUpdateFailure.downloadsActive,
        );
        expect(h.apkBytes.opened, 0);
        expect(h.installer.installedPaths, isEmpty);
      },
    );

    test('cancelling the download stops it quietly', () async {
      final (h, c, app) = await ready();

      final running = app.install();
      app.cancelDownload();
      await running;

      final state = c.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.idle);
      expect(state.failure, isNull);
      expect(h.installer.installedPaths, isEmpty);
    });

    test(
      'a lost connection while downloading is reported as offline',
      () async {
        final (h, c, app) = await ready();
        h.apkBytes.error = const AppUpdateException('network', 'reset');

        await app.install();

        expect(c.read(appUpdateProvider).failure, AppUpdateFailure.offline);
        expect(h.installer.installedPaths, isEmpty);
      },
    );

    test('a release with no published checksum is not installed from inside the app', () async {
      final h = await TestHarness.create(
        releases: FakeReleaseSource()..release = makeRelease(version: '1.2.0'),
      );
      addTearDown(h.dispose);
      final c = _container(h);
      final app = c.read(appUpdateProvider.notifier);
      await app.checkNow();

      await app.install();

      expect(c.read(appUpdateProvider).failure, AppUpdateFailure.rejected);
      expect(c.read(appUpdateProvider).offersManualInstall, isTrue);
      expect(h.apkBytes.opened, 0);
      expect(h.installer.installedPaths, isEmpty);
    });

    test(
      'an unexpected error while checking never leaves the checker stuck',
      () async {
        final h = await TestHarness.create(
          releases: FakeReleaseSource()..error = StateError('odd answer'),
        );
        addTearDown(h.dispose);
        final c = _container(h);
        final app = c.read(appUpdateProvider.notifier);

        await app.checkNow();
        expect(c.read(appUpdateProvider).isBusy, isFalse);
        expect(c.read(appUpdateProvider).failure, AppUpdateFailure.unreadable);

        h.releases
          ..error = const HandshakeException('bad certificate')
          ..release = null;
        await app.checkNow();
        expect(c.read(appUpdateProvider).isBusy, isFalse);
        expect(c.read(appUpdateProvider).failure, AppUpdateFailure.offline);

        h.releases.error = null;
        await app.checkNow(); // and it still works afterwards
        expect(c.read(appUpdateProvider).upToDate, isTrue);
      },
    );

    test('an unexpected error while downloading ends the download, not the updater', () async {
      final (h, c, app) = await ready();
      h.apkBytes.error = const FileSystemException('No space left on device');

      await app.install();

      expect(c.read(appUpdateProvider).isBusy, isFalse);
      expect(c.read(appUpdateProvider).failure, AppUpdateFailure.corrupted);

      h.apkBytes.error = StateError('odd');
      await app.install();
      expect(c.read(appUpdateProvider).isBusy, isFalse);
      expect(c.read(appUpdateProvider).failure, AppUpdateFailure.unreadable);
    });
  });
}
