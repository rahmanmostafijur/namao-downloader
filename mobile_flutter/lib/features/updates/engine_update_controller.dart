import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/updates/distribution.dart';
import '../../data/updates/engine_update_source.dart';
import '../../data/updates/engine_updater.dart';
import '../../data/updates/update_providers.dart';
import '../downloads/downloads_state.dart';

enum EngineUpdatePhase { idle, checking, updating }

class EngineUpdateState {
  const EngineUpdateState({
    this.phase = EngineUpdatePhase.idle,
    this.progress,
    this.info,
    this.outcome,
    this.updatedCount = 0,
  });

  final EngineUpdatePhase phase;

  /// 0 to 1 while an update is being installed.
  final double? progress;
  final EngineInfo? info;

  /// How the last attempt ended; cleared when the next one starts.
  final EngineUpdateOutcome? outcome;

  /// How many updates succeeded in this session: the screens announce each increase once.
  final int updatedCount;

  bool get isBusy => phase != EngineUpdatePhase.idle;

  EngineUpdateState copyWith({
    EngineInfo? info,
    EngineUpdateOutcome? outcome,
  }) => EngineUpdateState(
    phase: phase,
    progress: progress,
    info: info ?? this.info,
    outcome: outcome ?? this.outcome,
    updatedCount: updatedCount,
  );
}

final engineUpdateProvider =
    NotifierProvider<EngineUpdateController, EngineUpdateState>(
      EngineUpdateController.new,
    );

/// Drives the downloader updates the screens show: the automatic check at launch, the manual one
/// in Settings, the progress, and the result. What counts as newer, and every safety guarantee,
/// is in [EngineUpdater] and the native side.
class EngineUpdateController extends Notifier<EngineUpdateState> {
  @override
  EngineUpdateState build() => const EngineUpdateState();

  EngineUpdateSource get _source => ref.read(engineUpdateSourceProvider);

  Future<EngineInfo?> _readInfo() async {
    try {
      return await _source.info();
    } on EngineUpdateException {
      return null;
    }
  }

  Future<void> refresh() async {
    final info = await _readInfo();
    if (info != null && ref.mounted) state = state.copyWith(info: info);
  }

  /// The launch-time check: only when switched on and not checked within the last day.
  Future<void> autoCheck() async {
    if (!kUpdatesEnabled || state.isBusy) return;
    final info = await _readInfo();
    if (info == null || !ref.mounted) return;
    state = state.copyWith(info: info);
    if (!EngineUpdater.isAutoCheckDue(info, ref.read(clockProvider)())) return;
    await _run();
  }

  Future<void> checkNow() => _run();

  Future<void> setAutoUpdate(bool enabled) async {
    final info = state.info;
    if (info != null) {
      state = state.copyWith(info: info.withAutoUpdate(enabled));
    }
    try {
      await _source.setAutoUpdate(enabled);
    } on EngineUpdateException {
      await refresh(); // show what is really stored
    }
  }

  Future<void> _run() async {
    if (state.isBusy) return;
    // Downloads are protected twice: here, and by the native side, which refuses to swap the
    // engine while any process of it is running.
    if (ref.read(tabCountsProvider).active > 0) {
      state = state.copyWith(
        outcome: const EngineUpdateOutcome(EngineUpdateKind.busy),
      );
      return;
    }
    state = EngineUpdateState(
      phase: EngineUpdatePhase.checking,
      info: state.info,
      updatedCount: state.updatedCount,
    );
    final poll = Timer.periodic(
      ref.read(pollIntervalProvider),
      (_) => unawaited(_pollProgress()),
    );
    final EngineUpdateOutcome outcome;
    try {
      outcome = await ref.read(engineUpdaterProvider).update();
    } finally {
      poll.cancel();
    }
    if (!ref.mounted) return;
    final info = await _readInfo();
    if (!ref.mounted) return;
    state = EngineUpdateState(
      info: info ?? state.info,
      outcome: outcome,
      updatedCount:
          state.updatedCount +
          (outcome.kind == EngineUpdateKind.updated ? 1 : 0),
    );
  }

  Future<void> _pollProgress() async {
    if (!ref.mounted || !state.isBusy) return;
    final info = await _readInfo();
    if (info == null || !info.updating || !ref.mounted || !state.isBusy) return;
    state = EngineUpdateState(
      phase: EngineUpdatePhase.updating,
      progress: (info.progress ?? 0) / 100,
      info: info,
      updatedCount: state.updatedCount,
    );
  }
}
