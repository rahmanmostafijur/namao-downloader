import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/updates/apk_downloader.dart';
import '../../data/updates/apk_installer.dart';
import '../../data/updates/app_release.dart';
import '../../data/updates/distribution.dart';
import '../../data/updates/https_get.dart';
import '../../data/updates/update_providers.dart';
import '../../data/updates/versions.dart';
import '../downloads/downloads_state.dart';

enum AppUpdatePhase { idle, checking, downloading, awaitingInstaller }

/// Why an app update did not go ahead; the wording is in `update_messages.dart`.
enum AppUpdateFailure {
  offline,
  unreadable,
  downloadsActive,
  corrupted,
  needsPermission,
  rejected,
  installerFailed,
}

const Object _keep = Object();

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.release,
    this.progress,
    this.upToDate = false,
    this.failure,
    this.announce = false,
  });

  final AppUpdatePhase phase;

  /// A newer release, once one has been found.
  final AppRelease? release;

  /// 0 to 1 while the file is downloading; null when the size is not known.
  final double? progress;

  /// The last check found nothing newer.
  final bool upToDate;
  final AppUpdateFailure? failure;

  /// The prompt should be shown now (an automatic check found something not snoozed).
  final bool announce;

  bool get isBusy => phase != AppUpdatePhase.idle;

  /// Where installing inside the app cannot work and the person must do it by hand.
  bool get offersManualInstall =>
      failure == AppUpdateFailure.rejected ||
      failure == AppUpdateFailure.installerFailed;

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    Object? release = _keep,
    Object? progress = _keep,
    bool? upToDate,
    Object? failure = _keep,
    bool? announce,
  }) => AppUpdateState(
    phase: phase ?? this.phase,
    release: identical(release, _keep) ? this.release : release as AppRelease?,
    progress: identical(progress, _keep) ? this.progress : progress as double?,
    upToDate: upToDate ?? this.upToDate,
    failure: identical(failure, _keep)
        ? this.failure
        : failure as AppUpdateFailure?,
    announce: announce ?? this.announce,
  );
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(
  AppUpdateController.new,
);

/// Finds a newer Namao release and, when asked, downloads it, verifies it and hands it to
/// Android's installer. Installing always needs the person's confirmation on Android's own screen.
class AppUpdateController extends Notifier<AppUpdateState> {
  /// An automatic check happens at most this often.
  static const Duration checkEvery = Duration(hours: 24);

  /// "Remind me later" stays quiet this long (and never for a newer release).
  static const Duration remindAfter = Duration(days: 7);

  bool _cancelRequested = false;

  /// The prompt is on screen. Kept here, not in a global, so each app instance has its own.
  bool promptOpen = false;

  @override
  AppUpdateState build() {
    final results = ref.read(apkInstallerProvider).results.listen(_onResult);
    ref.onDispose(results.cancel);
    return const AppUpdateState();
  }

  DateTime _now() => ref.read(clockProvider)();

  Future<InstalledApp?> _installed() async {
    try {
      return parseInstalledApp(
        await ref.read(nativeMediaProvider).appVersion(),
      );
    } on Object {
      return null;
    }
  }

  // ------------------------------------------------------------------------- checking

  /// The launch-time check: at most once a day.
  Future<void> autoCheck() async {
    if (!kUpdatesEnabled || state.isBusy) return;
    final last = ref.read(updateStoreProvider).lastAppCheck;
    if (last != null && _now().difference(last) < checkEvery) return;
    await _check(manual: false);
  }

  Future<void> checkNow() => _check(manual: true);

  Future<void> _check({required bool manual}) async {
    if (state.isBusy) return;
    state = state.copyWith(phase: AppUpdatePhase.checking, failure: null);
    try {
      final release = await ref.read(appReleaseSourceProvider).latest();
      await ref.read(updateStoreProvider).recordAppCheck(_now());
      final installed = await _installed();
      if (!ref.mounted) return;
      final isNewer =
          release != null &&
          installed != null &&
          isNewerAppVersion(release.versionName, installed.name);
      if (!isNewer) {
        state = const AppUpdateState(upToDate: true);
        return;
      }
      final snoozed = ref
          .read(updateStoreProvider)
          .isSnoozed(release.versionName, _now());
      state = AppUpdateState(release: release, announce: manual || !snoozed);
    } on Object catch (error) {
      // Any failure (no route, a TLS or captive-portal error, an unexpected answer) must end the
      // check: a phase left at "checking" would disable every later check until a restart.
      developer.log('app update check: $error', name: 'namao.update');
      if (!ref.mounted) return;
      // An automatic check that fails stays quiet; one the person asked for says why.
      final offline =
          error is IOException ||
          (error is AppUpdateException && error.code == 'network');
      state = state.copyWith(
        phase: AppUpdatePhase.idle,
        failure: manual
            ? (offline ? AppUpdateFailure.offline : AppUpdateFailure.unreadable)
            : null,
      );
    }
  }

  // ------------------------------------------------------------------------- prompt

  /// The prompt is on screen; do not open it again for the same finding.
  void markAnnounced() => state = state.copyWith(announce: false);

  Future<void> remindLater() async {
    final release = state.release;
    state = state.copyWith(announce: false);
    if (release == null) return;
    await ref
        .read(updateStoreProvider)
        .snooze(release.versionName, _now().add(remindAfter));
  }

  // ------------------------------------------------------------------------ installing

  void cancelDownload() => _cancelRequested = true;

  /// The person closed the "confirm on the next screen" step.
  void acknowledgeInstaller() {
    if (state.phase == AppUpdatePhase.awaitingInstaller) {
      state = state.copyWith(phase: AppUpdatePhase.idle);
    }
  }

  void _onResult(InstallResult result) {
    if (state.phase != AppUpdatePhase.awaitingInstaller) return;
    switch (result.status) {
      case 'aborted': // the person said no on Android's screen: nothing went wrong
        state = state.copyWith(phase: AppUpdatePhase.idle);
      case 'failed':
        developer.log(
          'install failed: ${result.message}',
          name: 'namao.update',
        );
        state = state.copyWith(
          phase: AppUpdatePhase.idle,
          failure: AppUpdateFailure.installerFailed,
        );
      default: // success: Android restarts the app on the new version
        break;
    }
  }

  bool get _downloadsActive => ref.read(tabCountsProvider).active > 0;

  Future<void> install() async {
    final release = state.release;
    if (release == null || state.isBusy) return;
    if (_downloadsActive) {
      state = state.copyWith(failure: AppUpdateFailure.downloadsActive);
      return;
    }
    if (release.sha256 == null) {
      // Without a published checksum the download cannot be verified: do not install it from
      // here; the release page is the way.
      state = state.copyWith(failure: AppUpdateFailure.rejected);
      return;
    }
    final installer = ref.read(apkInstallerProvider);
    _cancelRequested = false;
    state = state.copyWith(
      phase: AppUpdatePhase.downloading,
      progress: 0.0,
      failure: null,
      announce: false,
    );
    try {
      final dir = Directory(await installer.downloadDir());
      final file = await ApkDownloader(ref.read(apkByteSourceProvider))
          .download(
            release,
            dir,
            onProgress: (fraction) {
              if (ref.mounted) state = state.copyWith(progress: fraction);
            },
            isCancelled: () => _cancelRequested,
          );
      if (!ref.mounted) return;
      // The file took a while to arrive; installing restarts the app, so check again.
      if (_downloadsActive) {
        _finish(AppUpdateFailure.downloadsActive);
        return;
      }
      final start = await installer.install(file.path);
      if (!ref.mounted) return;
      switch (start.kind) {
        case InstallStartKind.started:
          state = state.copyWith(
            phase: AppUpdatePhase.awaitingInstaller,
            progress: null,
          );
        case InstallStartKind.needsPermission:
          _finish(AppUpdateFailure.needsPermission);
        case InstallStartKind.rejected:
          developer.log(
            'install rejected: ${start.reason}',
            name: 'namao.update',
          );
          _finish(AppUpdateFailure.rejected);
      }
    } on ApkDownloadCancelled {
      if (ref.mounted) _finish(null);
    } on ApkVerificationException catch (error) {
      developer.log('update file rejected: $error', name: 'namao.update');
      if (ref.mounted) _finish(AppUpdateFailure.corrupted);
    } on AppUpdateException catch (error) {
      developer.log('update download: $error', name: 'namao.update');
      if (ref.mounted) {
        _finish(
          error.code == 'network'
              ? AppUpdateFailure.offline
              : AppUpdateFailure.unreadable,
        );
      }
    } on PlatformException catch (error) {
      developer.log('installer: $error', name: 'namao.update');
      if (ref.mounted) _finish(AppUpdateFailure.installerFailed);
    } on FileSystemException catch (error) {
      developer.log('update file: $error', name: 'namao.update');
      // Most often a full disk.
      if (ref.mounted) _finish(AppUpdateFailure.corrupted);
    } on IOException catch (error) {
      developer.log('update download: $error', name: 'namao.update');
      if (ref.mounted) _finish(AppUpdateFailure.offline);
    } on Object catch (error) {
      developer.log('update failed: $error', name: 'namao.update');
      if (ref.mounted) _finish(AppUpdateFailure.unreadable);
    }
  }

  void _finish(AppUpdateFailure? failure) => state = state.copyWith(
    phase: AppUpdatePhase.idle,
    progress: null,
    failure: failure,
  );

  /// The way out when installing here cannot work: the release page, to download and tap the file.
  Future<void> openReleasePage() async {
    final release = state.release;
    if (release == null) return;
    try {
      await ref.read(apkInstallerProvider).openLink(release.pageUrl);
    } on Object catch (error) {
      developer.log(
        'could not open the release page: $error',
        name: 'namao.update',
      );
    }
  }
}
