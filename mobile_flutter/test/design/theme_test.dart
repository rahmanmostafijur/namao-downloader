import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/design/theme.dart';
import 'package:namao_app/design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';
import '../support/pump_app.dart';

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// WCAG 2.x contrast ratio.
double contrast(Color a, Color b) {
  final la = luminance(a);
  final lb = luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(loadBundledFonts);

  group('WCAG contrast of the design tokens (>= 4.5:1 for text)', () {
    for (final palette in [NamaoPalette.dark, NamaoPalette.light]) {
      final name = palette.brightness.name;
      final backgrounds = {
        'bg': palette.bg,
        'surface': palette.surface,
        'surfaceRaised': palette.surfaceRaised,
      };
      final textColors = {
        'text': palette.text,
        'textDim': palette.textDim,
        'accent': palette.accent,
        'success': palette.success,
        'danger': palette.danger,
        'info': palette.info,
      };
      for (final bg in backgrounds.entries) {
        for (final fg in textColors.entries) {
          test('$name: ${fg.key} on ${bg.key}', () {
            expect(
              contrast(fg.value, bg.value),
              greaterThanOrEqualTo(4.5),
              reason:
                  '${fg.key} on ${bg.key} (${contrast(fg.value, bg.value).toStringAsFixed(2)}:1)',
            );
          });
        }
      }
      test('$name: content on accent buttons', () {
        expect(
          contrast(palette.onAccent, palette.accent),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('$name: body text is comfortably above the minimum', () {
        expect(contrast(palette.text, palette.bg), greaterThan(10));
      });
    }

    test('the contrast helper is correct (black on white = 21:1)', () {
      expect(contrast(Colors.black, Colors.white), closeTo(21, 0.01));
      expect(contrast(Colors.white, Colors.white), closeTo(1, 0.001));
    });
  });

  group('tokens', () {
    test('match the shared web design values', () {
      expect(NamaoPalette.dark.bg, const Color(0xFF0B0C0F));
      expect(NamaoPalette.dark.accent, const Color(0xFFF5A524));
      expect(NamaoPalette.dark.onAccent, const Color(0xFF1A1203));
      expect(NamaoPalette.light.bg, const Color(0xFFF6F5F2));
      expect(NamaoPalette.light.accent, const Color(0xFFB45309));
      expect(NamaoRadius.control, 10);
      expect(NamaoRadius.card, 14);
      expect(NamaoRadius.sheet, 20);
      expect(NamaoRadius.pill, 999);
      expect(
        [
          NamaoSpace.xs,
          NamaoSpace.s,
          NamaoSpace.m,
          NamaoSpace.l,
          NamaoSpace.xl,
          NamaoSpace.xxl,
          NamaoSpace.xxxl,
        ],
        [4, 8, 12, 16, 20, 24, 32],
      );
    });

    test('theme data uses the tokens in both brightnesses', () {
      for (final b in Brightness.values) {
        final theme = buildNamaoTheme(b);
        final p = NamaoPalette.of(b);
        expect(theme.brightness, b);
        expect(theme.colorScheme.primary, p.accent);
        expect(theme.colorScheme.onPrimary, p.onAccent);
        expect(theme.scaffoldBackgroundColor, p.bg);
        expect(theme.colorScheme.surface, p.surface);
        expect(theme.colorScheme.outline, p.border);
        expect(theme.extension<NamaoColors>()!.palette, p);
        expect(theme.textTheme.bodyMedium!.fontFamily, NamaoFonts.ui);
        expect(theme.textTheme.titleLarge!.fontFamily, NamaoFonts.display);
        expect(theme.useMaterial3, isTrue);
      }
    });
  });

  group('theme selection', () {
    testWidgets('System follows the platform brightness', (tester) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h, platformBrightness: Brightness.dark);
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
    });

    testWidgets('choosing Light/Dark applies instantly and persists', (
      tester,
    ) async {
      final h = await TestHarness.create();
      addTearDown(h.dispose);
      await pumpNamao(tester, h, platformBrightness: Brightness.dark);
      Brightness current() =>
          Theme.of(tester.element(find.byType(Scaffold).first)).brightness;
      Color scaffoldColor() =>
          Theme.of(tester.element(find.byType(Scaffold).first))
              .scaffoldBackgroundColor;

      await tester.tap(find.text('Settings').last);
      await settle(tester);
      expect(current(), Brightness.dark);

      await tester.tap(find.text('Light'));
      await settle(tester, frames: 10);
      expect(current(), Brightness.light);
      expect(scaffoldColor(), NamaoPalette.light.bg);
      expect(h.prefs.getString('settings.theme_mode'), 'light');

      await tester.tap(find.text('Dark'));
      await settle(tester, frames: 10);
      expect(current(), Brightness.dark);
      expect(scaffoldColor(), NamaoPalette.dark.bg);
      expect(h.prefs.getString('settings.theme_mode'), 'dark');
    });

    testWidgets('a stored theme is applied at startup', (tester) async {
      SharedPreferences.setMockInitialValues({'settings.theme_mode': 'light'});
      final h = await TestHarness.create(
        prefsValues: {'settings.theme_mode': 'light'},
      );
      addTearDown(h.dispose);
      await pumpNamao(tester, h, platformBrightness: Brightness.dark);
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.light,
      );
    });
  });
}
