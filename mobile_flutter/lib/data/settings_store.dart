import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-configured connection and appearance, as persisted.
class AppSettings {
  const AppSettings({
    this.serverUrl,
    this.apiKey,
    this.themeMode = ThemeMode.system,
  });

  /// Normalised (scheme required, no trailing slash). Null until first-run setup is done.
  final String? serverUrl;
  final String? apiKey;
  final ThemeMode themeMode;

  bool get isConfigured => serverUrl != null && serverUrl!.isNotEmpty;

  AppSettings copyWith({
    String? serverUrl,
    String? apiKey,
    bool clearApiKey = false,
    ThemeMode? themeMode,
  }) => AppSettings(
    serverUrl: serverUrl ?? this.serverUrl,
    apiKey: clearApiKey ? null : (apiKey ?? this.apiKey),
    themeMode: themeMode ?? this.themeMode,
  );
}

/// Where the API key lives. Backed by Android Keystore-protected storage in the app.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      // An unreadable key (e.g. keystore reset) behaves as "no key"; the user re-enters it.
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SettingsStore {
  SettingsStore(this._prefs, this._secrets);

  static const String _urlKey = 'settings.server_url';
  static const String _themeKey = 'settings.theme_mode';
  static const String _apiKeyKey = 'settings.api_key';

  final SharedPreferences _prefs;
  final SecretStore _secrets;

  Future<AppSettings> load() async {
    final key = await _secrets.read(_apiKeyKey);
    return AppSettings(
      serverUrl: _prefs.getString(_urlKey),
      apiKey: (key == null || key.isEmpty) ? null : key,
      themeMode: _parseTheme(_prefs.getString(_themeKey)),
    );
  }

  Future<void> saveServer(String url, String? apiKey) async {
    await _prefs.setString(_urlKey, url);
    if (apiKey == null || apiKey.isEmpty) {
      await _secrets.delete(_apiKeyKey);
    } else {
      await _secrets.write(_apiKeyKey, apiKey);
    }
  }

  Future<void> saveTheme(ThemeMode mode) =>
      _prefs.setString(_themeKey, mode.name);

  ThemeMode _parseTheme(String? name) => ThemeMode.values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => ThemeMode.system,
  );
}
