import 'package:flutter/material.dart';

import 'tokens.dart';
import 'type.dart';

ThemeData buildNamaoTheme(Brightness brightness) {
  final p = NamaoPalette.of(brightness);
  final textTheme = buildTextTheme(p);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    error: p.danger,
    onError: p.bg,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.textDim,
    outline: p.border,
    outlineVariant: p.border,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceRaised,
    surfaceContainerHighest: p.surfaceRaised,
    primaryContainer: p.accent.withValues(alpha: 0.16),
    onPrimaryContainer: p.accent,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(NamaoRadius.control),
  );
  const minSize = Size(NamaoLayout.touchTarget, NamaoLayout.touchTarget);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    fontFamily: NamaoFonts.ui,
    textTheme: textTheme,
    extensions: [NamaoColors(p)],
    splashFactory: InkRipple.splashFactory,
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: textTheme.titleLarge,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accent.withValues(alpha: 0.16),
      elevation: 0,
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? p.accent : p.textDim,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => inter(
          12,
          states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          states.contains(WidgetState.selected) ? p.text : p.textDim,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.accent.withValues(alpha: 0.16),
      selectedIconTheme: IconThemeData(color: p.accent),
      unselectedIconTheme: IconThemeData(color: p.textDim),
      selectedLabelTextStyle: inter(12, FontWeight.w600, p.text),
      unselectedLabelTextStyle: inter(12, FontWeight.w500, p.textDim),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.border,
        disabledForegroundColor: p.textDim,
        minimumSize: const Size(NamaoLayout.touchTarget, 52),
        shape: shape,
        textStyle: inter(15, FontWeight.w600, p.onAccent),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        minimumSize: minSize,
        shape: shape,
        side: BorderSide(color: p.border),
        textStyle: inter(14, FontWeight.w600, p.text),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: minSize,
        shape: shape,
        textStyle: inter(14, FontWeight.w600, p.accent),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.textDim,
        minimumSize: minSize,
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceRaised,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: NamaoSpace.l,
        vertical: NamaoSpace.m,
      ),
      hintStyle: textTheme.bodyLarge?.copyWith(color: p.textDim),
      border: _outline(p.border),
      enabledBorder: _outline(p.border),
      focusedBorder: _outline(p.accent, width: 1.5),
      errorBorder: _outline(p.danger),
      focusedErrorBorder: _outline(p.danger, width: 1.5),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(NamaoLayout.touchTarget, NamaoLayout.touchTarget),
        ),
        shape: WidgetStatePropertyAll(shape),
        side: WidgetStatePropertyAll(BorderSide(color: p.border)),
        textStyle: WidgetStatePropertyAll(inter(13.5, FontWeight.w600, p.text)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent.withValues(alpha: 0.16)
              : p.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? p.accent : p.textDim,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.surfaceRaised,
      contentTextStyle: inter(14, FontWeight.w500, p.text),
      actionTextColor: p.accent,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NamaoRadius.control),
        side: BorderSide(color: p.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NamaoRadius.sheet),
        side: BorderSide(color: p.border),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(NamaoRadius.sheet),
        ),
        side: BorderSide(color: p.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NamaoRadius.control),
        side: BorderSide(color: p.border),
      ),
      textStyle: textTheme.bodyMedium,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.border,
      circularTrackColor: p.border,
    ),
  );
}

OutlineInputBorder _outline(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(NamaoRadius.control),
      borderSide: BorderSide(color: color, width: width),
    );
