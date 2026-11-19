import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-chosen appearance, as persisted.
class AppSettings {
  const AppSettings({this.themeMode = ThemeMode.system});

  final ThemeMode themeMode;

  AppSettings copyWith({ThemeMode? themeMode}) =>
      AppSettings(themeMode: themeMode ?? this.themeMode);
}

class SettingsStore {
  SettingsStore(this._prefs);

  static const String _themeKey = 'settings.theme_mode';

  /// Written by versions that needed a server address; removed on load.
  static const String _legacyServerKey = 'settings.server_url';

  final SharedPreferences _prefs;

  AppSettings load() {
    if (_prefs.containsKey(_legacyServerKey)) {
      _prefs.remove(_legacyServerKey);
    }
    return AppSettings(themeMode: _parseTheme(_prefs.getString(_themeKey)));
  }

  Future<void> saveTheme(ThemeMode mode) =>
      _prefs.setString(_themeKey, mode.name);

  ThemeMode _parseTheme(String? name) => ThemeMode.values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => ThemeMode.system,
  );
}
