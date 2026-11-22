import '../core/models/api_error.dart';
import '../core/models/job.dart';
import '../core/models/job_status.dart';
import '../core/models/json_read.dart';

/// State of moving the finished file into Downloads.
enum SaveState {
  /// Not started (the download is not finished, or the save is about to start).
  none,

  /// Writing into MediaStore right now.
  transferring,

  /// In `Download/Namao`. The saved file is now the artifact.
  saved,

  /// The save failed or was interrupted. "Retry save" is offered.
  failed,
}

/// Which list an entry belongs to.
enum DownloadsTab { active, completed, failed }

/// One history record: the download job plus what happened when its file was saved. Persisted
/// on the phone, so it is the only index of past downloads and survives restarts.
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
    this.jobGone = false,
    this.saveState = SaveState.none,
    this.savedUri,
    this.savedName,
    this.savedBytes,
    this.saveError,
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
      jobGone: json['server_gone'] == true,
      saveState: SaveState.values.firstWhere(
        (s) => s.name == stateName,
        orElse: () => SaveState.none,
      ),
      savedUri: readString(json['saved_uri']),
      savedName: readString(json['saved_name']),
      savedBytes: readInt(json['saved_bytes']),
      saveError: readString(json['save_error']),
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

  /// Last job record seen.
  final Job? job;

  /// The download's record or finished file no longer exists on this phone, and it was never
  /// saved (the system cleared the app's storage, or the entry came from an older version).
  final bool jobGone;

  final SaveState saveState;
  final String? savedUri;
  final String? savedName;
  final int? savedBytes;
  final String? saveError;

  JobStatus? get status => job?.status;
  bool get isSaved => saveState == SaveState.saved && savedUri != null;

  /// Failed, cancelled or interrupted before a file was produced (not "gone").
  bool get isFailed => switch (status) {
    JobStatus.failed || JobStatus.cancelled || JobStatus.interrupted => true,
    _ => false,
  };

  /// True while the download is running or the file is being moved into Downloads.
  bool get isActive {
    if (isSaved) return false;
    if (jobGone) return false;
    final s = status;
    if (s == null) return true;
    if (!s.isTerminal) return true;
    return s == JobStatus.completed &&
        (saveState == SaveState.none || saveState == SaveState.transferring);
  }

  DownloadsTab get tab {
    if (isSaved) return DownloadsTab.completed;
    if (jobGone || isFailed) return DownloadsTab.failed;
    if (isActive) return DownloadsTab.active;
    return DownloadsTab
        .completed; // downloaded, but moving it into Downloads failed
  }

  /// A download that finished and whose file has not been saved to Downloads yet.
  bool get needsSave =>
      status == JobStatus.completed &&
      !isSaved &&
      !jobGone &&
      job?.result != null;

  HistoryEntry copyWith({
    Job? job,
    bool? jobGone,
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
      jobGone: jobGone ?? this.jobGone,
      saveState: saveState ?? this.saveState,
      savedUri: clearSaved ? null : (savedUri ?? this.savedUri),
      savedName: clearSaved ? null : (savedName ?? this.savedName),
      savedBytes: clearSaved ? null : (savedBytes ?? this.savedBytes),
      saveError: clearSaveError ? null : (saveError ?? this.saveError),
    );
  }

  /// The most specific error to show: the job's own error.
  ApiErrorBody? get jobError => job?.error;

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
    // Key name kept from the first version so existing history still loads.
    'server_gone': jobGone,
    'save_state': saveState.name,
    'saved_uri': savedUri,
    'saved_name': savedName,
    'saved_bytes': savedBytes,
    'save_error': saveError,
  };
}
