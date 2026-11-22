import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:namao_app/data/providers.dart';
import 'package:namao_app/data/updates/update_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'update_fakes.dart';

/// Everything a controller or widget test needs: fakes wired in, real SharedPreferences mock.
/// The update fakes start quiet (downloader just checked, no newer app), so tests that are not
/// about updating never see an update.
class TestHarness {
  TestHarness._({
    required this.api,
    required this.media,
    required this.prefs,
    required this.overrides,
    required this.engineUpdates,
    required this.releases,
    required this.apkBytes,
    required this.installer,
  });

  static Future<TestHarness> create({
    Map<String, Object> prefsValues = const {},
    ThemeMode? themeMode,
    FakeApi? api,
    FakeNativeMedia? media,
    FakeEngineUpdateSource? engineUpdates,
    FakeReleaseSource? releases,
    FakeApkByteSource? apkBytes,
    FakeApkInstaller? installer,
  }) async {
    SharedPreferences.setMockInitialValues({
      ...prefsValues,
      if (themeMode != null) 'settings.theme_mode': themeMode.name,
    });
    final prefs = await SharedPreferences.getInstance();
    final fakeApi = api ?? FakeApi();
    final fakeMedia = media ?? FakeNativeMedia();
    final fakeEngineUpdates = engineUpdates ?? FakeEngineUpdateSource();
    final fakeReleases = releases ?? FakeReleaseSource();
    final fakeBytes = apkBytes ?? FakeApkByteSource();
    final fakeInstaller = installer ?? FakeApkInstaller();
    var keyCounter = 0;
    return TestHarness._(
      api: fakeApi,
      media: fakeMedia,
      prefs: prefs,
      engineUpdates: fakeEngineUpdates,
      releases: fakeReleases,
      apkBytes: fakeBytes,
      installer: fakeInstaller,
      overrides: [
        engineUpdateSourceProvider.overrideWithValue(fakeEngineUpdates),
        appReleaseSourceProvider.overrideWithValue(fakeReleases),
        apkByteSourceProvider.overrideWithValue(fakeBytes),
        apkInstallerProvider.overrideWithValue(fakeInstaller),
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(fakeApi),
        nativeMediaProvider.overrideWithValue(fakeMedia),
        pollIntervalProvider.overrideWithValue(const Duration(milliseconds: 5)),
        idGeneratorProvider.overrideWithValue(() => 'key-${++keyCounter}'),
      ],
    );
  }

  final FakeApi api;
  final FakeNativeMedia media;
  final SharedPreferences prefs;
  final List<Override> overrides;
  final FakeEngineUpdateSource engineUpdates;
  final FakeReleaseSource releases;
  final FakeApkByteSource apkBytes;
  final FakeApkInstaller installer;

  ProviderContainer container() {
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    return container;
  }

  void dispose() {
    api.dispose();
    installer.dispose();
  }
}

/// Polls [condition] on the real event loop until it holds (or fails the test after [timeout]).
Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

ThemeMode themeModeOf(String name) =>
    ThemeMode.values.firstWhere((m) => m.name == name);
