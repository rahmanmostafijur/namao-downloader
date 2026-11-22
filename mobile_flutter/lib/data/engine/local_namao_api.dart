import 'dart:developer' as developer;
import 'dart:io';

import '../../core/api/api_exception.dart';
import '../../core/api/namao_api.dart';
import '../../core/error_messages.dart';
import '../../core/models/api_error.dart';
import '../../core/models/job.dart';
import '../../core/models/job_status.dart';
import '../../core/models/video_metadata.dart';
import '../../core/url_tools.dart';
import '../../core/uuid.dart';
import '../file_saver.dart' show safeDisplayName;
import '../session/instagram_session_store.dart';
import 'error_classifier.dart';
import 'format_builder.dart';
import 'link_resolver.dart';
import 'local_engine.dart';
import 'progress_tracker.dart';
import 'ytdlp_options.dart';

/// A yt-dlp build older than this is treated as a likely cause when a site stops working.
const int _staleEngineDays = 60;

const int _metadataCacheSize = 20;

/// What this class remembers about a download it started in this process.
class _Tracked {
  _Tracked({
    required this.tracker,
    this.title,
    this.isInstagram = false,
    this.hasSession = false,
  });

  final ProgressTracker tracker;
  final String? title;

  /// What an Instagram failure is judged against: was a session stored when this started?
  final bool isInstagram;
  final bool hasSession;

  /// The final record, kept so a finished job never depends on the native side again.
  Job? terminal;
}

/// The downloader that runs on this phone: [LocalEngine] (yt-dlp + FFmpeg) does the work and this
/// class presents it as the job records the rest of the app already understands. All decisions
/// (options, formats, progress, error wording) live here in Dart, where they are unit-tested.
class LocalNamaoApi implements NamaoApi {
  LocalNamaoApi({
    required this._engine,
    String Function()? newId,
    DateTime Function()? now,
    this._allowAnyLink = kAllowAnyLink,
    LinkResolver? resolver,
    this._sessions,
  }) : _newId = newId ?? newUuid,
       _now = now ?? DateTime.now,
       _resolver = resolver ?? LinkResolver();

  final LocalEngine _engine;
  final LinkResolver _resolver;

  /// The user's optional Instagram session; null in builds and tests without one.
  final InstagramSessionStore? _sessions;
  final String Function() _newId;
  final DateTime Function() _now;
  final bool _allowAnyLink;

  final Map<String, _Tracked> _jobs = {};
  final Map<String, String> _idByKey = {};
  final Map<String, VideoMetadata> _metadata = {};
  Future<void>? _ready;
  String? _engineVersion;

  // --------------------------------------------------------------------- engine

  @override
  Future<void> prepare() => _ready ??= _initEngine();

  Future<void> _initEngine() async {
    try {
      _engineVersion = await _engine.init();
    } on LocalEngineException catch (error) {
      _ready = null; // the next call tries again
      _log('engine init failed', error.message);
      throw _failure('environment_unsupported', retryable: true);
    }
  }

  bool get _engineIsStale {
    final match = RegExp(r'^(\d{4})\.(\d{1,2})\.(\d{1,2})')
        .firstMatch(_engineVersion ?? '');
    if (match == null) return false;
    final released = DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    return _now().difference(released).inDays > _staleEngineDays;
  }

  // ------------------------------------------------------------------- metadata

  @override
  Future<VideoMetadata> metadata(String url) async {
    await prepare();
    final target = await _resolve(url);
    final session = await _sessionFor(target);
    final output = await _readLink(target, session);
    final info = RawInfo.parse(output);
    if (info == null) {
      _log('unreadable metadata output', output);
      throw _failure('metadata_failed', retryable: true);
    }
    if (info.isLive) throw _failure('unsupported_content');
    final result = VideoMetadata(
      platform: detectPlatform(url)?.name ?? '',
      title: info.title,
      uploader: info.uploader,
      durationSeconds: info.durationSeconds,
      thumbnail: info.thumbnail,
      formats: List.unmodifiable(buildFormatOptions(info)),
    );
    _remember(url, result);
    return result;
  }

  /// Links where the stored Instagram session made a run fail but reading them without it worked.
  /// Instagram answers a session it no longer accepts with an error (HTTP 401) instead of treating
  /// the request as anonymous, so a stale session would otherwise break public posts. These links
  /// are read, and later downloaded, without the session.
  final Set<String> _withoutSession = {};

  /// The video's facts, using the stored session when there is one, and falling back to a plain
  /// anonymous read once if that fails.
  Future<String> _readLink(
    String target,
    ({bool isInstagram, bool exists, bool use}) session,
  ) async {
    final options = metadataOptions(allowAnyLink: _allowAnyLink);
    try {
      return await _engine.run(
        target,
        options,
        session: session.use ? 'instagram' : null,
      );
    } on LocalEngineException catch (error) {
      final engineDown =
          error.code == 'unavailable' || error.code == 'init_failed';
      if (!session.use || engineDown) {
        throw _fromEngineError(error, metadataPhase: true, session: session);
      }
      _log('read with session failed; retrying without it', error.message);
      try {
        final output = await _engine.run(target, options);
        _withoutSession.add(target);
        return output;
      } on LocalEngineException catch (anonymous) {
        // Without the session it fails too: that failure is the real answer (for example a story
        // that needs a login), judged knowing a session exists.
        throw _fromEngineError(
          anonymous,
          metadataPhase: true,
          session: session,
        );
      }
    }
  }

  void _remember(String url, VideoMetadata metadata) {
    _metadata.remove(url);
    _metadata[url] = metadata;
    while (_metadata.length > _metadataCacheSize) {
      _metadata.remove(_metadata.keys.first);
    }
  }

  // ------------------------------------------------------------------ downloads

  @override
  Future<Job> createDownload(
    String url,
    String quality,
    String idempotencyKey,
  ) async {
    final existing = _idByKey[idempotencyKey];
    if (existing != null) return getJob(existing);
    final parsed = Quality.tryParse(quality);
    if (parsed == null) throw _failure('invalid_quality', status: 400);
    await prepare();

    final known = _metadata[url];
    final format = _formatFor(known, quality);
    final id = _newId();
    final target = await _resolve(url);
    final session = await _sessionFor(target);
    try {
      await _engine.start(
        id,
        target,
        downloadOptions(parsed, allowAnyLink: _allowAnyLink),
        session: session.use ? 'instagram' : null,
      );
    } on LocalEngineException catch (error) {
      throw _fromEngineError(error, metadataPhase: false, session: session);
    }
    _jobs[id] = _Tracked(
      isInstagram: session.isInstagram,
      hasSession: session.exists,
      title: known?.title,
      tracker: ProgressTracker(
        // A video that carries no audio of its own is fetched as two streams, then merged. Unknown
        // (no format list was seen for this link) stays unknown rather than guessed.
        expectedStreams: parsed.kind == QualityKind.audio
            ? 1
            : (format == null ? null : (format.needsMerge ? 2 : 1)),
        estimatedTotalBytes: format?.sizeBytes,
      ),
    );
    _idByKey[idempotencyKey] = id;
    return Job(
      id: id,
      status: JobStatus.fetchingMetadata,
      platform: detectPlatform(url)?.name ?? '',
      quality: quality,
      title: known?.title,
      createdAt: _now(),
    );
  }

  FormatOption? _formatFor(VideoMetadata? metadata, String quality) {
    if (metadata == null) return null;
    for (final format in metadata.formats) {
      if (format.id == quality) return format;
    }
    return null;
  }

  @override
  Future<Job> getJob(String id) async {
    final tracked = _jobs[id];
    final cached = tracked?.terminal;
    if (cached != null) return cached;
    final EngineStatus? status;
    try {
      status = await _engine.status(id);
    } on LocalEngineException catch (error) {
      _log('status failed', error.message);
      throw _failure('environment_unsupported', retryable: true);
    }
    final job = status == null
        ? _interrupted(id)
        : _toJob(
            id,
            tracked ?? _Tracked(tracker: ProgressTracker(expectedStreams: 1)),
            status,
          );
    if (tracked != null && job.status.isTerminal) tracked.terminal = job;
    return job;
  }

  Job _interrupted(String id) => Job(
    id: id,
    status: JobStatus.interrupted,
    platform: '',
    quality: '',
    error: const ApiErrorBody(
      code: 'interrupted',
      message: '',
      retryable: true,
    ),
  );

  Job _toJob(String id, _Tracked tracked, EngineStatus status) {
    final title = status.title ?? tracked.title;
    Job job(
      JobStatus s, {
      JobProgress? progress,
      ApiErrorBody? error,
      JobResult? result,
    }) => Job(
      id: id,
      status: s,
      platform: '',
      quality: '',
      title: title,
      progress: progress ?? const JobProgress(),
      error: error,
      result: result,
    );

    switch (status.state) {
      case EngineJobState.running:
        if (status.processing) {
          return job(
            JobStatus.merging,
            progress: const JobProgress(percent: 99),
          );
        }
        if (status.streams.isEmpty) return job(JobStatus.fetchingMetadata);
        final snapshot = tracked.tracker.update(status.streams);
        return job(
          JobStatus.downloading,
          progress: JobProgress(
            percent: snapshot.percent,
            downloadedBytes: snapshot.downloadedBytes,
            totalBytes: snapshot.totalBytes,
            speedBps: status.speed,
            etaSeconds: status.eta,
          ),
        );
      case EngineJobState.completed:
        final result = _resultOf(status, title);
        if (result == null) {
          return job(
            JobStatus.failed,
            error: const ApiErrorBody(
              code: 'output_invalid',
              message: '',
              retryable: true,
            ),
          );
        }
        return job(
          JobStatus.completed,
          progress: const JobProgress(percent: 100),
          result: result,
        );
      case EngineJobState.cancelled:
        return job(JobStatus.cancelled);
      case EngineJobState.failed:
        final failure = classifyEngineError(
          status.error ?? '',
          metadataPhase: false,
          engineStale: _engineIsStale,
          isInstagram: tracked.isInstagram,
          hasSession: tracked.hasSession,
        );
        _log('download failed (${failure.code})', status.error ?? '');
        return job(
          JobStatus.failed,
          error: ApiErrorBody(
            code: failure.code,
            message: '',
            retryable: failure.retryable,
          ),
        );
    }
  }

  JobResult? _resultOf(EngineStatus status, String? title) {
    final path = status.path;
    final size = status.size;
    if (path == null || size == null || size <= 0) return null;
    final dot = path.lastIndexOf('.');
    final extension = dot < 0 ? '' : path.substring(dot);
    return JobResult(
      filename: '${safeDisplayName(title ?? 'video')}$extension',
      sizeBytes: size,
      downloadUrl: 'device',
      durationSeconds: status.duration,
    );
  }

  @override
  Future<Job> cancel(String id) async {
    final current = await getJob(id);
    if (current.status.isTerminal) {
      throw _failure('conflict', status: 409);
    }
    try {
      await _engine.cancel(id);
    } on LocalEngineException catch (error) {
      _log('cancel failed', error.message);
      throw _failure('environment_unsupported', retryable: true);
    }
    final cancelled = Job(
      id: id,
      status: JobStatus.cancelled,
      platform: current.platform,
      quality: current.quality,
      title: current.title,
    );
    _jobs[id]?.terminal = cancelled;
    return cancelled;
  }

  // ---------------------------------------------------------------------- files

  @override
  Future<File> finishedFile(String id) async {
    final EngineStatus? status;
    try {
      status = await _engine.status(id);
    } on LocalEngineException catch (error) {
      _log('file lookup failed', error.message);
      throw _failure('environment_unsupported', retryable: true);
    }
    final path = status?.path;
    if (status?.state != EngineJobState.completed || path == null) {
      throw _failure('expired', status: 404);
    }
    final file = File(path);
    if (!await file.exists()) throw _failure('expired', status: 404);
    return file;
  }

  @override
  Future<void> release(String id) async {
    try {
      await _engine.release(id);
    } on LocalEngineException catch (error) {
      _log(
        'release failed',
        error.message,
      ); // leftovers are removed by cleanup() next launch
    }
  }

  @override
  Future<void> cleanup(Set<String> keep) async {
    try {
      await _engine.cleanup(keep);
    } on LocalEngineException catch (error) {
      _log('cleanup failed', error.message);
    }
  }

  // --------------------------------------------------------------------- errors

  /// fb.watch and share links lead to the real video through redirects; everything else is
  /// returned as it is. A link that cannot be followed fails here with its own reason, never as
  /// an "unsupported link".
  Future<String> _resolve(String url) async {
    try {
      return await _resolver.resolve(url);
    } on LinkResolveException catch (error) {
      _log('link not resolved (${error.code})', url);
      throw _failure(error.code, retryable: error.code == 'network_transient');
    }
  }

  ApiException _failure(String code, {bool retryable = false, int? status}) =>
      ApiException(
        code: code,
        message: messageForCode(code),
        retryable: retryable,
        status: status,
      );

  /// Whether this is an Instagram link, whether the user has a stored session, and whether it is
  /// still usable (a session past its own expiry date is not sent; the failure then says so).
  Future<({bool isInstagram, bool exists, bool use})> _sessionFor(
    String url,
  ) async {
    if (detectPlatform(url) != SourcePlatform.instagram) {
      return (isInstagram: false, exists: false, use: false);
    }
    SessionInfo? info;
    try {
      info = await _sessions?.info();
    } on Object {
      info = null; // storage trouble must never block a public link
    }
    return (
      isInstagram: true,
      exists: info != null,
      use:
          info != null &&
          !info.isExpired(_now()) &&
          !_withoutSession.contains(url),
    );
  }

  ApiException _fromEngineError(
    LocalEngineException error, {
    required bool metadataPhase,
    ({bool isInstagram, bool exists, bool use})? session,
  }) {
    if (error.code == 'unavailable' || error.code == 'init_failed') {
      _log('engine unavailable', error.message);
      return _failure('environment_unsupported', retryable: true);
    }
    final failure = classifyEngineError(
      error.message,
      metadataPhase: metadataPhase,
      engineStale: _engineIsStale,
      isInstagram: session?.isInstagram ?? false,
      hasSession: session?.exists ?? false,
    );
    _log('engine error (${failure.code})', error.message);
    return _failure(failure.code, retryable: failure.retryable);
  }

  /// Technical detail for debugging only; it is never shown on screen.
  void _log(String what, String detail) =>
      developer.log('$what: $detail', name: 'namao.engine');
}
