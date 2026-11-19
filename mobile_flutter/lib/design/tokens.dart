import 'package:flutter/material.dart';

/// Single source of truth for Namao's visual identity. The web client uses the same values:
/// calm utilitarian surfaces, hairline borders and one warm amber accent.
@immutable
class NamaoPalette {
  const NamaoPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.danger,
    required this.info,
  });

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color text;
  final Color textDim;
  final Color accent;

  /// Content drawn on top of [accent].
  final Color onAccent;
  final Color success;
  final Color danger;
  final Color info;

  static const NamaoPalette dark = NamaoPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF0B0C0F),
    surface: Color(0xFF121317),
    surfaceRaised: Color(0xFF181A20),
    border: Color(0xFF23262E),
    text: Color(0xFFECEDEF),
    textDim: Color(0xFF9096A2),
    accent: Color(0xFFF5A524),
    onAccent: Color(0xFF1A1203),
    success: Color(0xFF3DD68C),
    danger: Color(0xFFF87171),
    info: Color(0xFF7AA2FF),
  );

  static const NamaoPalette light = NamaoPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF6F5F2),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFBFAF8),
    border: Color(0xFFE4E1DA),
    text: Color(0xFF17181B),
    textDim: Color(0xFF5F6470),
    accent: Color(0xFFB45309),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF15803D),
    danger: Color(0xFFB91C1C),
    info: Color(0xFF1D4ED8),
  );

  static NamaoPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

abstract final class NamaoRadius {
  static const double control = 10;
  static const double card = 14;
  static const double sheet = 20;
  static const double pill = 999;
}

/// Spacing scale: 4 / 8 / 12 / 16 / 20 / 24 / 32.
abstract final class NamaoSpace {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

abstract final class NamaoMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOut;

  /// Zero when the system asks for reduced motion.
  static Duration of(BuildContext context, [Duration base = normal]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : base;
}

abstract final class NamaoLayout {
  /// NavigationRail from this width up, NavigationBar below.
  static const double railBreakpoint = 600;

  /// Reading width for single-column screens on tablets.
  static const double contentMaxWidth = 680;

  /// Minimum touch target.
  static const double touchTarget = 48;
}

abstract final class NamaoFonts {
  static const String ui = 'Inter';
  static const String display = 'BricolageGrotesque';
}

/// The palette made available as a [ThemeExtension]: `context.palette`.
@immutable
class NamaoColors extends ThemeExtension<NamaoColors> {
  const NamaoColors(this.palette);

  final NamaoPalette palette;

  @override
  NamaoColors copyWith({NamaoPalette? palette}) =>
      NamaoColors(palette ?? this.palette);

  @override
  NamaoColors lerp(ThemeExtension<NamaoColors>? other, double t) =>
      other is NamaoColors && t >= 0.5 ? other : this;
}

extension NamaoThemeContext on BuildContext {
  NamaoPalette get palette =>
      Theme.of(this).extension<NamaoColors>()?.palette ??
      NamaoPalette.of(Theme.of(this).brightness);
}
