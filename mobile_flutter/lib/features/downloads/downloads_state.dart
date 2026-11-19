import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/job_poller.dart';
import '../../data/history_entry.dart';
import 'downloads_controller.dart';

/// Immutable snapshot of tracked downloads.
class DownloadsState {
  DownloadsState({
    this.entries = const [],
    this.lost = const {},
    this.isLoaded = false,
  });

  /// Newest first.
  final List<HistoryEntry> entries;

  /// Jobs whose progress could not be read (the download may still be running).
  final Map<String, PollLoss> lost;

  /// History has been read from disk.
  final bool isLoaded;

  late final Map<String, HistoryEntry> _byId = {
    for (final entry in entries) entry.jobId: entry,
  };

  HistoryEntry? entryFor(String jobId) => _byId[jobId];

  DownloadsState copyWith({
    List<HistoryEntry>? entries,
    Map<String, PollLoss>? lost,
    bool? isLoaded,
  }) => DownloadsState(
    entries: entries ?? this.entries,
    lost: lost ?? this.lost,
    isLoaded: isLoaded ?? this.isLoaded,
  );
}

/// Ordered ids for one tab, with value equality so a poll tick that changes nothing
/// structural does not rebuild the list.
@immutable
class IdList {
  const IdList(this.ids);

  final List<String> ids;

  @override
  bool operator ==(Object other) =>
      other is IdList && listEquals(other.ids, ids);

  @override
  int get hashCode => Object.hashAll(ids);
}

typedef TabCounts = ({int active, int completed, int failed});

final downloadsProvider = NotifierProvider<DownloadsController, DownloadsState>(
  DownloadsController.new,
);

final tabIdsProvider = Provider.family<IdList, DownloadsTab>((ref, tab) {
  final entries = ref.watch(downloadsProvider.select((s) => s.entries));
  return IdList([
    for (final entry in entries)
      if (entry.tab == tab) entry.jobId,
  ]);
});

final tabCountsProvider = Provider<TabCounts>((ref) {
  final entries = ref.watch(downloadsProvider.select((s) => s.entries));
  var active = 0;
  var completed = 0;
  var failed = 0;
  for (final entry in entries) {
    switch (entry.tab) {
      case DownloadsTab.active:
        active++;
      case DownloadsTab.completed:
        completed++;
      case DownloadsTab.failed:
        failed++;
    }
  }
  return (active: active, completed: completed, failed: failed);
});

/// One row's data. Selecting a single entry keeps unchanged rows from rebuilding on each poll.
final entryProvider = Provider.family<HistoryEntry?, String>(
  (ref, id) => ref.watch(downloadsProvider.select((s) => s.entryFor(id))),
);

final lostProvider = Provider.family<PollLoss?, String>(
  (ref, id) => ref.watch(downloadsProvider.select((s) => s.lost[id])),
);
