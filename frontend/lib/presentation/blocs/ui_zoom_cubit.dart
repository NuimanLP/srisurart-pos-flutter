// UiZoomCubit — whole-screen zoom for elderly users, persisted to
// shared_preferences under `sa_pos_ui_zoom` (survives restarts).
//
// The font-size control (FontScaleCubit) only grows text and tops out at
// 1.25x: past that, fixed-height cards and rows overflow. Zoom instead scales
// EVERYTHING (text, buttons, images, spacing) like browser zoom — see the
// [UiZoom] widget (widgets/ui_zoom.dart), which the root MaterialApp wraps
// around the app.
//
// The zoom actually applied is capped per screen so the logical screen never
// drops below [kUiZoomMinLogicalWidth] × [kUiZoomMinLogicalHeight] — narrower
// than the smallest phone layout the app supports would overflow.

import 'dart:ui' show Size;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kUiZoomKey = 'sa_pos_ui_zoom';

/// Narrowest logical width the app is laid out at (smallest supported phone).
const double kUiZoomMinLogicalWidth = 360;

/// Shortest logical height the app is laid out at.
const double kUiZoomMinLogicalHeight = 320;

/// Zoom levels offered in Settings.
const List<double> uiZoomLevels = [1.0, 1.5, 2.0, 2.5, 3.0];

/// The largest zoom a screen of [screen] logical size can take.
double maxUiZoomFor(Size screen) {
  final byWidth = screen.width / kUiZoomMinLogicalWidth;
  final byHeight = screen.height / kUiZoomMinLogicalHeight;
  final max = byWidth < byHeight ? byWidth : byHeight;
  return max < 1.0 ? 1.0 : max;
}

/// The zoom actually applied: [requested] capped by [maxUiZoomFor].
double effectiveUiZoom(Size screen, double requested) {
  if (requested <= 1.0) return 1.0;
  final max = maxUiZoomFor(screen);
  return requested < max ? requested : max;
}

class UiZoomCubit extends Cubit<double> {
  UiZoomCubit() : super(1.0) {
    _load();
  }

  bool _chosen = false;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_kUiZoomKey);
    // A choice made while prefs were loading wins over the stored value.
    if (v != null && v >= 1.0 && !_chosen) {
      emit(v);
    }
  }

  Future<void> setZoom(double zoom) async {
    _chosen = true;
    emit(zoom);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiZoomKey, zoom);
  }
}
