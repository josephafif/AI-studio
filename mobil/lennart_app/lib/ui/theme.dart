import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Färger som inte beror på ljust/mörkt läge.
class Palette {
  static const green = Color(0xFF3DDC97);
  static const cyan = Color(0xFF47C7FF);
  static const violet = Color(0xFFA78BFA);
  static const danger = Color(0xFFFF6B6B);
  static const ink = Color(0xFF03140C); // text på färgade ytor
}

/// Färger som skiljer sig mellan ljust och mörkt läge. Hämtas med `context.c`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color bg, surface, glass, stroke, text, muted, accent, rain, bubble;
  final bool dark;
  const AppColors({
    required this.bg, required this.surface, required this.glass, required this.stroke,
    required this.text, required this.muted, required this.accent, required this.rain, required this.bubble, required this.dark,
  });

  static const darkColors = AppColors(
    bg: Color(0xFF05070A), surface: Color(0xFF0D1219), glass: Color(0x14FFFFFF), stroke: Color(0x1FFFFFFF),
    text: Color(0xFFE9EEF5), muted: Color(0xFF8B97A8), accent: Palette.green, rain: Palette.green, bubble: Color(0xFF18202A), dark: true);
  static const lightColors = AppColors(
    bg: Color(0xFFF3F6F9), surface: Color(0xFFFFFFFF), glass: Color(0xB3FFFFFF), stroke: Color(0x1A0B1A2A),
    text: Color(0xFF0D141C), muted: Color(0xFF5B6675), accent: Color(0xFF0E9F62), rain: Color(0xFF0E7A55), bubble: Color(0xFFE6EBF0), dark: false);

  @override
  AppColors copyWith() => this;
  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) => t < 0.5 ? this : (other as AppColors? ?? this);
}

extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>()!;
}

/// Rubriker i Claude-stil: en serif med karaktär (Noto Serif på Android).
const serif = TextStyle(fontFamily: 'serif', fontFamilyFallback: ['Noto Serif', 'DejaVu Serif', 'Georgia']);

const mono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['RobotoMono', 'DejaVu Sans Mono', 'Droid Sans Mono', 'Courier New'],
);

ThemeData buildTheme(Brightness b) {
  final ac = b == Brightness.dark ? AppColors.darkColors : AppColors.lightColors;
  final scheme = ColorScheme.fromSeed(seedColor: Palette.green, brightness: b, surface: ac.surface);
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: ac.bg,
    extensions: [ac],
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: ac.text, fontSize: 15.5, height: 1.45),
      bodySmall: TextStyle(color: ac.muted, fontSize: 12),
      titleMedium: TextStyle(color: ac.text, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    ),
    iconTheme: IconThemeData(color: ac.text),
    sliderTheme: SliderThemeData(
      activeTrackColor: ac.accent,
      inactiveTrackColor: ac.stroke,
      thumbColor: ac.accent,
      overlayColor: ac.accent.withValues(alpha: 0.15),
      trackHeight: 3,
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Colors.transparent, elevation: 0),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ac.dark ? ac.surface : const Color(0xFF0D141C),
      contentTextStyle: const TextStyle(color: Colors.white),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: ac.surface),
  );
}

/// Ljust, mörkt eller som telefonen – sparas mellan starterna.
class Appearance extends ValueNotifier<ThemeMode> {
  Appearance() : super(ThemeMode.system);
  File? _file;

  Future<void> load() async {
    _file = File('${(await getApplicationSupportDirectory()).path}/utseende.txt');
    if (await _file!.exists()) {
      value = ThemeMode.values.firstWhere((m) => m.name == (_file!.readAsStringSync()).trim(), orElse: () => ThemeMode.system);
    }
  }

  void set(ThemeMode mode) {
    value = mode;
    _file?.writeAsString(mode.name);
  }
}

final appearance = Appearance();
