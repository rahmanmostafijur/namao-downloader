import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/api/namao_api.dart';
import 'package:namao_app/data/settings_store.dart';

import '../support/fakes.dart';
import '../support/harness.dart';
import '../support/pump_app.dart';

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Settings').last);
  await settle(tester);
}

void main() {
  setUpAll(loadBundledFonts);

  group('Test connection (real /health/ready result)', () {
    Future<TestHarness> boot(WidgetTester tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openSettings(tester);
      return h;
    }

    testWidgets('ready and authorised', (tester) async {
      final h = await boot(tester);
      await tester.tap(find.text('Test connection'));
      await settle(tester);
      expect(find.textContaining('Connected to 10.0.2.2:8000'), findsOneWidget);
      expect(h.api.calls, contains('check'));
    });

    testWidgets('reachable but not ready lists what is failing', (
      tester,
    ) async {
      final h = await boot(tester);
      h.api.report = const ConnectionReport(
        ready: false,
        authorized: true,
        failingChecks: ['ffmpeg', 'worker'],
      );
      await tester.tap(find.text('Test connection'));
      await settle(tester);
      expect(find.textContaining('not ready'), findsOneWidget);
      expect(find.textContaining('ffmpeg, worker'), findsOneWidget);
    });

    testWidgets('a wrong or missing API key is called out', (tester) async {
      final h = await boot(tester);
      h.api.report = const ConnectionReport(ready: true, authorized: false);
      await tester.tap(find.text('Test connection'));
      await settle(tester);
      expect(find.textContaining('needs a valid API key'), findsOneWidget);
    });

    testWidgets('unreachable server names the address', (tester) async {
      final h = await boot(tester);
      h.api.connectionError = const ApiException.network();
      await tester.tap(find.text('Test connection'));
      await settle(tester);
      expect(find.textContaining("Can't reach 10.0.2.2:8000"), findsOneWidget);
    });

    testWidgets('an address without a scheme is rejected before any request', (
      tester,
    ) async {
      final h = await boot(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'http://10.0.2.2:8000'),
        '192.168.1.5:8000',
      );
      await tester.tap(find.text('Test connection'));
      await settle(tester);
      expect(find.textContaining('Start with http://'), findsOneWidget);
      expect(h.api.calls, isNot(contains('check')));
    });
  });

  testWidgets(
    'plain http to a public host shows the cleartext warning; LAN does not',
    (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await openSettings(tester);
      expect(
        find.textContaining('plain http outside your private network'),
        findsNothing,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'http://10.0.2.2:8000'),
        'http://example.com:8000',
      );
      await settle(tester);
      expect(
        find.textContaining('plain http outside your private network'),
        findsOneWidget,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'http://example.com:8000'),
        'https://example.com',
      );
      await settle(tester);
      expect(
        find.textContaining('plain http outside your private network'),
        findsNothing,
      );
    },
  );

  testWidgets('saving normalises the address and stores the API key securely', (
    tester,
  ) async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    await openSettings(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'http://10.0.2.2:8000'),
      ' http://192.168.1.9:8000/ ',
    );
    await tester.enterText(find.byType(TextField).at(1), 'k3y');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('Server saved'), findsOneWidget);
    expect(h.prefs.getString('settings.server_url'), 'http://192.168.1.9:8000');
    expect(
      h.prefs.getString('settings.api_key'),
      isNull,
      reason: 'the key is never in shared_preferences',
    );
  });

  test(
    'SettingsStore keeps the key in the secret store and the rest in prefs',
    () async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      final secrets = FakeSecretStore();
      final store = SettingsStore(h.prefs, secrets);
      await store.saveServer('http://10.0.2.2:8000', 'topsecret');
      await store.saveTheme(ThemeMode.dark);
      expect(secrets.values.values, ['topsecret']);
      expect(
        h.prefs.getKeys().any(
          (k) => h.prefs.get(k).toString().contains('topsecret'),
        ),
        isFalse,
      );

      final loaded = await store.load();
      expect(loaded.serverUrl, 'http://10.0.2.2:8000');
      expect(loaded.apiKey, 'topsecret');
      expect(loaded.themeMode, ThemeMode.dark);

      await store.saveServer('http://10.0.2.2:8000', null);
      expect((await store.load()).apiKey, isNull);
      expect(secrets.values, isEmpty);
    },
  );

  testWidgets('first run shows setup, saving a server enters the app', (
    tester,
  ) async {
    final h = await TestHarness.create(settings: const AppSettings());
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(find.text('Get formats'), findsNothing);

    await tester.tap(find.textContaining('Use 10.0.2.2:8000'));
    await settle(tester);
    expect(find.text('http://10.0.2.2:8000'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(find.text('Get formats'), findsOneWidget);
  });

  testWidgets(
    'Settings shows storage location, honest limits and the version',
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
    },
  );
}
