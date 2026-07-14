// theme_controller — app-wide light/dark mode, persisted to shared_preferences.
//
// The AppShell topbar toggle flips [ThemeModeCubit]'s state; persistence
// survives restarts under the key `sa_pos_theme` (mirrors the JS localStorage
// key).
//
// IMPORTANT coordination note: for the toggle to actually re-theme the app, the
// root MaterialApp (lib/app.dart, Contract-owned) must read this cubit and
// pass `themeMode: context.watch<ThemeModeCubit>().state`.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kThemeKey = 'sa_pos_theme';

class ThemeModeCubit extends Cubit<ThemeMode> {
  ThemeModeCubit() : super(ThemeMode.light) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kThemeKey);
    if (v == 'dark') {
      emit(ThemeMode.dark);
    } else if (v == 'light') {
      emit(ThemeMode.light);
    }
  }

  Future<void> toggle() async {
    final next = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    emit(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kThemeKey, next == ThemeMode.dark ? 'dark' : 'light');
  }

  Future<void> set(ThemeMode mode) async {
    emit(mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kThemeKey, mode == ThemeMode.dark ? 'dark' : 'light');
  }
}
