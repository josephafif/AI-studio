import 'package:flutter/material.dart';

class Palette {
  static const bg = Color(0xFF06080C);
  static const surface = Color(0xFF0E131B);
  static const glass = Color(0x14FFFFFF);
  static const stroke = Color(0x1FFFFFFF);
  static const text = Color(0xFFE9EEF5);
  static const muted = Color(0xFF8B97A8);
  static const green = Color(0xFF3DDC97);
  static const cyan = Color(0xFF47C7FF);
  static const violet = Color(0xFFA78BFA);
  static const danger = Color(0xFFFF6B6B);

  /// En egen färg per Lennart-version: grön, cyan, violett, rosa …
  static Color model(int index) {
    const hues = [152.0, 192.0, 262.0, 322.0, 38.0];
    return HSLColor.fromAHSL(1, hues[index % hues.length], 0.85, 0.62).toColor();
  }
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Palette.green,
    brightness: Brightness.dark,
    surface: Palette.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.bg,
    fontFamily: 'Roboto',
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: Palette.text, fontSize: 15.5, height: 1.45),
      bodySmall: TextStyle(color: Palette.muted, fontSize: 12),
      titleMedium: TextStyle(color: Palette.text, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: Palette.green,
      inactiveTrackColor: Palette.stroke,
      thumbColor: Palette.green,
      overlayColor: Palette.green.withValues(alpha: 0.15),
      trackHeight: 3,
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Colors.transparent, elevation: 0),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: Palette.surface),
  );
}
