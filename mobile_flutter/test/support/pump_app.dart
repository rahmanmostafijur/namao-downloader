import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/app.dart';

import 'harness.dart';

/// Registers the bundled Inter and Bricolage Grotesque files so widget tests lay text out with the
/// real glyph metrics instead of the Ahem test font (whose wide boxes would fake overflows).
Future<void> loadBundledFonts() async {
  for (final (family, path) in [
    ('Inter', 'assets/fonts/Inter.ttf'),
    ('BricolageGrotesque', 'assets/fonts/BricolageGrotesque.ttf'),
  ]) {
    final bytes = File(path).readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(
        Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))),
      );
    await loader.load();
  }
}

/// Mounts the whole app with fakes. [size] is in logical px (DPR 1).
Future<void> pumpNamao(
  WidgetTester tester,
  TestHarness harness, {
  Size size = const Size(400, 800),
  double textScale = 1.0,
  Brightness? platformBrightness,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  if (platformBrightness != null) {
    tester.platformDispatcher.platformBrightnessTestValue = platformBrightness;
  }
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });
  await tester.pumpWidget(
    ProviderScope(overrides: harness.overrides, child: const NamaoApp()),
  );
  await settle(tester);
}

/// Pumps a few frames. pumpAndSettle never returns here: skeletons and progress bars animate forever.
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void mockClipboard(WidgetTester tester, String? text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' ? {'text': text} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}
