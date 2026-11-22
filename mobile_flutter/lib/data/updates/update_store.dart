import 'package:shared_preferences/shared_preferences.dart';

/// What the app-update checker remembers between launches: when it last looked, and which version
/// the person asked not to be reminded about yet.
class UpdateStore {
  UpdateStore(this._prefs);

  static const String _lastCheckKey = 'updates.app_last_check_ms';
  static const String _snoozedVersionKey = 'updates.app_snoozed_version';
  static const String _snoozedUntilKey = 'updates.app_snoozed_until_ms';

  final SharedPreferences _prefs;

  DateTime? get lastAppCheck {
    final ms = _prefs.getInt(_lastCheckKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> recordAppCheck(DateTime at) =>
      _prefs.setInt(_lastCheckKey, at.millisecondsSinceEpoch);

  /// Whether the prompt for [version] was dismissed and its reminder is not due yet. A different
  /// (newer) version is never snoozed: it is news.
  bool isSnoozed(String version, DateTime now) {
    if (_prefs.getString(_snoozedVersionKey) != version) return false;
    final ms = _prefs.getInt(_snoozedUntilKey);
    return ms != null && now.millisecondsSinceEpoch < ms;
  }

  Future<void> snooze(String version, DateTime until) async {
    await _prefs.setString(_snoozedVersionKey, version);
    await _prefs.setInt(_snoozedUntilKey, until.millisecondsSinceEpoch);
  }
}
