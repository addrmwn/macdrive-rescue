import 'package:flutter/material.dart';

/// Palet warna gelap yang dipakai seluruh aplikasi.
class AppColors {
  static const bg = Color(0xFF0F1117);
  static const card = Color(0xFF171A23);
  static const cardInner = Color(0xFF1E2230);
  static const border = Color(0xFF2A2F42);
  static const text = Color(0xFFE8EAF2);
  static const muted = Color(0xFF8B90A5);
  static const accent = Color(0xFF4F8CFF);
  static const accentDim = Color(0xFF2D4F96);
  static const green = Color(0xFF3DDC84);
  static const red = Color(0xFFFF5C5C);
  static const yellow = Color(0xFFFFC857);
  static const headerBg = Color(0xFF12141D);
}

ThemeData buildDarkTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.card,
      error: AppColors.red,
      onPrimary: Colors.white,
      onSurface: AppColors.text,
    ),
    fontFamily: 'Segoe UI',
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.cardInner,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.cardInner),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(const Color(0xFF333952)),
      radius: const Radius.circular(6),
      thickness: WidgetStateProperty.all(8),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: AppColors.cardInner,
    ),
  );
}