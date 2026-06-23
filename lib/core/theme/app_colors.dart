// Brand palette ported from colors_and_type.css :root vars and POS.html.
// Navy + orange auto-parts identity. Keep hex values EXACT.

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // ── BRAND PALETTE (confirmed) ──
  static const Color navy = Color(0xFF0B2444); // Primary — text, borders, fascia
  static const Color orange = Color(0xFFE8601C); // Accent — prices, CTAs
  static const Color steelBlue = Color(0xFF6B8FAF); // Support — secondary text
  static const Color offWhite = Color(0xFFFFFBF2); // Background — signage, receipt
  static const Color forestGreen = Color(0xFF3B6D11); // Confirm — in stock

  // Navy tints
  static const Color navyMid = Color(0xFF153660);
  static const Color navyLight = Color(0xFF1E4A80);
  static const Color navyHover = Color(0xFF24568F);
  static const Color navyDeep = Color(0xFF071A33);

  // Orange tints
  static const Color orangeDark = Color(0xFFC04E10);
  static const Color orangeLight = Color(0xFFFF7A35);

  // Neutral
  static const Color white = Color(0xFFFFFFFF);
  static const Color gray100 = Color(0xFFEDF0F4);
  static const Color gray200 = Color(0xFFD1D8E0);
  static const Color gray300 = Color(0xFFB8C6D4);
  static const Color gray400 = Color(0xFF6B8FAF); // = steel-blue
  static const Color gray500 = Color(0xFF4A6070);
  static const Color gray600 = Color(0xFF2E3D4A);
  static const Color black = Color(0xFF0A0E14);

  // Surfaces (semantic)
  static const Color surfaceLight = offWhite;
  static const Color surfaceLightAlt = Color(0xFFF5F0E6);
  static const Color surfaceDark = navyMid;
  static const Color bgDark = navy;

  // Status
  static const Color success = forestGreen; // #3B6D11
  static const Color successLight = Color(0xFF5A9E2F);
  static const Color warning = Color(0xFFD4820A);
  static const Color error = Color(0xFFC0392B);
  static const Color info = steelBlue;

  // ── Category color palette (CAT_PALETTE from db.js getCatColor) ──
  // Consistent color per category name (index into the seeded category order).
  static const List<Color> catPalette = [
    Color(0xFF1E4A80),
    Color(0xFFC04E10),
    Color(0xFF3B6D11),
    Color(0xFF6B2DA8),
    Color(0xFF1A6B5C),
    Color(0xFF8B4513),
    Color(0xFF1A5C8B),
    Color(0xFF8B2840),
    Color(0xFF4A6B1A),
    Color(0xFF6B4A1A),
  ];

  /// Port of getCatColor(name): index into [catPalette] by the category's
  /// position in [categories]; falls back to a 31-based char hash for unknowns.
  static Color catColor(String name, List<String> categories) {
    final idx = categories.indexOf(name);
    if (idx >= 0) return catPalette[idx % catPalette.length];
    int h = 0;
    for (var i = 0; i < name.length; i++) {
      h = (h * 31 + name.codeUnitAt(i)) & 0xffffffff;
    }
    return catPalette[h.abs() % catPalette.length];
  }
}
