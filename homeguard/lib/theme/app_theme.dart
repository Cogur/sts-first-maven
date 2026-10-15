import 'package:flutter/material.dart';

/// Dark-first security console palette. Accent colours carry meaning:
/// green = secure/LAN, amber = remote/degraded, red = alarm/offline.
abstract final class AppColors {
  static const background = Color(0xFF0B0F14);
  static const surface = Color(0xFF131A22);
  static const surfaceHigh = Color(0xFF1B2430);
  static const outline = Color(0xFF263241);
  static const primary = Color(0xFF3FA9F5);
  static const secure = Color(0xFF2ECC71);
  static const warning = Color(0xFFF5A623);
  static const danger = Color(0xFFE74C3C);
  static const textMuted = Color(0xFF8A99AB);
}

abstract final class AppTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(seedColor: AppColors.primary, brightness: Brightness.dark).copyWith(
      primary: AppColors.primary,
      surface: AppColors.surface,
      surfaceContainerHighest: AppColors.surfaceHigh,
      outline: AppColors.outline,
      error: AppColors.danger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: Color(0x333FA9F5),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
      chipTheme: const ChipThemeData(side: BorderSide(color: AppColors.outline)),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  /// Light theme kept for accessibility; the app defaults to dark.
  static ThemeData light() =>
      ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary));
}
