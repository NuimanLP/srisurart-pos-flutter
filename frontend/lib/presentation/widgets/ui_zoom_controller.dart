// ui_zoom_controller — whole-screen zoom for elderly users, persisted to
// shared_preferences.
//
// The font-size control (font_scale_controller.dart) only grows text and tops
// out at 1.25x: past that, fixed-height cards and rows overflow. Zoom instead
// scales EVERYTHING (text, buttons, images, spacing) like browser zoom: the app
// is laid out on a smaller logical screen (size / zoom) and painted scaled up,
// so the responsive breakpoints simply switch to the tablet/phone layouts.
//
// The zoom actually applied is capped per screen so the logical screen never
// drops below [kUiZoomMinLogicalWidth] × [kUiZoomMinLogicalHeight] — narrower
// than the smallest phone layout the app supports would overflow.
//
// Persistence key: `sa_pos_ui_zoom` (survives restarts).

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'font_scale_controller.dart';

const String _kUiZoomKey = 'sa_pos_ui_zoom';

/// Narrowest logical width the app is laid out at (smallest supported phone).
const double kUiZoomMinLogicalWidth = 360;

/// Shortest logical height the app is laid out at.
const double kUiZoomMinLogicalHeight = 320;

const List<FontScalePreset> uiZoomPresets = [
  FontScalePreset(
    label: 'ปกติ',
    desc: 'ไม่ขยาย',
    value: 1.0,
    icon: Icons.crop_free,
  ),
  FontScalePreset(label: '1.5 เท่า', desc: '', value: 1.5, icon: Icons.zoom_in),
  FontScalePreset(label: '2 เท่า', desc: '', value: 2.0, icon: Icons.zoom_in),
  FontScalePreset(label: '2.5 เท่า', desc: '', value: 2.5, icon: Icons.zoom_in),
  FontScalePreset(label: '3 เท่า', desc: '', value: 3.0, icon: Icons.zoom_in),
];

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

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_kUiZoomKey);
    if (v != null && v >= 1.0) {
      emit(v);
    }
  }

  Future<void> setZoom(double zoom) async {
    emit(zoom);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiZoomKey, zoom);
  }
}

/// Lays [child] out on a screen [zoom] times smaller and paints it [zoom]
/// times larger. Hit testing goes through the same transform (FittedBox).
class UiZoom extends StatelessWidget {
  final double zoom;
  final Widget child;
  const UiZoom({super.key, required this.zoom, required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final z = effectiveUiZoom(mq.size, zoom);
    if (z <= 1.0) return child;
    final size = mq.size / z;
    return MediaQuery(
      data: mq.copyWith(
        size: size,
        devicePixelRatio: mq.devicePixelRatio * z,
        padding: mq.padding / z,
        viewPadding: mq.viewPadding / z,
        viewInsets: mq.viewInsets / z,
        systemGestureInsets: mq.systemGestureInsets / z,
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(size: size, child: child),
      ),
    );
  }
}
