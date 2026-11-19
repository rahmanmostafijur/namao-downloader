import '../core/models/api_error.dart';
import '../core/models/job.dart';
import '../core/models/job_status.dart';
import '../core/models/json_read.dart';

/// State of getting the finished file onto this phone.
enum SaveState {
  /// Not started (job not finished, or about to start).
  none,

  /// Streaming from the server / writing to MediaStore right now.
  transferring,

  /// In `Download/Namao`. The local file is now the artifact.
  saved,

  /// The device transfer failed or was interrupted. "Retry save" is offered.
  failed,
}

/// Which list an entry belongs to.
enum DownloadsTab { active, completed, failed }

/// One client-side history record: the job the server knows about plus what happened on the
/// phone. There is deliberately no list-jobs endpoint, so this is the only index of jobs.
class HistoryEntry {
  const HistoryEntry({
    required this.jobId,
    required this.sourceUrl,
    required this.title,
    required this.qualityId,
    required this.qualityLabel,
    required this.platform,
    required this.createdAt,
    this.thumbnail,
    this.job,
    this.serverGone = false,
    this.saveState = SaveState.none,
    this.savedUri,
    this.savedName,
    this.savedBytes,
    this.saveError,
    this.serverUrl,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final jobJson = readMap(json['job']);
    final stateName = readString(json['save_state']);
    return HistoryEntry(
      jobId: readString(json['job_id']) ?? '',
      sourceUrl: readString(json['source_url']) ?? '',
      title: readString(json['title']) ?? '',
      qualityId: readString(json['quality_id']) ?? '',
      qualityLabel: readString(json['quality_label']) ?? '',
      platform: readString(json['platform']) ?? '',
      createdAt:
          readDate(json['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      thumbnail: readString(json['thumbnail']),
      job: jobJson == null ? null : Job.fromJson(jobJson),
      serverGone: json['server_gone'] == true,
      saveState: SaveState.values.firstWhere(
        (s) => s.name == stateName,
        orElse: () => SaveState.none,
      ),
      savedUri: readString(json['saved_uri']),
      savedName: readString(json['saved_name']),
      savedBytes: readInt(json['saved_bytes']),
      saveError: readString(json['save_error']),
      serverUrl: readString(json['server_url']),
    );
  }

  final String jobId;
  final String sourceUrl;
  final String title;
  final String? thumbnail;
  final String qualityId;
  final String qualityLabel;
  final String platform;
  final DateTime createdAt;

  /// Last job record received from the server.
  final Job? job;

  /// The server answered 404/410 for this job before the file was saved (expired or reset).
  final bool serverGone;

  final SaveState saveState;
  final String? savedUri;
  final String? savedName;
  final int? savedBytes;
  final String? saveError;

  /// The server that owns this job. Job ids are capability tokens of ONE server, so an entry is
  /// only tracked while that server is configured. Null for records written before this field.
  final String? serverUrl;

  bool isForServer(String? current) =>
      serverUrl == null || serverUrl == current;

  JobStatus? get status => job?.status;
  bool get isSaved => saveState == SaveState.saved && savedUri != null;

  /// Failed, cancelled or interrupted on the server (not "expired").
  bool get isFailedOnServer => switch (status) {
    JobStatus.failed || JobStatus.cancelled || JobStatus.interrupted => true,
    _ => false,
  };

  /// True while the server is working or the file is on its way to the phone.
  bool get isActive {
    if (isSaved) return false;
    if (serverGone) return false;
    final s = status;
    if (s == null) return true;
    if (!s.isTerminal) return true;
    return s == JobStatus.completed &&
        (saveState == SaveState.none || saveState == SaveState.transferring);
  }

  DownloadsTab get tab {
    if (isSaved) return DownloadsTab.completed;
    if (serverGone || isFailedOnServer) return DownloadsTab.failed;
    if (isActive) return DownloadsTab.active;
    return DownloadsTab
        .completed; // completed on the server, device save failed
  }

  /// A job that finished on the server and whose file this app has not saved yet.
  bool get needsSave =>
      status == JobStatus.completed &&
      !isSaved &&
      !serverGone &&
      job?.result != null;

  HistoryEntry copyWith({
    Job? job,
    bool? serverGone,
    SaveState? saveState,
    String? savedUri,
    String? savedName,
    int? savedBytes,
    String? saveError,
    bool clearSaveError = false,
    bool clearSaved = false,
  }) {
    return HistoryEntry(
      jobId: jobId,
      sourceUrl: sourceUrl,
      title: title,
      qualityId: qualityId,
      qualityLabel: qualityLabel,
      platform: platform,
      createdAt: createdAt,
      thumbnail: thumbnail,
      job: job ?? this.job,
      serverGone: serverGone ?? this.serverGone,
      saveState: saveState ?? this.saveState,
      savedUri: clearSaved ? null : (savedUri ?? this.savedUri),
      savedName: clearSaved ? null : (savedName ?? this.savedName),
      savedBytes: clearSaved ? null : (savedBytes ?? this.savedBytes),
      saveError: clearSaveError ? null : (saveError ?? this.saveError),
      serverUrl: serverUrl,
    );
  }

  /// The most specific error to show: the server's job error.
  ApiErrorBody? get serverError => job?.error;

  Map<String, dynamic> toJson() => {
    'job_id': jobId,
    'source_url': sourceUrl,
    'title': title,
    'thumbnail': thumbnail,
    'quality_id': qualityId,
    'quality_label': qualityLabel,
    'platform': platform,
    'created_at': createdAt.toIso8601String(),
    'job': job?.toJson(),
    'server_gone': serverGone,
    'save_state': saveState.name,
    'saved_uri': savedUri,
    'saved_name': savedName,
    'saved_bytes': savedBytes,
    'save_error': saveError,
    'server_url': serverUrl,
  };
}
