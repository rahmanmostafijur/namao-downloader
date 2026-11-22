import 'dart:async';
import 'dart:io';

import 'package:namao_app/data/updates/apk_downloader.dart';
import 'package:namao_app/data/updates/apk_installer.dart';
import 'package:namao_app/data/updates/app_release.dart';
import 'package:namao_app/data/updates/engine_update_source.dart';

/// A scriptable downloader-update backend. Failures leave the "installed" version untouched, the
/// way the native side keeps the previous engine in place.
class FakeEngineUpdateSource implements EngineUpdateSource {
  FakeEngineUpdateSource({EngineInfo? info, this.latest = '2026.11.10'})
    : current =
          info ?? EngineInfo(version: '2026.11.10', lastCheck: DateTime.now());

  EngineInfo current;
  String latest;
  EngineUpdateException? latestError;
  EngineUpdateException? installError;

  /// While set, [install] waits for it; [info] reports an update in progress during that wait.
  Completer<void>? installGate;
  bool _installing = false;

  final List<String> calls = [];

  @override
  Future<EngineInfo> info() async {
    calls.add('info');
    if (_installing) {
      return EngineInfo(
        version: current.version,
        autoUpdate: current.autoUpdate,
        updating: true,
        progress: 40,
      );
    }
    return current;
  }

  @override
  Future<String> latestVersion() async {
    calls.add('latest');
    final error = latestError;
    if (error != null) throw error;
    return latest;
  }

  @override
  Future<String> install(String version) async {
    calls.add('install $version');
    final gate = installGate;
    if (gate != null) {
      _installing = true;
      await gate.future;
      _installing = false;
    }
    final error = installError;
    if (error != null) throw error;
    final now = DateTime.now();
    current = EngineInfo(
      version: version,
      previousVersion: current.version,
      autoUpdate: current.autoUpdate,
      lastCheck: now,
      lastUpdate: now,
    );
    return version;
  }

  @override
  Future<void> setAutoUpdate(bool enabled) async {
    calls.add('auto $enabled');
    current = current.withAutoUpdate(enabled);
  }

  @override
  Future<void> markChecked() async {
    calls.add('checked');
  }
}

class FakeReleaseSource implements AppReleaseSource {
  AppRelease? release;
  Object? error;
  int calls = 0;

  @override
  Future<AppRelease?> latest() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return release;
  }
}

AppRelease makeRelease({
  String version = '9.9.9',
  String notes = '• Faster downloads\n• Fewer failures',
  String? sha256,
  int? sizeBytes,
}) => AppRelease(
  versionName: version,
  notes: notes,
  apkUrl: Uri.https(
    'github.com',
    '/x/y/releases/download/v$version/namao-android.apk',
  ),
  pageUrl: Uri.https('github.com', '/x/y/releases/tag/v$version'),
  sha256: sha256,
  sizeBytes: sizeBytes,
);

/// Serves fixed bytes (in small chunks) as the update file.
class FakeApkByteSource implements ApkByteSource {
  FakeApkByteSource([this.bytes = const [1, 2, 3, 4, 5, 6, 7, 8]]);

  List<int> bytes;
  Object? error;
  int opened = 0;

  @override
  Future<ApkByteStream> open(Uri url) async {
    opened++;
    final failure = error;
    if (failure != null) throw failure;
    final chunks = [
      for (var i = 0; i < bytes.length; i += 3)
        bytes.sublist(i, i + 3 > bytes.length ? bytes.length : i + 3),
    ];
    return ApkByteStream(Stream.fromIterable(chunks), bytes.length);
  }
}

/// Android's installer, recorded. Nothing is ever "installed" unless a test says the person agreed.
class FakeApkInstaller implements ApkInstaller {
  final Directory dir = Directory.systemTemp.createTempSync('namao_fake_apk');
  final StreamController<InstallResult> _results =
      StreamController<InstallResult>.broadcast();

  InstallStart startResult = const InstallStart(InstallStartKind.started);
  final List<String> installedPaths = [];
  final List<Uri> openedLinks = [];

  @override
  Future<String> downloadDir() async => dir.path;

  @override
  Future<InstallStart> install(String path) async {
    installedPaths.add(path);
    return startResult;
  }

  @override
  Future<void> openLink(Uri url) async => openedLinks.add(url);

  @override
  Stream<InstallResult> get results => _results.stream;

  /// What the system installer reports after the person answers its confirmation screen.
  void report(String status, {String? message}) =>
      _results.add(InstallResult(status, message: message));

  void dispose() {
    _results.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
