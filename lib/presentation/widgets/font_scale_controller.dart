// font_scale_controller — app-wide text scale multiplier, persisted to
// shared_preferences.
//
// The settings screen (🎨 ธีม tab) exposes preset scale cards + a slider.
// The root MaterialApp (lib/app.dart) wraps the widget tree with a
// MediaQuery override that applies TextScaler.linear(fontScale).
//
// Persistence key: `sa_pos_font_scale` (survives restarts).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kFontScaleKey = 'sa_pos_font_scale';

/// Preset font-scale options shown in the settings UI.
class FontScalePreset {
  final String label;
  final String desc;
  final double value;
  final IconData icon;
  const FontScalePreset({
    required this.label,
    required this.desc,
    required this.value,
    required this.icon,
  });
}

const List<FontScalePreset> fontScalePresets = [
  FontScalePreset(
    label: 'เล็ก',
    desc: 'สำหรับจอใหญ่',
    value: 0.85,
    icon: Icons.text_decrease,
  ),
  FontScalePreset(
    label: 'ปกติ',
    desc: 'ค่าเริ่มต้น',
    value: 1.0,
    icon: Icons.text_fields,
  ),
  FontScalePreset(
    label: 'ใหญ่',
    desc: 'อ่านง่ายขึ้น',
    value: 1.1,
    icon: Icons.text_increase,
  ),
  FontScalePreset(
    label: 'ใหญ่มาก',
    desc: 'ชัดเจนขึ้น',
    value: 1.2,
    icon: Icons.format_size,
  ),
  FontScalePreset(
    label: 'ใหญ่พิเศษ',
    desc: 'สูงสุดที่รองรับ',
    value: 1.25,
    icon: Icons.zoom_in,
  ),
];

class FontScaleNotifier extends Notifier<double> {
  @override
  double build() {
    _load();
    return 1.0; // default — normal size
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_kFontScaleKey);
    if (v != null) {
      state = v;
    }
  }

  Future<void> setScale(double scale) async {
    state = scale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontScaleKey, scale);
  }
}

/// App-wide font scale. Read in app.dart for MediaQuery.textScaler; configured
/// from the Settings screen 🎨 ธีม tab.
final fontScaleProvider =
    NotifierProvider<FontScaleNotifier, double>(FontScaleNotifier.new);
