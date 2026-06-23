// theme_controller — app-wide light/dark mode, persisted to shared_preferences.
//
// The AppShell topbar toggle flips [themeModeProvider]; persistence survives
// restarts under the key `sa_pos_theme` (mirrors the JS localStorage key).
//
// IMPORTANT coordination note: for the toggle to actually re-theme the app, the
// root MaterialApp (lib/app.dart, Contract-owned) must read this provider and
// pass `themeMode: ref.watch(themeModeProvider)`. Until app.dart is updated to
// watch it, the preference is still persisted and exposed here; AppShell reflects
// and toggles the stored value.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kThemeKey = 'sa_pos_theme';

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.light;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kThemeKey);
    if (v == 'dark') {
      state = ThemeMode.dark;
    } else if (v == 'light') {
      state = ThemeMode.light;
    }
  }

  Future<void> toggle() async {
    final next =
        state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kThemeKey, next == ThemeMode.dark ? 'dark' : 'light');
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kThemeKey, mode == ThemeMode.dark ? 'dark' : 'light');
  }
}

/// App-wide theme mode. Read in app.dart for `MaterialApp.themeMode`; toggled
/// from the AppShell topbar.
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
