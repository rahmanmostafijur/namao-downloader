import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/http_namao_api.dart';
import '../core/api/namao_api.dart';
import '../core/uuid.dart';
import 'file_saver.dart';
import 'history_store.dart';
import 'native_media.dart';
import 'settings_store.dart';

/// Overridden in `main()` after SharedPreferences is opened.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) =>
      throw UnimplementedError('sharedPreferencesProvider must be overridden'),
);

/// Settings read once before the first frame (the API key lives in secure storage, which is async).
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

final secretStoreProvider = Provider<SecretStore>(
  (ref) => const SecureSecretStore(),
);

final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => SettingsStore(
    ref.watch(sharedPreferencesProvider),
    ref.watch(secretStoreProvider),
  ),
);

final historyStoreProvider = Provider<HistoryStore>(
  (ref) => HistoryStore(ref.watch(sharedPreferencesProvider)),
);

final nativeMediaProvider = Provider<NativeMedia>(
  (ref) => const MethodChannelNativeMedia(),
);

/// Idempotency keys and the like: injectable so tests are deterministic.
final idGeneratorProvider = Provider<String Function()>((ref) => newUuid);

/// How often a running job is polled.
final pollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  Future<void> saveServer(String url, String? apiKey) async {
    await ref.read(settingsStoreProvider).saveServer(url, apiKey);
    final key = (apiKey == null || apiKey.isEmpty) ? null : apiKey;
    state = AppSettings(
      serverUrl: url,
      apiKey: key,
      themeMode: state.themeMode,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await ref.read(settingsStoreProvider).saveTheme(mode);
  }
}

/// The server connection (url + key only, so theme changes don't rebuild the client).
final connectionProvider = Provider<({String? url, String? key})>((ref) {
  final settings = ref.watch(settingsProvider);
  return (url: settings.serverUrl, key: settings.apiKey);
});

/// Builds a client for a server address. Tests replace this with a fake.
final apiFactoryProvider = Provider<NamaoApi Function(String url, String? key)>(
  (ref) =>
      (url, key) => HttpNamaoApi(baseUrl: url, apiKey: key),
);

/// Null until the user has configured a server.
final apiProvider = Provider<NamaoApi?>((ref) {
  final connection = ref.watch(connectionProvider);
  final url = connection.url;
  if (url == null || url.isEmpty) return null;
  final api = ref.watch(apiFactoryProvider)(url, connection.key);
  ref.onDispose(api.close);
  return api;
});

final fileSaverProvider = Provider<FileSaver?>((ref) {
  final api = ref.watch(apiProvider);
  if (api == null) return null;
  return FileSaver(
    api: api,
    media: ref.watch(nativeMediaProvider),
    tempDirectory: () => Directory.systemTemp,
  );
});
