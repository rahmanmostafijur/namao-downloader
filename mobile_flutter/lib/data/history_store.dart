import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'history_entry.dart';

/// Newest entries are kept; oldest are dropped beyond this many.
const int maxHistoryEntries = 200;

/// Persists download history locally (there is no list-jobs endpoint on the server).
class HistoryStore {
  HistoryStore(this._prefs);

  static const String _key = 'history.v1';

  final SharedPreferences _prefs;

  /// Tolerant: a missing, corrupt or partially invalid blob yields what could be read.
  List<HistoryEntry> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final byId = <String, HistoryEntry>{};
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final entry = HistoryEntry.fromJson(item);
      if (entry.jobId.isEmpty) continue;
      byId.putIfAbsent(entry.jobId, () => entry); // dedupe by job id
    }
    return List.unmodifiable(byId.values);
  }

  Future<void> save(List<HistoryEntry> entries) {
    final capped = entries.length > maxHistoryEntries
        ? entries.sublist(0, maxHistoryEntries)
        : entries;
    return _prefs.setString(
      _key,
      jsonEncode([for (final e in capped) e.toJson()]),
    );
  }

  Future<void> clear() => _prefs.remove(_key);
}
