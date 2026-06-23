// Light + dark ThemeData seeded on the brand colors.
// Thai body text uses Google Fonts Sarabun (matches tutorial/receipt typography).

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: AppColors.offWhite,
    );
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
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: AppColors.bgDark,
    );
  }

  static ThemeData _base(ColorScheme scheme) {
    final textTheme = GoogleFonts.sarabunTextTheme(
      ThemeData(brightness: scheme.brightness).textTheme,
    );
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
