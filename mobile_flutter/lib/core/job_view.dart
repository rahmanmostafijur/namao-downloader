import 'formatting.dart';
import 'models/job.dart';
import 'models/job_status.dart';

/// Colour intent of a status, resolved to a theme colour by the UI.
enum StatusTone { neutral, active, success, danger }

/// Everything a row needs to render a server job. Derived only from the job record.
class JobView {
  const JobView({
    required this.label,
    required this.tone,
    required this.isTerminal,
    required this.canCancel,
    required this.canRetry,
    this.progress,
    this.speedEta = '',
    this.bytesLine = '',
  });

  /// Shared status wording (identical to the web client).
  final String label;
  final StatusTone tone;
  final bool isTerminal;
  final bool canCancel;
  final bool canRetry;

  /// 0..1 when the server reported a real percentage, null for an indeterminate bar.
  final double? progress;

  /// "1.2 MB/s · 24s left", empty when the server sent neither.
  final String speedEta;

  /// "12.3 MB / 45.0 MB", empty when no byte counts are known.
  final String bytesLine;
}

String statusLabel(Job job) {
  switch (job.status) {
    case JobStatus.queued:
      return job.attempt > 0
          ? 'Retrying (attempt ${job.attempt + 1} of ${job.maxAttempts})…'
          : 'Waiting in queue…';
    case JobStatus.validating:
      return 'Checking link…';
    case JobStatus.fetchingMetadata:
      return 'Reading video info…';
    case JobStatus.downloading:
      return _hasRealPercent(job)
          ? 'Downloading ${formatPercent(job.progress.percent)}'
          : 'Downloading…';
    case JobStatus.merging:
      return 'Merging audio and video…';
    case JobStatus.verifying:
      return 'Verifying file…';
    case JobStatus.completed:
      return 'Ready';
    case JobStatus.failed:
      return 'Failed';
    case JobStatus.cancelled:
      return 'Cancelled';
    case JobStatus.interrupted:
      return 'Interrupted';
  }
}

/// A percentage is only trusted when the server gave a total or a non-zero value:
/// a bare 0 with unknown size would be a fabricated "0%".
bool _hasRealPercent(Job job) {
  final total = job.progress.totalBytes;
  return (total != null && total > 0) || job.progress.percent > 0;
}

bool jobCanRetry(Job job) => switch (job.status) {
  JobStatus.cancelled || JobStatus.interrupted => true,
  JobStatus.failed => job.error?.retryable ?? true,
  _ => false,
};

JobView describeJob(Job job) {
  final status = job.status;
  final isDownloading = status == JobStatus.downloading;
  final determinate = isDownloading && _hasRealPercent(job);
  return JobView(
    label: statusLabel(job),
    tone: switch (status) {
      JobStatus.completed => StatusTone.success,
      JobStatus.failed || JobStatus.interrupted => StatusTone.danger,
      JobStatus.cancelled => StatusTone.neutral,
      _ => StatusTone.active,
    },
    isTerminal: status.isTerminal,
    canCancel: !status.isTerminal,
    canRetry: jobCanRetry(job),
    progress: determinate ? job.progress.percent / 100 : null,
    speedEta: isDownloading ? _speedEta(job.progress) : '',
    bytesLine: isDownloading ? _bytesLine(job.progress) : '',
  );
}

String _speedEta(JobProgress progress) => [
  formatSpeed(progress.speedBps),
  formatEta(progress.etaSeconds),
].where((part) => part != null && part.isNotEmpty).join(' · ');

String _bytesLine(JobProgress progress) {
  final done = formatBytes(progress.downloadedBytes);
  final total = formatBytes(progress.totalBytes);
  if (done != null && total != null) return '$done / $total';
  return done == null ? '' : '$done downloaded';
}
