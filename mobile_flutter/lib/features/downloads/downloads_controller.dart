import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/job_poller.dart';
import '../../core/models/job.dart';
import '../../core/models/job_status.dart';
import '../../core/models/video_metadata.dart';
import '../../data/file_saver.dart';
import '../../data/history_entry.dart';
import '../../data/native_media.dart';
import '../../data/providers.dart';
import 'downloads_state.dart';

/// Outcome of Open / Share on a saved file.
enum FileActionResult { ok, fileMissing, noAppFound, failed }

const String interruptedSaveMessage =
    'Saving to your phone was interrupted. Tap Retry save.';

/// App-level owner of every tracked download. Lives above the widget tree, so switching tabs
/// never cancels a download or its save, and a foreground notification keeps the app alive while
/// downloads run in the background.
class DownloadsController extends Notifier<DownloadsState> {
  final Map<String, JobPoller> _pollers = {};
  final Map<String, TransferToken> _tokens = {};
  final List<String> _saveQueue = [];
  final Set<String> _retrying = {};
  bool _serviceRunning = false;
  bool _draining = false;
  bool _notificationsAsked = false;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNotification = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum gap between disk writes for progress-only changes.
  static const Duration _persistEvery = Duration(seconds: 5);

  @override
  DownloadsState build() {
    ref.onDispose(() {
      _stopAllPollers();
      for (final token in _tokens.values) {
        token.cancel();
      }
    });
    unawaited(Future<void>.microtask(_restore));
    return DownloadsState();
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> _restore() async {
    final loaded = ref.read(historyStoreProvider).load();
    final reconciled = [for (final e in loaded) _reconcile(e)];
    state = state.copyWith(entries: reconciled, isLoaded: true);
    _persist(force: true);
    // Only a finished download that is waiting to be saved still needs its working files. Anything
    // else (a download cut off when the app died, a failed or cancelled one) left only leftovers,
    // which can be hundreds of MB.
    await ref.read(apiProvider).cleanup({
      for (final e in reconciled)
        if (e.needsSave) e.jobId,
    });
    if (!ref.mounted) return;
    await _trackAll();
  }

  /// A `transferring` record from an earlier process cannot still be running: it was cut off.
  HistoryEntry _reconcile(HistoryEntry entry) {
    if (entry.saveState != SaveState.transferring) return entry;
    return entry.copyWith(
      saveState: SaveState.failed,
      saveError: interruptedSaveMessage,
    );
  }

  Future<void> onAppResumed() async {
    if (!state.isLoaded) return;
    await _trackAll();
  }

  /// Downloads keep running (and being tracked) in the background, so only the history is written.
  void onAppPaused() => _persist(force: true);

  Future<void> _trackAll() async {
    for (final entry in state.entries) {
      if (!ref.mounted) return;
      if (entry.jobGone || entry.isSaved) continue;
      final status = entry.status;
      if (status == null || !status.isTerminal) {
        _startPoller(entry.jobId);
      } else if (entry.needsSave && entry.saveState == SaveState.none) {
        _enqueueSave(entry.jobId);
      }
    }
    _syncService();
  }

  void _stopAllPollers() {
    for (final poller in _pollers.values) {
      poller.stop();
    }
    _pollers.clear();
  }

  // ----------------------------------------------------------------- polling

  void _startPoller(String id) {
    if (!ref.mounted || (_pollers[id]?.isRunning ?? false)) return;
    final poller = JobPoller(
      api: ref.read(apiProvider),
      jobId: id,
      interval: ref.read(pollIntervalProvider),
      onJob: _applyJob,
      onLost: (reason, error) => _onLost(id, reason),
    );
    _pollers[id] = poller;
    unawaited(poller.start());
  }

  Future<void> _refreshOnce(String id) async {
    try {
      _applyJob(await ref.read(apiProvider).getJob(id));
    } on ApiException catch (error) {
      if (error.isJobGone) _onLost(id, PollLoss.notFound);
      // Any other failure leaves the record as it was: nothing is claimed that wasn't seen.
    }
  }

  void _applyJob(Job job) {
    if (!ref.mounted) return;
    final entry = state.entryFor(job.id);
    if (entry == null) return;
    if (job.status.isTerminal) _pollers.remove(job.id);
    final lost = state.lost.containsKey(job.id)
        ? ({...state.lost}..remove(job.id))
        : null;
    if (entry.job != job) {
      final updated = entry.copyWith(job: job);
      _replace(
        updated,
        lost: lost,
        structural: entry.job?.status != job.status,
      );
    } else if (lost != null) {
      state = state.copyWith(lost: lost);
    }
    final fresh = state.entryFor(job.id);
    if (fresh != null &&
        job.status == JobStatus.completed &&
        fresh.needsSave &&
        fresh.saveState == SaveState.none) {
      _enqueueSave(job.id);
    }
    _notifyProgress();
  }

  void _onLost(String id, PollLoss reason) {
    if (!ref.mounted) return;
    _pollers.remove(id);
    final entry = state.entryFor(id);
    if (entry == null) return;
    if (reason == PollLoss.notFound) {
      if (!entry.isSaved) {
        _replace(entry.copyWith(jobGone: true), structural: true);
      }
      return;
    }
    state = state.copyWith(lost: {...state.lost, id: reason});
  }

  /// Retry reading progress now (the "tap to refresh" affordance and pull-to-refresh).
  Future<void> refresh(String id) async {
    final entry = state.entryFor(id);
    if (entry == null || entry.jobGone) return;
    _pollers.remove(id)?.stop();
    await _refreshOnce(id);
    final fresh = state.entryFor(id);
    if (fresh != null && !(fresh.status?.isTerminal ?? false)) _startPoller(id);
  }

  // ------------------------------------------------------------- user actions

  Future<HistoryEntry> start({
    required String sourceUrl,
    required VideoMetadata metadata,
    required FormatOption format,
    required String idempotencyKey,
  }) async {
    final job = await ref
        .read(apiProvider)
        .createDownload(sourceUrl, format.id, idempotencyKey);
    final existing = state.entryFor(job.id);
    final entry =
        existing?.copyWith(job: job) ??
        HistoryEntry(
          jobId: job.id,
          sourceUrl: sourceUrl,
          title: metadata.title,
          thumbnail: metadata.thumbnail,
          qualityId: format.id,
          qualityLabel: format.label,
          platform: job.platform.isEmpty ? metadata.platform : job.platform,
          createdAt: ref.read(clockProvider)(),
          job: job,
        );
    _replace(entry, structural: true, addIfMissing: true);
    if (!job.status.isTerminal) _startPoller(job.id);
    return entry;
  }

  /// A new job (new idempotency key) for the same link and quality. The failed record is replaced.
  Future<HistoryEntry> retry(String jobId) async {
    final old = state.entryFor(jobId);
    if (old == null) throw StateError('Unknown download $jobId');
    if (!_retrying.add(jobId)) {
      return old; // a second tap while the first is in flight
    }
    try {
      return await _retry(old);
    } finally {
      _retrying.remove(jobId);
    }
  }

  Future<HistoryEntry> _retry(HistoryEntry old) async {
    // A key derived from the record being retried: a second tap returns the same new job
    // instead of creating another one.
    final job = await ref
        .read(apiProvider)
        .createDownload(old.sourceUrl, old.qualityId, 'retry:${old.jobId}');
    final entry = HistoryEntry(
      jobId: job.id,
      sourceUrl: old.sourceUrl,
      title: old.title,
      thumbnail: old.thumbnail,
      qualityId: old.qualityId,
      qualityLabel: old.qualityLabel,
      platform: old.platform,
      createdAt: ref.read(clockProvider)(),
      job: job,
    );
    if (!old.isSaved && job.id != old.jobId) _discard(old.jobId);
    _replace(entry, structural: true, addIfMissing: true);
    if (!job.status.isTerminal) _startPoller(job.id);
    return entry;
  }

  Future<void> cancel(String jobId) async {
    try {
      _applyJob(await ref.read(apiProvider).cancel(jobId));
    } on ApiException catch (error) {
      if (error.status == 409) {
        await _refreshOnce(jobId); // already finished: show what really happened
        return;
      }
      rethrow;
    }
  }

  /// Removes the history record only. The saved media file is never touched.
  void remove(String jobId) {
    _discard(jobId);
    _persist(force: true);
  }

  /// Removes every finished record; running downloads keep being tracked.
  void clearFinished() {
    for (final entry in state.entries.where((e) => !e.isActive)) {
      _discard(entry.jobId);
    }
    _persist(force: true);
  }

  void _discard(String jobId) {
    _tokens[jobId]?.cancel();
    _pollers.remove(jobId)?.stop();
    _saveQueue.remove(jobId);
    state = state.copyWith(
      entries: [
        for (final e in state.entries)
          if (e.jobId != jobId) e,
      ],
      lost: {...state.lost}..remove(jobId),
    );
    // A finished file that was never saved is of no use once its record is gone.
    unawaited(ref.read(apiProvider).release(jobId));
    _syncService();
  }

  // --------------------------------------------------------------- the phone

  /// Starts (or retries) saving into Downloads. Idempotent: a saved or queued job is left alone.
  void saveToDevice(String jobId) {
    final entry = state.entryFor(jobId);
    if (entry == null || !entry.needsSave) return;
    if (entry.saveState == SaveState.failed) {
      _replace(
        entry.copyWith(saveState: SaveState.none, clearSaveError: true),
        structural: true,
      );
    }
    _enqueueSave(jobId);
  }

  void _enqueueSave(String jobId) {
    if (_saveQueue.contains(jobId) || _tokens.containsKey(jobId)) return;
    _saveQueue.add(jobId);
    unawaited(_drainSaves());
  }

  Future<void> _drainSaves() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_saveQueue.isNotEmpty) {
        await _saveOne(_saveQueue.removeAt(0));
      }
    } finally {
      _draining = false;
      if (_saveQueue.isNotEmpty) {
        unawaited(_drainSaves()); // queued while stopping
      }
    }
  }

  Future<void> _saveOne(String jobId) async {
    final entry = state.entryFor(jobId);
    final result = entry?.job?.result;
    if (entry == null || result == null || entry.isSaved) return;
    final token = TransferToken();
    _tokens[jobId] = token;
    _replace(
      entry.copyWith(saveState: SaveState.transferring, clearSaveError: true),
      structural: true,
    );
    try {
      final saved = await ref
          .read(fileSaverProvider)
          .save(
            jobId: jobId,
            filename: result.filename,
            expectedBytes: result.sizeBytes,
            token: token,
          );
      _finishSave(jobId, saved: saved);
    } on TransferException catch (error) {
      _finishSave(jobId, failure: error);
    } on Object {
      _finishSave(
        jobId,
        failure: const TransferException(
          TransferFailure.io,
          'Saving failed unexpectedly. Please try again.',
        ),
      );
    } finally {
      _tokens.remove(jobId);
    }
  }

  void _finishSave(
    String jobId, {
    SavedMedia? saved,
    TransferException? failure,
  }) {
    if (!ref.mounted) return;
    final entry = state.entryFor(jobId);
    if (entry == null) return;
    if (saved != null) {
      _replace(
        entry.copyWith(
          saveState: SaveState.saved,
          savedUri: saved.uri,
          savedName: saved.displayName,
          savedBytes: saved.sizeBytes,
          clearSaveError: true,
        ),
        structural: true,
      );
      return;
    }
    final error = failure!;
    _replace(
      entry.copyWith(
        saveState: SaveState.failed,
        saveError: error.message,
        jobGone: entry.jobGone || error.failure == TransferFailure.expired,
      ),
      structural: true,
    );
  }

  // ------------------------------------------------- background notification

  /// Keeps one foreground notification up for as long as anything is downloading or being
  /// saved, so Android does not stop the app while it works in the background.
  void _syncService() {
    if (!ref.mounted) return;
    final shouldRun = state.entries.any((e) => e.isActive);
    if (shouldRun == _serviceRunning) return;
    _serviceRunning = shouldRun;
    final media = ref.read(nativeMediaProvider);
    unawaited(shouldRun ? _startService(media) : _stopService(media));
  }

  Future<void> _startService(NativeMedia media) async {
    try {
      // Not awaited: the permission dialog must not hold the download back on a fresh install.
      unawaited(_askNotificationsOnce(media));
      await media.startTransfer('Preparing your download…');
    } on NativeMediaException {
      // Without the service the download still runs while the app is in the foreground.
    }
  }

  Future<void> _stopService(NativeMedia media) async {
    try {
      await media.stopTransfer();
    } on NativeMediaException {
      // Nothing to stop.
    }
  }

  Future<void> _askNotificationsOnce(NativeMedia media) async {
    if (_notificationsAsked) return;
    _notificationsAsked = true;
    try {
      await media.requestNotificationPermission();
    } on NativeMediaException {
      // Denied or unavailable: downloads still run; only the notification is hidden.
    }
  }

  /// At most once a second: the notification shows the real progress of the running download.
  void _notifyProgress() {
    if (!_serviceRunning) return;
    final now = ref.read(clockProvider)();
    if (now.difference(_lastNotification) < const Duration(seconds: 1)) return;
    _lastNotification = now;
    final active = state.entries.where((e) => e.isActive).toList();
    if (active.isEmpty) return;
    var percent = -1;
    final String text;
    if (active.length > 1) {
      text = 'Downloading ${active.length} videos…';
    } else {
      final job = active.first.job;
      final status = job?.status;
      if (status == JobStatus.downloading && job!.progress.percent > 0) {
        percent = job.progress.percent.round().clamp(0, 100);
        text = 'Downloading $percent%';
      } else if (status == JobStatus.merging ||
          status == JobStatus.verifying ||
          status == JobStatus.completed) {
        text = 'Finishing…';
      } else {
        text = 'Preparing your download…';
      }
    }
    unawaited(_notify(ref.read(nativeMediaProvider), percent, text));
  }

  Future<void> _notify(NativeMedia media, int percent, String text) async {
    try {
      await media.updateTransfer(percent, text);
    } on NativeMediaException {
      // The notification is cosmetic.
    }
  }

  // ------------------------------------------------------------- open / share

  Future<FileActionResult> openSaved(String jobId) => _fileAction(
    jobId,
    (media, entry, mime) => media.open(entry.savedUri!, mime),
  );

  Future<FileActionResult> shareSaved(String jobId) => _fileAction(
    jobId,
    (media, entry, mime) => media.share(entry.savedUri!, mime, entry.title),
  );

  Future<FileActionResult> _fileAction(
    String jobId,
    Future<void> Function(NativeMedia media, HistoryEntry entry, String mime)
    action,
  ) async {
    final entry = state.entryFor(jobId);
    if (entry == null || !entry.isSaved) return FileActionResult.failed;
    final media = ref.read(nativeMediaProvider);
    try {
      if (!await media.exists(entry.savedUri!)) {
        _replace(
          entry.copyWith(
            saveState: SaveState.failed,
            saveError:
                'The saved file was moved or deleted from Downloads/Namao.',
            clearSaved: true,
            // The working copy was deleted when it was saved: only a new download can recover it.
            jobGone: true,
          ),
          structural: true,
        );
        return FileActionResult.fileMissing;
      }
      await action(
        media,
        entry,
        mimeFor(entry.savedName ?? entry.job?.result?.filename ?? ''),
      );
      return FileActionResult.ok;
    } on NativeMediaException catch (error) {
      return error.failure == NativeMediaFailure.noAppToOpen
          ? FileActionResult.noAppFound
          : FileActionResult.failed;
    }
  }

  // ------------------------------------------------------------------ state

  void _replace(
    HistoryEntry entry, {
    Map<String, PollLoss>? lost,
    bool structural = false,
    bool addIfMissing = false,
  }) {
    final exists = state.entryFor(entry.jobId) != null;
    final List<HistoryEntry> entries;
    if (exists) {
      entries = [
        for (final e in state.entries) e.jobId == entry.jobId ? entry : e,
      ];
    } else if (addIfMissing) {
      entries = [entry, ...state.entries];
    } else {
      return;
    }
    state = state.copyWith(entries: entries, lost: lost);
    _persist(force: structural);
    if (structural) _syncService();
  }

  void _persist({bool force = false}) {
    final now = ref.read(clockProvider)();
    if (!force && now.difference(_lastPersist) < _persistEvery) return;
    _lastPersist = now;
    unawaited(ref.read(historyStoreProvider).save(state.entries));
  }
}
