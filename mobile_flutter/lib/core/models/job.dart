import 'api_error.dart';
import 'job_status.dart';
import 'json_read.dart';

class JobProgress {
  const JobProgress({
    this.percent = 0,
    this.downloadedBytes,
    this.totalBytes,
    this.speedBps,
    this.etaSeconds,
  });

  factory JobProgress.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const JobProgress();
    return JobProgress(
      percent: (readDouble(json['percent']) ?? 0).clamp(0, 100).toDouble(),
      downloadedBytes: readInt(json['downloaded_bytes']),
      totalBytes: readInt(json['total_bytes']),
      speedBps: readDouble(json['speed_bps']),
      etaSeconds: readInt(json['eta_seconds']),
    );
  }

  final double percent;
  final int? downloadedBytes;
  final int? totalBytes;
  final double? speedBps;
  final int? etaSeconds;

  Map<String, dynamic> toJson() => {
    'percent': percent,
    'downloaded_bytes': downloadedBytes,
    'total_bytes': totalBytes,
    'speed_bps': speedBps,
    'eta_seconds': etaSeconds,
  };

  @override
  bool operator ==(Object other) =>
      other is JobProgress &&
      other.percent == percent &&
      other.downloadedBytes == downloadedBytes &&
      other.totalBytes == totalBytes &&
      other.speedBps == speedBps &&
      other.etaSeconds == etaSeconds;

  @override
  int get hashCode =>
      Object.hash(percent, downloadedBytes, totalBytes, speedBps, etaSeconds);
}

class JobResult {
  const JobResult({
    required this.filename,
    required this.sizeBytes,
    required this.downloadUrl,
    this.height,
    this.durationSeconds,
  });

  /// Null when a required field is missing: a result without a size can't be verified.
  static JobResult? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final filename = readString(json['filename']);
    final size = readInt(json['size_bytes']);
    final url = readString(json['download_url']);
    if (filename == null || size == null || url == null) return null;
    return JobResult(
      filename: filename,
      sizeBytes: size,
      downloadUrl: url,
      height: readInt(json['height']),
      durationSeconds: readDouble(json['duration_seconds']),
    );
  }

  final String filename;
  final int sizeBytes;
  final String downloadUrl;
  final int? height;
  final double? durationSeconds;

  Map<String, dynamic> toJson() => {
    'filename': filename,
    'size_bytes': sizeBytes,
    'download_url': downloadUrl,
    'height': height,
    'duration_seconds': durationSeconds,
  };

  @override
  bool operator ==(Object other) =>
      other is JobResult &&
      other.filename == filename &&
      other.sizeBytes == sizeBytes &&
      other.downloadUrl == downloadUrl &&
      other.height == height &&
      other.durationSeconds == durationSeconds;

  @override
  int get hashCode =>
      Object.hash(filename, sizeBytes, downloadUrl, height, durationSeconds);
}

/// The server's job record. Every number the UI shows about a job comes from here.
class Job {
  const Job({
    required this.id,
    required this.status,
    required this.platform,
    required this.quality,
    this.title,
    this.progress = const JobProgress(),
    this.attempt = 0,
    this.maxAttempts = 1,
    this.retryAt,
    this.error,
    this.result,
    this.createdAt,
    this.updatedAt,
    this.expiresAt,
  });

  /// Returns null when the payload lacks an id or carries an unknown status.
  static Job? fromJson(Map<String, dynamic> json) {
    final id = readString(json['id']);
    final status = JobStatus.tryParse(json['status']);
    if (id == null || status == null) return null;
    final error = readMap(json['error']);
    return Job(
      id: id,
      status: status,
      platform: readString(json['platform']) ?? '',
      quality: readString(json['quality']) ?? '',
      title: readString(json['title']),
      progress: JobProgress.fromJson(readMap(json['progress'])),
      attempt: readInt(json['attempt']) ?? 0,
      maxAttempts: readInt(json['max_attempts']) ?? 1,
      retryAt: readDate(json['retry_at']),
      error: error == null ? null : ApiErrorBody.fromJson(error),
      result: JobResult.fromJson(readMap(json['result'])),
      createdAt: readDate(json['created_at']),
      updatedAt: readDate(json['updated_at']),
      expiresAt: readDate(json['expires_at']),
    );
  }

  final String id;
  final JobStatus status;
  final String platform;
  final String quality;
  final String? title;
  final JobProgress progress;
  final int attempt;
  final int maxAttempts;
  final DateTime? retryAt;
  final ApiErrorBody? error;
  final JobResult? result;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? expiresAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'status': status.wire,
    'platform': platform,
    'quality': quality,
    'title': title,
    'progress': progress.toJson(),
    'attempt': attempt,
    'max_attempts': maxAttempts,
    'retry_at': retryAt?.toIso8601String(),
    'error': error?.toJson(),
    'result': result?.toJson(),
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
    'expires_at': expiresAt?.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is Job &&
      other.id == id &&
      other.status == status &&
      other.platform == platform &&
      other.quality == quality &&
      other.title == title &&
      other.progress == progress &&
      other.attempt == attempt &&
      other.maxAttempts == maxAttempts &&
      other.retryAt == retryAt &&
      other.error == error &&
      other.result == result &&
      other.updatedAt == updatedAt &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
    id,
    status,
    platform,
    quality,
    title,
    progress,
    attempt,
    maxAttempts,
    retryAt,
    error,
    result,
    updatedAt,
    expiresAt,
  );
}
