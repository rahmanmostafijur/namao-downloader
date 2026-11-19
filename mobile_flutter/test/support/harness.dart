import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:namao_app/data/file_saver.dart';
import 'package:namao_app/data/providers.dart';
import 'package:namao_app/data/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Everything a controller or widget test needs: fakes wired in, real SharedPreferences mock.
class TestHarness {
  TestHarness._({
    required this.api,
    required this.media,
    required this.temp,
    required this.prefs,
    required this.overrides,
  });

  static Future<TestHarness> create({
    Map<String, Object> prefsValues = const {},
    AppSettings? settings,
    FakeApi? api,
    FakeNativeMedia? media,
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    final fakeApi = api ?? FakeApi();
    final fakeMedia = media ?? FakeNativeMedia();
    final temp = Directory.systemTemp.createTempSync('namao_harness');
    var keyCounter = 0;
    return TestHarness._(
      api: fakeApi,
      media: fakeMedia,
      temp: temp,
      prefs: prefs,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialSettingsProvider.overrideWithValue(
          settings ?? configuredSettings(),
        ),
        secretStoreProvider.overrideWithValue(FakeSecretStore()),
        apiFactoryProvider.overrideWithValue((url, key) => fakeApi),
        nativeMediaProvider.overrideWithValue(fakeMedia),
        pollIntervalProvider.overrideWithValue(const Duration(milliseconds: 5)),
        idGeneratorProvider.overrideWithValue(() => 'key-${++keyCounter}'),
        fileSaverProvider.overrideWith(
          (ref) => FileSaver(
            api: fakeApi,
            media: fakeMedia,
            tempDirectory: () => temp,
          ),
        ),
      ],
    );
  }

  final FakeApi api;
  final FakeNativeMedia media;
  final Directory temp;
  final SharedPreferences prefs;
  final List<Override> overrides;

  ProviderContainer container() {
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    return container;
  }

  void dispose() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
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
