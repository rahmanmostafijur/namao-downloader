import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';

import '../support/harness.dart';
import '../support/pump_app.dart';

bool _buttonEnabled(WidgetTester tester, String label) =>
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, label))
        .onPressed !=
    null;

void main() {
  setUpAll(loadBundledFonts);

  testWidgets('paste -> formats -> select -> download -> View', (tester) async {
    final h = await TestHarness.create();
    h.api.hangJobs = true;
    addTearDown(h.dispose);
    mockClipboard(tester, 'https://youtu.be/abc123');
    await pumpNamao(tester, h);

    // Idle: supported sites, button disabled.
    expect(find.text('WORKS WITH'), findsOneWidget);
    expect(_buttonEnabled(tester, 'Get formats'), isFalse);

    await tester.tap(find.text('Paste'));
    await settle(tester);
    expect(find.text('https://youtu.be/abc123'), findsOneWidget);
    expect(find.text('YouTube'), findsWidgets); // detection chip

    await tester.tap(find.text('Get formats'));
    await tester.pump(); // request in flight
    await settle(tester);
    expect(h.api.calls, contains('metadata https://youtu.be/abc123'));

    // Metadata preview and grouped formats, exactly as listed by the server.
    expect(find.text('Sample video title'), findsOneWidget);
    expect(find.text('Some Channel · 2:05'), findsOneWidget);
    expect(find.text('VIDEO'), findsOneWidget);
    expect(find.text('AUDIO'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(
      find.text('~50.0 MB'),
      findsOneWidget,
      reason: 'estimated size has a tilde',
    );
    expect(find.text('30.0 MB'), findsOneWidget);
    expect(find.text('size unknown'), findsOneWidget);
    expect(
      find.text('2160p'),
      findsNothing,
      reason: 'never show a quality the server did not list',
    );
    expect(find.text('Download 1080p'), findsNothing);

    await tester.tap(find.text('1080p'));
    await settle(tester);
    expect(find.text('Download 1080p'), findsOneWidget);

    await tester.tap(find.text('Download 1080p'));
    await settle(tester);
    expect(h.api.calls, contains('create https://youtu.be/abc123 1080'));
    expect(h.api.idempotencyKeys, ['key-1']);
    expect(find.text('Added to Downloads'), findsOneWidget);
    expect(find.text('Download 1080p'), findsNothing);

    // The Downloads tab badge shows one active download; View jumps there.
    expect(find.text('1'), findsWidgets);
    await tester.tap(find.text('View'));
    await settle(tester);
    expect(find.text('Sample video title'), findsOneWidget);
    expect(find.text('Preparing your download…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('an unsupported link shows the message and blocks the request', (
    tester,
  ) async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);
    await pumpNamao(tester, h);
    await tester.enterText(find.byType(TextField), 'https://vimeo.com/123');
    await settle(tester);
    expect(find.textContaining("not supported yet"), findsOneWidget);
    expect(_buttonEnabled(tester, 'Get formats'), isFalse);
    await tester.tap(find.byTooltip('Clear'));
    await settle(tester);
    expect(find.textContaining("not supported yet"), findsNothing);
  });

  testWidgets(
    'a lost internet connection says so in plain words; Retry recovers',
    (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      h.api.metadataError = const ApiException(
        code: 'network_transient',
        message: 'Your internet connection was interrupted.',
        retryable: true,
      );
      await pumpNamao(tester, h);
      await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
      await settle(tester);
      await tester.tap(find.text('Get formats'));
      await settle(tester);
      expect(
        find.text('Your internet connection was interrupted.'),
        findsOneWidget,
      );
      expect(find.textContaining('server'), findsNothing);

      h.api.metadataError = null;
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('Sample video title'), findsOneWidget);
    },
  );

  testWidgets('a refusal shows its message; non-retryable offers no Retry', (
    tester,
  ) async {
    final h = await TestHarness.create();
    addTearDown(h.dispose);
    h.api.metadataError = const ApiException(
      code: 'unsupported_content',
      message: 'Only single, non-live videos are supported.',
      status: 400,
    );
    await pumpNamao(tester, h);
    await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
    await settle(tester);
    await tester.tap(find.text('Get formats'));
    await settle(tester);
    expect(
      find.text('Only single, non-live videos are supported.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'a failed Download keeps formats; the next tap starts a fresh one',
    (tester) async {
      final h = await TestHarness.create();
      h.api.hangJobs = true;
      addTearDown(h.dispose);
      await pumpNamao(tester, h);
      await tester.enterText(find.byType(TextField), 'https://youtu.be/abc');
      await settle(tester);
      await tester.tap(find.text('Get formats'));
      await settle(tester);
      await tester.tap(find.text('1080p'));
      await settle(tester);

      h.api.createResult = const ApiException(
        code: 'environment_unsupported',
        message: "Namao couldn't get ready on this phone.",
        retryable: true,
      );
      await tester.tap(find.text('Download 1080p'));
      await settle(tester);
      expect(find.textContaining("couldn't get ready"), findsWidgets);
      expect(
        find.text('Download 1080p'),
        findsOneWidget,
        reason: 'formats and button remain',
      );

      h.api.createResult = 'auto';
      await tester.tap(find.text('Download 1080p'));
      await settle(tester);
      expect(
        h.api.idempotencyKeys,
        ['key-1', 'key-2'],
        reason: 'each tap is its own download; nothing is sent over a network to lose',
      );
      expect(find.text('Added to Downloads'), findsOneWidget);
    },
  );
}
