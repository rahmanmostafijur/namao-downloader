import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/namao_api.dart';
import '../core/uuid.dart';
import 'engine/local_engine.dart';
import 'engine/local_namao_api.dart';
import 'file_saver.dart';
import 'history_store.dart';
import 'native_media.dart';
import 'session/instagram_session_store.dart';
import 'settings_store.dart';

/// Overridden in `main()` after SharedPreferences is opened.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) =>
      throw UnimplementedError('sharedPreferencesProvider must be overridden'),
);

final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => SettingsStore(ref.watch(sharedPreferencesProvider)),
);

final historyStoreProvider = Provider<HistoryStore>(
  (ref) => HistoryStore(ref.watch(sharedPreferencesProvider)),
);

final nativeMediaProvider = Provider<NativeMedia>(
  (ref) => const MethodChannelNativeMedia(),
);

/// The on-device yt-dlp + FFmpeg runner. Tests replace this with a fake.
final localEngineProvider = Provider<LocalEngine>(
  (ref) => const MethodChannelLocalEngine(),
);

/// Idempotency keys and the like: injectable so tests are deterministic.
final idGeneratorProvider = Provider<String Function()>((ref) => newUuid);

/// How often a running download is checked.
final pollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsStoreProvider).load();

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await ref.read(settingsStoreProvider).saveTheme(mode);
  }
}

/// The user's optional Instagram session (their own cookies.txt, encrypted on this phone).
final instagramSessionStoreProvider = Provider<InstagramSessionStore>(
  (ref) => const MethodChannelInstagramSessionStore(),
);

/// The downloader every screen uses: it runs on this phone.
final apiProvider = Provider<NamaoApi>(
  (ref) => LocalNamaoApi(
    engine: ref.watch(localEngineProvider),
    sessions: ref.watch(instagramSessionStoreProvider),
  ),
);

final fileSaverProvider = Provider<FileSaver>(
  (ref) => FileSaver(
    api: ref.watch(apiProvider),
    media: ref.watch(nativeMediaProvider),
  ),
);
