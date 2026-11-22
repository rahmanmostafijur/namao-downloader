import 'package:flutter/services.dart';

import 'progress_tracker.dart';

/// The native runner could not do what was asked. [message] is the tool's own text, kept for
/// classification and logs, and never shown to people.
class LocalEngineException implements Exception {
  const LocalEngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'LocalEngineException($code, $message)';
}

enum EngineJobState { running, completed, failed, cancelled }

/// The native runner's raw view of one job; Dart turns it into the job the screens show.
class EngineStatus {
  const EngineStatus({
    required this.state,
    this.processing = false,
    this.streams = const [],
    this.speed,
    this.eta,
    this.error,
    this.title,
    this.duration,
    this.path,
    this.size,
  });

  factory EngineStatus.fromMap(Map<Object?, Object?> map) {
    final state = EngineJobState.values.firstWhere(
      (s) => s.name == map['state'],
      orElse: () => EngineJobState.failed,
    );
    final rawStreams = map['streams'];
    return EngineStatus(
      state: state,
      processing: map['processing'] == true,
      streams: [
        if (rawStreams is List)
          for (final s in rawStreams)
            if (s is Map) StreamProgress.fromMap(s),
      ],
      speed: (map['speed'] as num?)?.toDouble(),
      eta: (map['eta'] as num?)?.toInt(),
      error: map['error'] as String?,
      title: map['title'] as String?,
      duration: (map['duration'] as num?)?.toDouble(),
      path: map['path'] as String?,
      size: (map['size'] as num?)?.toInt(),
    );
  }

  final EngineJobState state;

  /// Merging or converting has started: the transfer itself is over.
  final bool processing;
  final List<StreamProgress> streams;
  final double? speed;
  final int? eta;

  /// The tool's error output when [state] is failed.
  final String? error;
  final String? title;
  final double? duration;
  final String? path;
  final int? size;
}

/// The on-device downloader (yt-dlp + FFmpeg bundled in the app), behind a small channel.
/// Abstract so everything above it is testable without a phone.
abstract class LocalEngine {
  /// Unpacks the runtime on first launch and keeps yt-dlp current. Returns yt-dlp's version.
  Future<String> init();

  /// Runs the tool once and returns what it printed. [session] is `instagram` when the user's own
  /// stored Instagram session should be used (the native side attaches it for Instagram links
  /// only); the cookies themselves never pass through Dart again.
  Future<String> run(String url, List<String> options, {String? session});

  Future<void> start(
    String jobId,
    String url,
    List<String> options, {
    String? session,
  });

  /// Null when the native side has no record of the job.
  Future<EngineStatus?> status(String jobId);

  Future<void> cancel(String jobId);

  /// Deletes the job's working files.
  Future<void> release(String jobId);

  /// Deletes the working files of every job not in [keep].
  Future<void> cleanup(Set<String> keep);
}

class MethodChannelLocalEngine implements LocalEngine {
  const MethodChannelLocalEngine();

  static const MethodChannel _channel = MethodChannel(
    'com.namao.flutter/engine',
  );

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      throw LocalEngineException(error.code, error.message ?? error.code);
    } on MissingPluginException {
      throw const LocalEngineException(
        'unavailable',
        'The on-device engine is not available on this platform.',
      );
    }
  }

  @override
  Future<String> init() async {
    final result = await _invoke<Map<Object?, Object?>>('init');
    return (result?['version'] as String?) ?? 'unknown';
  }

  @override
  Future<String> run(
    String url,
    List<String> options, {
    String? session,
  }) async =>
      await _invoke<String>('run', {
        'url': url,
        'args': options,
        'session': session,
      }) ??
      '';

  @override
  Future<void> start(
    String jobId,
    String url,
    List<String> options, {
    String? session,
  }) async {
    await _invoke<bool>('start', {
      'jobId': jobId,
      'url': url,
      'args': options,
      'session': session,
    });
  }

  @override
  Future<EngineStatus?> status(String jobId) async {
    final map = await _invoke<Map<Object?, Object?>>('status', {
      'jobId': jobId,
    });
    return map == null ? null : EngineStatus.fromMap(map);
  }

  @override
  Future<void> cancel(String jobId) async {
    await _invoke<bool>('cancel', {'jobId': jobId});
  }

  @override
  Future<void> release(String jobId) async {
    await _invoke<bool>('release', {'jobId': jobId});
  }

  @override
  Future<void> cleanup(Set<String> keep) async {
    await _invoke<bool>('cleanup', {'keep': keep.toList()});
  }
}
