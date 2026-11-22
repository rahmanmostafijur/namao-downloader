import 'dart:developer' as developer;

import 'engine_update_source.dart';
import 'versions.dart';

enum EngineUpdateKind { updated, upToDate, busy, offline, failed, unavailable }

class EngineUpdateOutcome {
  const EngineUpdateOutcome(this.kind, {this.version, this.previousVersion});

  final EngineUpdateKind kind;

  /// The version that is installed after the attempt.
  final String? version;
  final String? previousVersion;
}

/// The decisions about the downloader update: when to look, whether what was found is newer, and
/// what a failure means. The mechanics (download, checksum, swap, rollback, never during a
/// download) are native; see `EngineUpdates.kt`.
class EngineUpdater {
  EngineUpdater(this._source);

  final EngineUpdateSource _source;

  /// Automatic checks happen at most this often after one that ended well…
  static const Duration checkEvery = Duration(hours: 24);

  /// …and at most this often after a failed one, so an offline phone does not retry on every launch.
  static const Duration retryAfterFailure = Duration(hours: 3);

  static bool isAutoCheckDue(EngineInfo info, DateTime now) {
    if (!info.autoUpdate) return false;
    final checked = info.lastCheck;
    if (checked != null && now.difference(checked) < checkEvery) return false;
    final attempted = info.lastAttempt;
    if (attempted != null && now.difference(attempted) < retryAfterFailure) {
      return false;
    }
    return true;
  }

  /// Looks for a newer stable version and installs it. Never throws: every way it can go wrong is an outcome.
  Future<EngineUpdateOutcome> update() async {
    try {
      final info = await _source.info();
      if (info.updating) {
        return const EngineUpdateOutcome(EngineUpdateKind.busy);
      }
      final latest = await _source.latestVersion();
      if (!isNewerEngineVersion(latest, info.version)) {
        await _source.markChecked();
        return EngineUpdateOutcome(
          EngineUpdateKind.upToDate,
          version: info.version,
        );
      }
      final installed = await _source.install(latest);
      return EngineUpdateOutcome(
        EngineUpdateKind.updated,
        version: installed,
        previousVersion: info.version,
      );
    } on EngineUpdateException catch (error) {
      developer.log('engine update: $error', name: 'namao.update');
      return EngineUpdateOutcome(switch (error.code) {
        'busy' => EngineUpdateKind.busy,
        'network' => EngineUpdateKind.offline,
        'unavailable' => EngineUpdateKind.unavailable,
        _ => EngineUpdateKind.failed,
      });
    }
  }
}
