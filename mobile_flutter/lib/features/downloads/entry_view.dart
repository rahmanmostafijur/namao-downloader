import '../../core/error_messages.dart';
import '../../core/formatting.dart';
import '../../core/job_poller.dart';
import '../../core/job_view.dart';
import '../../core/models/job_status.dart';
import '../../core/url_tools.dart';
import '../../data/history_entry.dart';

/// Everything a downloads row shows, derived from the history record (server job + device state).
class EntryView {
  const EntryView({
    required this.label,
    required this.tone,
    required this.tab,
    this.progress,
    this.showProgress = false,
    this.message,
    this.hint,
    this.messageIsError = false,
    this.detail = '',
    this.bytesLine = '',
    this.sizeLine = '',
    this.canCancel = false,
    this.canRetry = false,
    this.canRetrySave = false,
    this.isSaved = false,
    this.canRemove = false,
    this.canRefresh = false,
  });

  final String label;
  final StatusTone tone;
  final DownloadsTab tab;

  /// Bar value 0..1; null with [showProgress] = indeterminate.
  final double? progress;
  final bool showProgress;

  /// Explanatory line under the status (error text, save status).
  final String? message;
  final String? hint;
  final bool messageIsError;

  /// "1.2 MB/s · 24s left".
  final String detail;

  /// "12.3 MB / 45.0 MB".
  final String bytesLine;

  /// Final size, shown once the file exists.
  final String sizeLine;

  final bool canCancel;
  final bool canRetry;
  final bool canRetrySave;
  final bool isSaved;
  final bool canRemove;
  final bool canRefresh;
}

EntryView describeEntry(
  HistoryEntry entry, {
  PollLoss? lost,
  int? transferBytes,
  bool otherServer = false,
}) {
  if (entry.isSaved) return _saved(entry);
  if (otherServer) return _otherServer(entry);
  if (entry.serverGone) return _expired(entry);
  final job = entry.job;
  if (job == null) {
    return EntryView(
      label: 'Waiting in queue…',
      tone: StatusTone.active,
      tab: entry.tab,
      showProgress: true,
      canCancel: true,
    );
  }
  if (job.status == JobStatus.completed) {
    return _completedOnServer(entry, transferBytes);
  }
  return _fromJob(entry, lost);
}

EntryView _saved(HistoryEntry entry) {
  final size = formatBytes(entry.savedBytes ?? entry.job?.result?.sizeBytes);
  return EntryView(
    label: 'Saved',
    tone: StatusTone.success,
    tab: DownloadsTab.completed,
    message: 'Downloads/Namao/${entry.savedName ?? ''}'.replaceAll(
      RegExp(r'/$'),
      '',
    ),
    sizeLine: size ?? '',
    isSaved: true,
    canRemove: true,
  );
}

EntryView _otherServer(HistoryEntry entry) => EntryView(
  label: 'On another server',
  tone: StatusTone.neutral,
  tab: entry.tab,
  message:
      'This download belongs to ${serverLabel(entry.serverUrl ?? 'another server')}. '
      'Switch back to that server in Settings to keep tracking it.',
  canRemove: true,
);

EntryView _expired(HistoryEntry entry) => const EntryView(
  label: 'Expired',
  tone: StatusTone.danger,
  tab: DownloadsTab.failed,
  message: 'The server no longer has this download. Retry fetches it again from the source.',
  messageIsError: true,
  canRetry: true,
  canRemove: true,
);

EntryView _completedOnServer(HistoryEntry entry, int? transferBytes) {
  final total = entry.job?.result?.sizeBytes ?? 0;
  final size = formatBytes(total) ?? '';
  switch (entry.saveState) {
    case SaveState.transferring:
      final known = total > 0 && transferBytes != null;
      return EntryView(
        label: known
            ? 'Saving to phone ${formatPercent(transferBytes * 100 / total)}'
            : 'Saving to phone…',
        tone: StatusTone.active,
        tab: entry.tab,
        progress: known ? transferBytes / total : null,
        showProgress: true,
        bytesLine: known ? '${formatBytes(transferBytes)} / $size' : '',
      );
    case SaveState.failed:
      return EntryView(
        label: 'Ready',
        tone: StatusTone.success,
        tab: entry.tab,
        message: entry.saveError ?? "Couldn't save to this phone.",
        messageIsError: true,
        sizeLine: size,
        canRetrySave: true,
        canRemove: true,
      );
    case SaveState.none:
    case SaveState.saved:
      return EntryView(
        label: 'Ready',
        tone: StatusTone.success,
        tab: entry.tab,
        message: 'Preparing to save…',
        showProgress: true,
        sizeLine: size,
      );
  }
}

EntryView _fromJob(HistoryEntry entry, PollLoss? lost) {
  final job = entry.job!;
  final view = describeJob(job);
  final failed = entry.isFailedOnServer;
  final presentation = failed ? presentJobError(job.error) : null;
  final showCancelledMessage = job.status != JobStatus.cancelled;
  return EntryView(
    label: view.label,
    tone: view.tone,
    tab: entry.tab,
    progress: view.progress,
    showProgress: !view.isTerminal,
    message:
        _lostMessage(lost) ??
        (showCancelledMessage ? presentation?.message : null),
    hint: lost == null && showCancelledMessage ? presentation?.hint : null,
    messageIsError: failed || lost != null,
    detail: view.speedEta,
    bytesLine: view.bytesLine,
    canCancel: view.canCancel && lost != PollLoss.notFound,
    canRetry: view.canRetry,
    canRemove: view.isTerminal,
    canRefresh: lost != null,
  );
}

String? _lostMessage(PollLoss? lost) => switch (lost) {
  PollLoss.unauthorized => 'The server rejected the API key, so progress can’t be updated. Check Settings.',
  PollLoss.unreachable =>
    'Lost contact with the server. The download may still be running.',
  _ => null,
};
