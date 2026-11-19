import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/settings_store.dart';

import '../support/harness.dart';
import '../support/pump_app.dart';

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Settings').last);
  await settle(tester);
}

void main() {
  setUpAll(loadBundledFonts);

  testWidgets('a fresh install opens straight on Home: no setup, no server', (
    tester,
  ) async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);

    await pumpNamao(tester, h);

    expect(find.text('Get formats'), findsOneWidget);
    expect(find.textContaining('Connect to your server'), findsNothing);
    expect(find.textContaining('Server'), findsNothing);
  });

  testWidgets('Settings has no server, address, API key or connection test', (
    tester,
  ) async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);
    await pumpNamao(tester, h);

    await openSettings(tester);

    expect(find.text('SERVER'), findsNothing);
    expect(find.text('Test connection'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('API key'), findsNothing);
    expect(find.text('APPEARANCE'), findsOneWidget);
  });

  testWidgets('engine startup is attempted at launch, off the screen', (
    tester,
  ) async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);

    await pumpNamao(tester, h);

    expect(h.api.calls, contains('prepare'));
  });

  test('SettingsStore removes the server address an older version saved', () async {
    final h = await TestHarness.create(
      prefsValues: {
        'settings.server_url': 'http://192.168.1.9:8000',
        'settings.theme_mode': 'dark',
      },
    );
    addTearDown(h.dispose);
    final store = SettingsStore(h.prefs);

    final loaded = store.load();

    expect(loaded.themeMode, ThemeMode.dark);
    expect(h.prefs.containsKey('settings.server_url'), isFalse);
  });

  test('SettingsStore saves and reloads the theme', () async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);
    final store = SettingsStore(h.prefs);

    await store.saveTheme(ThemeMode.light);

    expect(store.load().themeMode, ThemeMode.light);
  });

  testWidgets(
    'Settings shows storage location, honest limits, licenses and the version',
    (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openSettings(tester);
      await tester.scrollUntilVisible(
        find.textContaining('Version'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Saved to Downloads/Namao'), findsOneWidget);
      expect(find.textContaining('does not bypass logins'), findsOneWidget);
      expect(find.text('Version 1.0.0 (1)'), findsOneWidget);
      expect(find.text('Open-source licenses'), findsOneWidget);
    },
  );
}
