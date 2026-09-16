// Light + dark ThemeData seeded on the brand colors.
// Thai body text uses Sarabun (matches tutorial/receipt typography), bundled
// as a local asset font (#271) rather than fetched at runtime via
// google_fonts — the offline PWA shell can't reach fonts.gstatic.com.

import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.light,
      primary: AppColors.orange,
      secondary: AppColors.navy,
      surface: AppColors.surfaceLight,
      error: AppColors.error,
    );
    return _base(scheme).copyWith(scaffoldBackgroundColor: AppColors.offWhite);
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.dark,
      primary: AppColors.orange,
      secondary: AppColors.steelBlue,
      surface: AppColors.surfaceDark,
      error: AppColors.error,
    );
    return _base(scheme).copyWith(scaffoldBackgroundColor: AppColors.bgDark);
  }

  static ThemeData _base(ColorScheme scheme) {
    // Same shape google_fonts' `sarabunTextTheme()` produced: every Material
    // TextTheme role keeps its own size/weight/spacing, only the font family
    // changes. `Sarabun` is declared in pubspec.yaml with the 400/500 faces
    // Material 3's default TextTheme actually references (see typography.dart
    // englishLike2021 — only w400/w500 appear); any explicit bold request
    // beyond that synthesizes bold from the nearest face, same as before.
    final textTheme = ThemeData(
      brightness: scheme.brightness,
    ).textTheme.apply(fontFamily: 'Sarabun');
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.navy,
        foregroundColor: AppColors.white,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.orange,
          foregroundColor: AppColors.white,
        ),
      ),
    );
  }
}
