import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/namao_api.dart';
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

const String interruptedTransferMessage =
    'The transfer to this phone was interrupted. The file is still on the server: tap Retry save.';

/// App-level owner of every tracked download. Lives above the widget tree, so switching tabs
/// never cancels polling or a phone-side transfer.
class DownloadsController extends Notifier<DownloadsState> {
  final Map<String, JobPoller> _pollers = {};
  final Map<String, TransferToken> _tokens = {};
  final List<String> _saveQueue = [];
  final Set<String> _retrying = {};
  bool _serviceRunning = false;
  bool _draining = false;
  bool _notificationsAsked = false;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTransferUi = DateTime.fromMillisecondsSinceEpoch(0);
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
    ref.listen<NamaoApi?>(apiProvider, (previous, next) {
      _stopAllPollers();
      if (next != null && state.isLoaded) unawaited(_trackAll());
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
    final saver = ref.read(fileSaverProvider);
    if (saver != null) await saver.cleanStaleTempFiles();
    if (!ref.mounted) return;
    await _trackAll();
  }

  /// A `transferring` record from an earlier process cannot still be running: it was cut off.
  HistoryEntry _reconcile(HistoryEntry entry) {
    if (entry.saveState != SaveState.transferring) return entry;
    return entry.copyWith(
      saveState: SaveState.failed,
      saveError: interruptedTransferMessage,
    );
  }

  Future<void> onAppResumed() async {
    if (!state.isLoaded) return;
    await _trackAll();
  }

  void onAppPaused() {
    _stopAllPollers();
    _persist(force: true);
  }

  Future<void> _trackAll() async {
    for (final entry in state.entries) {
      if (!ref.mounted) return;
      final status = entry.status;
      if (entry.serverGone || entry.isSaved || !_isCurrentServer(entry)) {
        continue;
      }
      if (status == null || !status.isTerminal) {
        _startPoller(entry.jobId);
      } else if (entry.needsSave) {
        await _refreshOnce(entry.jobId);
        if (!ref.mounted) return;
        final fresh = state.entryFor(entry.jobId);
        if (fresh != null &&
            fresh.needsSave &&
            fresh.saveState == SaveState.none) {
          _enqueueSave(fresh.jobId);
        }
      }
    }
  }

  void _stopAllPollers() {
    for (final poller in _pollers.values) {
      poller.stop();
    }
    _pollers.clear();
  }

  // ----------------------------------------------------------------- polling

  void _startPoller(String id) {
    final api = ref.read(apiProvider);
    if (!ref.mounted || api == null || (_pollers[id]?.isRunning ?? false)) {
      return;
    }
    final poller = JobPoller(
      api: api,
      jobId: id,
      interval: ref.read(pollIntervalProvider),
      onJob: _applyJob,
      onLost: (reason, error) => _onLost(id, reason),
    );
    _pollers[id] = poller;
    unawaited(poller.start());
  }

  String? get _server => ref.read(connectionProvider).url;

  bool _isCurrentServer(HistoryEntry entry) => entry.isForServer(_server);

  Future<void> _refreshOnce(String id) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      final job = await api.getJob(id);
      _applyJob(job);
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
  }

  void _onLost(String id, PollLoss reason) {
    if (!ref.mounted) return;
    _pollers.remove(id);
    final entry = state.entryFor(id);
    if (entry == null) return;
    if (reason == PollLoss.notFound) {
      if (!entry.isSaved) {
        _replace(entry.copyWith(serverGone: true), structural: true);
      }
      return;
    }
    state = state.copyWith(lost: {...state.lost, id: reason});
  }

  /// Retry polling now (the "tap to refresh" affordance and pull-to-refresh).
  Future<void> refresh(String id) async {
    final entry = state.entryFor(id);
    if (entry == null || entry.serverGone || !_isCurrentServer(entry)) return;
    _pollers.remove(id)?.stop();
    await _refreshOnce(id);
    final fresh = state.entryFor(id);
    if (fresh != null && !(fresh.status?.isTerminal ?? false)) _startPoller(id);
  }

  // ------------------------------------------------------------- user actions

  NamaoApi _requireApi() {
    final api = ref.read(apiProvider);
    if (api == null) {
      throw const ApiException(
        kind: ApiFailureKind.server,
        code: 'client_not_configured',
        message: 'Set up a server in Settings first.',
      );
    }
    return api;
  }

  Future<HistoryEntry> start({
    required String sourceUrl,
    required VideoMetadata metadata,
    required FormatOption format,
    required String idempotencyKey,
  }) async {
    final job = await _requireApi().createDownload(
      sourceUrl,
      format.id,
      idempotencyKey,
    );
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
          serverUrl: _server,
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
    // A key derived from the record being retried: a lost answer followed by another tap
    // returns the same new job instead of creating a second one.
    final job = await _requireApi().createDownload(
      old.sourceUrl,
      old.qualityId,
      'retry:${old.jobId}',
    );
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
      serverUrl: _server,
    );
    if (!old.isSaved && job.id != old.jobId) _discard(old.jobId);
    _replace(entry, structural: true, addIfMissing: true);
    if (!job.status.isTerminal) _startPoller(job.id);
    return entry;
  }

  Future<void> cancel(String jobId) async {
    try {
      _applyJob(await _requireApi().cancel(jobId));
    } on ApiException catch (error) {
      if (error.status == 409) {
        await _refreshOnce(
          jobId,
        ); // already finished: show what the server says
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
      transfers: {...state.transfers}..remove(jobId),
    );
  }

  // --------------------------------------------------------------- the phone

  /// Starts (or retries) the device save. Idempotent: a saved or queued job is left alone.
  void saveToDevice(String jobId) {
    final entry = state.entryFor(jobId);
    if (entry == null || !entry.needsSave || !_isCurrentServer(entry)) return;
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
    final media = ref.read(nativeMediaProvider);
    try {
      // Not awaited: the permission dialog must not hold the transfer back on a fresh install.
      unawaited(_askNotificationsOnce(media));
      while (_saveQueue.isNotEmpty) {
        await _saveOne(_saveQueue.removeAt(0), media);
      }
    } finally {
      if (_serviceRunning) {
        _serviceRunning = false;
        await _stopService(media);
      }
      _draining = false;
      if (_saveQueue.isNotEmpty) {
        unawaited(_drainSaves()); // queued while stopping
      }
    }
  }

  Future<void> _askNotificationsOnce(NativeMedia media) async {
    if (_notificationsAsked) return;
    _notificationsAsked = true;
    try {
      await media.requestNotificationPermission();
    } on NativeMediaException {
      // Denied or unavailable: the transfer still runs; only the notification is hidden.
    }
  }

  Future<void> _startService(NativeMedia media) async {
    try {
      await media.startTransfer('Saving to Downloads/Namao');
    } on NativeMediaException {
      // Without the service the transfer still runs while the app is in the foreground.
    }
  }

  Future<void> _stopService(NativeMedia media) async {
    try {
      await media.stopTransfer();
    } on NativeMediaException {
      // Nothing to stop.
    }
  }

  Future<void> _saveOne(String jobId, NativeMedia media) async {
    final entry = state.entryFor(jobId);
    final result = entry?.job?.result;
    final saver = ref.read(fileSaverProvider);
    if (entry == null || result == null || entry.isSaved) return;
    if (saver == null || !_isCurrentServer(entry)) return;
    if (!_serviceRunning) {
      // Started only once a transfer is really going to run, never speculatively.
      _serviceRunning = true;
      await _startService(media);
    }
    final token = TransferToken();
    _tokens[jobId] = token;
    _replace(
      entry.copyWith(saveState: SaveState.transferring, clearSaveError: true),
      structural: true,
    );
    _setTransfer(jobId, 0);
    try {
      final saved = await saver.save(
        jobId: jobId,
        filename: result.filename,
        expectedBytes: result.sizeBytes,
        token: token,
        onProgress: (bytes) =>
            _onTransferProgress(jobId, bytes, result.sizeBytes, media),
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
      if (ref.mounted) {
        state = state.copyWith(transfers: {...state.transfers}..remove(jobId));
      }
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
        serverGone:
            entry.serverGone || error.failure == TransferFailure.expired,
      ),
      structural: true,
    );
  }

  void _setTransfer(String jobId, int bytes) {
    state = state.copyWith(transfers: {...state.transfers, jobId: bytes});
  }

  void _onTransferProgress(
    String jobId,
    int bytes,
    int total,
    NativeMedia media,
  ) {
    final now = ref.read(clockProvider)();
    if (now.difference(_lastTransferUi) >= const Duration(milliseconds: 250)) {
      _lastTransferUi = now;
      _setTransfer(jobId, bytes);
    }
    if (now.difference(_lastNotification) >= const Duration(seconds: 1) &&
        total > 0) {
      _lastNotification = now;
      final percent = (bytes * 100 ~/ total).clamp(0, 100);
      unawaited(_notify(media, percent));
    }
  }

  Future<void> _notify(NativeMedia media, int percent) async {
    try {
      await media.updateTransfer(percent, 'Saving $percent%');
    } on NativeMediaException {
      // The notification is cosmetic.
    }
  }

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
  }

  void _persist({bool force = false}) {
    final now = ref.read(clockProvider)();
    if (!force && now.difference(_lastPersist) < _persistEvery) return;
    _lastPersist = now;
    unawaited(ref.read(historyStoreProvider).save(state.entries));
  }
}
