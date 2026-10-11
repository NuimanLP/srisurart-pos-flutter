// UiZoom — lays the app out on a screen [zoom] times smaller and paints it
// [zoom] times larger, like browser zoom. Wrapped around the whole app in
// MaterialApp.builder (lib/app.dart) from UiZoomCubit's state, so dialogs and
// menus (inside the Navigator overlay) are zoomed too. Hit testing goes
// through the same transform (FittedBox). The zoom is capped per screen by
// effectiveUiZoom (blocs/ui_zoom_cubit.dart).
//
// The tree shape is the same at every zoom (1x included): returning [child]
// bare at 1x would remount the Router/Navigator subtree — losing its state —
// whenever the applied zoom crosses 1x (choosing 1x, or a window resize
// across the cap).
//
// Known limit: the cap uses the full screen height, not the height minus the
// on-screen keyboard, so a form dialog on a landscape tablet at its cap may
// overflow while the keyboard is open.

import 'package:flutter/widgets.dart';

import '../blocs/ui_zoom_cubit.dart';

class UiZoom extends StatelessWidget {
  final double zoom;
  final Widget child;
  const UiZoom({super.key, required this.zoom, required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final z = effectiveUiZoom(mq.size, zoom);
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
