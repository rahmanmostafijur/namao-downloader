import 'package:flutter/services.dart';

/// A downloader update could not be done. [code]: `busy`, `network`, `verify_failed`,
/// `unavailable` or `failed`. [message] is for logs only and never shown to people.
class EngineUpdateException implements Exception {
  const EngineUpdateException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'EngineUpdateException($code, $message)';
}

/// What the phone knows about the downloader that is installed.
class EngineInfo {
  const EngineInfo({
    this.version,
    this.previousVersion,
    this.autoUpdate = true,
    this.lastCheck,
    this.lastAttempt,
    this.lastUpdate,
    this.updating = false,
    this.progress,
  });

  factory EngineInfo.fromMap(Map<Object?, Object?> map) {
    DateTime? time(Object? ms) =>
        ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
    return EngineInfo(
      version: map['version'] as String?,
      previousVersion: map['previousVersion'] as String?,
      autoUpdate: map['autoUpdate'] != false,
      lastCheck: time(map['lastCheckMs']),
      lastAttempt: time(map['lastAttemptMs']),
      lastUpdate: time(map['lastUpdateMs']),
      updating: map['updating'] == true,
      progress: (map['progress'] as num?)?.toInt(),
    );
  }

  final String? version;
  final String? previousVersion;
  final bool autoUpdate;

  /// The last time a check ended well (found nothing newer, or updated).
  final DateTime? lastCheck;

  /// The last time a check was started, successful or not.
  final DateTime? lastAttempt;
  final DateTime? lastUpdate;
  final bool updating;

  /// 0 to 100 while an update is running.
  final int? progress;

  EngineInfo withAutoUpdate(bool value) => EngineInfo(
    version: version,
    previousVersion: previousVersion,
    autoUpdate: value,
    lastCheck: lastCheck,
    lastAttempt: lastAttempt,
    lastUpdate: lastUpdate,
    updating: updating,
    progress: progress,
  );
}

/// The native downloader-update operations. Abstract so the policy above it is testable without a phone.
abstract class EngineUpdateSource {
  Future<EngineInfo> info();

  /// The newest stable version published upstream.
  Future<String> latestVersion();

  /// Installs [version] and returns the version that runs afterwards. On any failure the previous
  /// downloader stays in place and keeps working.
  Future<String> install(String version);

  Future<void> setAutoUpdate(bool enabled);

  /// Records that a check found nothing newer.
  Future<void> markChecked();
}

class MethodChannelEngineUpdateSource implements EngineUpdateSource {
  const MethodChannelEngineUpdateSource();

  static const MethodChannel _channel = MethodChannel(
    'com.namao.flutter/engine',
  );

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      final code = switch (error.code) {
        'busy' || 'network' || 'verify_failed' => error.code,
        'init_failed' => 'unavailable',
        _ => 'failed',
      };
      throw EngineUpdateException(code, error.message ?? error.code);
    } on MissingPluginException {
      throw const EngineUpdateException(
        'unavailable',
        'Engine updates are not available on this platform.',
      );
    }
  }

  @override
  Future<EngineInfo> info() async {
    final map = await _invoke<Map<Object?, Object?>>('engineInfo');
    return EngineInfo.fromMap(map ?? const {});
  }

  @override
  Future<String> latestVersion() async {
    final version = await _invoke<String>('engineLatest');
    if (version == null || version.isEmpty) {
      throw const EngineUpdateException('failed', 'no version was returned');
    }
    return version;
  }

  @override
  Future<String> install(String version) async {
    final map = await _invoke<Map<Object?, Object?>>('engineInstall', {
      'version': version,
    });
    final installed = map?['version'] as String?;
    if (installed == null) {
      throw const EngineUpdateException('failed', 'no version was returned');
    }
    return installed;
  }

  @override
  Future<void> setAutoUpdate(bool enabled) async {
    await _invoke<bool>('engineSetAuto', {'enabled': enabled});
  }

  @override
  Future<void> markChecked() async {
    await _invoke<bool>('engineMarkChecked');
  }
}
