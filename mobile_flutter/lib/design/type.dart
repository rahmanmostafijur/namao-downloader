import 'package:flutter/material.dart';

import 'tokens.dart';

/// Inter (UI) and Bricolage Grotesque (wordmark, headings): variable fonts bundled as assets.
/// Both the weight and the `wght` axis are set so layout and rendering agree.
TextStyle inter(
  double size,
  FontWeight weight,
  Color color, {
  double? height,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: NamaoFonts.ui,
  fontSize: size,
  fontWeight: weight,
  fontVariations: [FontVariation('wght', weight.value.toDouble())],
  color: color,
  height: height,
  letterSpacing: letterSpacing,
);

TextStyle display(
  double size,
  FontWeight weight,
  Color color, {
  double? height,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: NamaoFonts.display,
  fontSize: size,
  fontWeight: weight,
  fontVariations: [FontVariation('wght', weight.value.toDouble())],
  color: color,
  height: height,
  letterSpacing: letterSpacing,
);

extension TabularFigures on TextStyle {
  /// Equal-width digits so speeds, sizes and percentages don't jitter as they change.
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

TextTheme buildTextTheme(NamaoPalette p) => TextTheme(
  displaySmall: display(
    32,
    FontWeight.w700,
    p.text,
    height: 1.1,
    letterSpacing: -0.6,
  ),
  headlineSmall: display(
    24,
    FontWeight.w700,
    p.text,
    height: 1.2,
    letterSpacing: -0.3,
  ),
  titleLarge: display(
    20,
    FontWeight.w700,
    p.text,
    height: 1.25,
    letterSpacing: -0.2,
  ),
  titleMedium: inter(16, FontWeight.w600, p.text, height: 1.3),
  titleSmall: inter(14, FontWeight.w600, p.text, height: 1.3),
  bodyLarge: inter(16, FontWeight.w400, p.text, height: 1.4),
  bodyMedium: inter(14, FontWeight.w400, p.text, height: 1.4),
  bodySmall: inter(12.5, FontWeight.w400, p.textDim, height: 1.35),
  labelLarge: inter(14, FontWeight.w600, p.text, height: 1.2),
  labelMedium: inter(12.5, FontWeight.w600, p.textDim, height: 1.2),
  labelSmall: inter(
    11.5,
    FontWeight.w500,
    p.textDim,
    height: 1.2,
    letterSpacing: 0.2,
  ),
);
