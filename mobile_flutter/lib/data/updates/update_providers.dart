import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'apk_downloader.dart';
import 'apk_installer.dart';
import 'app_release.dart';
import 'engine_update_source.dart';
import 'engine_updater.dart';
import 'update_store.dart';

/// The pieces of the update system that touch the outside world. Tests replace every one of them.

final updateStoreProvider = Provider<UpdateStore>(
  (ref) => UpdateStore(ref.watch(sharedPreferencesProvider)),
);

final engineUpdateSourceProvider = Provider<EngineUpdateSource>(
  (ref) => const MethodChannelEngineUpdateSource(),
);

final engineUpdaterProvider = Provider<EngineUpdater>(
  (ref) => EngineUpdater(ref.watch(engineUpdateSourceProvider)),
);

final appReleaseSourceProvider = Provider<AppReleaseSource>(
  (ref) => GithubReleaseSource(),
);

final apkByteSourceProvider = Provider<ApkByteSource>(
  (ref) => const HttpApkByteSource(),
);

final apkInstallerProvider = Provider<ApkInstaller>((ref) {
  final installer = MethodChannelApkInstaller();
  ref.onDispose(installer.dispose);
  return installer;
});
