import 'dart:async';
import 'dart:io';

import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/api/namao_api.dart';
import 'package:namao_app/core/models/api_error.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/core/models/video_metadata.dart';
import 'package:namao_app/data/native_media.dart';

Job makeJob({
  String id = 'job1',
  JobStatus status = JobStatus.queued,
  String platform = 'youtube',
  String quality = '1080',
  String? title,
  JobProgress progress = const JobProgress(),
  int attempt = 0,
  int maxAttempts = 3,
  ApiErrorBody? error,
  JobResult? result,
  DateTime? updatedAt,
}) => Job(
  id: id,
  status: status,
  platform: platform,
  quality: quality,
  title: title,
  progress: progress,
  attempt: attempt,
  maxAttempts: maxAttempts,
  error: error,
  result: result,
  updatedAt: updatedAt,
);

JobResult makeResult({
  String filename = 'Video.mp4',
  int sizeBytes = 10,
}) => JobResult(
  filename: filename,
  sizeBytes: sizeBytes,
  downloadUrl: 'device',
);

const ApiException notFound = ApiException(
  code: 'not_found',
  message: 'Not found.',
  status: 404,
);

const VideoMetadata sampleMetadata = VideoMetadata(
  platform: 'youtube',
  title: 'Sample video title',
  uploader: 'Some Channel',
  durationSeconds: 125,
  formats: [
    FormatOption(
      id: 'best',
      label: 'Best available',
      kind: FormatKind.video,
      note: 'Highest quality',
      sizeBytes: 50 * 1024 * 1024,
      sizeEstimated: true,
    ),
    FormatOption(
      id: '1080',
      label: '1080p',
      kind: FormatKind.video,
      height: 1080,
      note: 'MP4',
      sizeBytes: 30 * 1024 * 1024,
      needsMerge: true,
    ),
    FormatOption(id: '720', label: '720p', kind: FormatKind.video, height: 720),
    FormatOption(
      id: 'audio',
      label: 'Audio only',
      kind: FormatKind.audio,
      note: 'M4A',
      sizeBytes: 4 * 1024 * 1024,
    ),
  ],
);

/// A scriptable downloader. Each call is recorded in [calls].
class FakeApi implements NamaoApi {
  final List<String> calls = [];
  final List<String> idempotencyKeys = [];
  VideoMetadata? metadataResult = sampleMetadata;
  Object? metadataError;
  Completer<VideoMetadata>? metadataGate;
  Object? prepareError;

  /// Job returned by `createDownload`; a fresh id per call unless [fixedCreateId] is set.
  Object createResult = 'auto';
  String? fixedCreateId;
  int _createCounter = 0;

  /// Scripted `getJob` responses per id. The last one repeats. Entries are [Job] or [ApiException].
  final Map<String, List<Object>> jobScripts = {};
  Object? cancelResult;

  /// Finished files by job id; each is written to disk when asked for.
  final Map<String, List<int>> files = {};
  Object? fileError;
  Set<String>? lastCleanupKeep;

  /// When true, getJob never answers (keeps widget tests free of poll timers).
  bool hangJobs = false;

  final Directory _dir = Directory.systemTemp.createTempSync('namao_fake_api');

  void script(String id, List<Object> responses) =>
      jobScripts[id] = List.of(responses);

  /// Whether a working file for [id] is currently on disk.
  bool hasWorkingFile(String id) => File('${_dir.path}/$id.bin').existsSync();

  void dispose() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }

  @override
  Future<void> prepare() async {
    calls.add('prepare');
    final error = prepareError;
    if (error != null) throw error;
  }

  @override
  Future<VideoMetadata> metadata(String url) async {
    calls.add('metadata $url');
    if (metadataGate != null) return metadataGate!.future;
    final error = metadataError;
    if (error != null) throw error;
    return metadataResult!;
  }

  @override
  Future<Job> createDownload(
    String url,
    String quality,
    String idempotencyKey,
  ) async {
    calls.add('create $url $quality');
    idempotencyKeys.add(idempotencyKey);
    final result = createResult;
    if (result is Exception || result is Error) throw result;
    if (result is Job) return result;
    _createCounter++;
    return makeJob(
      id: fixedCreateId ?? 'job$_createCounter',
      quality: quality,
      status: JobStatus.queued,
    );
  }

  @override
  Future<Job> getJob(String id) async {
    calls.add('get $id');
    if (hangJobs) return Completer<Job>().future;
    final script = jobScripts[id];
    if (script == null || script.isEmpty) throw notFound;
    final next = script.length > 1 ? script.removeAt(0) : script.first;
    if (next is Exception) throw next;
    return next as Job;
  }

  @override
  Future<Job> cancel(String id) async {
    calls.add('cancel $id');
    final result = cancelResult;
    if (result is Exception) throw result;
    return (result as Job?) ?? makeJob(id: id, status: JobStatus.cancelled);
  }

  @override
  Future<File> finishedFile(String id) async {
    calls.add('file $id');
    final error = fileError;
    if (error != null) throw error;
    final bytes = files[id];
    if (bytes == null) throw notFound;
    final file = File('${_dir.path}/$id.bin');
    await file.writeAsBytes(bytes);
    return file;
  }

  @override
  Future<void> release(String id) async {
    calls.add('release $id');
    final file = File('${_dir.path}/$id.bin');
    if (file.existsSync()) file.deleteSync();
  }

  @override
  Future<void> cleanup(Set<String> keep) async {
    calls.add('cleanup');
    lastCleanupKeep = keep;
  }
}

class FakeNativeMedia implements NativeMedia {
  final List<String> events = [];
  final Map<String, bool> existing = {};
  NativeMediaException? saveError;
  NativeMediaException? openError;
  int savedCounter = 0;
  String? lastTempPath;
  bool tempExistedAtSave = false;
  bool notificationsGranted = true;

  /// Makes saveToDownloads fail with an error that is not a NativeMediaException.
  bool saveUnexpected = false;

  @override
  Future<SavedMedia> saveToDownloads({
    required String tempPath,
    required String displayName,
    required String mimeType,
    required int expectedBytes,
  }) async {
    events.add('save $displayName $mimeType $expectedBytes');
    lastTempPath = tempPath;
    tempExistedAtSave = File(tempPath).existsSync();
    if (saveUnexpected) throw StateError('unexpected');
    final error = saveError;
    if (error != null) throw error;
    savedCounter++;
    final uri = 'content://media/downloads/$savedCounter';
    existing[uri] = true;
    return SavedMedia(
      uri: uri,
      displayName: displayName,
      sizeBytes: expectedBytes,
    );
  }

  @override
  Future<bool> exists(String uri) async => existing[uri] ?? false;

  @override
  Future<void> open(String uri, String mimeType) async {
    events.add('open $uri $mimeType');
    final error = openError;
    if (error != null) throw error;
  }

  @override
  Future<void> share(String uri, String mimeType, String title) async {
    events.add('share $uri $mimeType');
  }

  @override
  Future<void> startTransfer(String text) async => events.add('startTransfer');

  @override
  Future<void> updateTransfer(int percent, String text) async {}

  @override
  Future<void> stopTransfer() async => events.add('stopTransfer');

  @override
  Future<bool> requestNotificationPermission() async => notificationsGranted;

  @override
  Future<String> appVersion() async => '1.0.0 (1)';
}
