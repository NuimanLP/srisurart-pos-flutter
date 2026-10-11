// Whole-screen zoom (ui_zoom_controller.dart): the cap per screen size, and
// that a zoomed app is laid out smaller, painted larger, and still tappable.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/presentation/widgets/ui_zoom_controller.dart';

void main() {
  group('effectiveUiZoom', () {
    test('no zoom stays 1', () {
      expect(effectiveUiZoom(const Size(1920, 1080), 1.0), 1.0);
    });

    test('a big screen takes the requested zoom', () {
      expect(effectiveUiZoom(const Size(1920, 1080), 3.0), 3.0);
    });

    test('a laptop is capped by its height', () {
      expect(effectiveUiZoom(const Size(1366, 768), 3.0), 768 / 320);
    });

    test('a phone cannot zoom below the smallest supported layout', () {
      expect(effectiveUiZoom(const Size(390, 844), 2.0), 390 / 360);
      expect(effectiveUiZoom(const Size(320, 640), 2.0), 1.0);
    });
  });

  testWidgets('zoomed app is laid out smaller and taps still land', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size logical;
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => UiZoom(zoom: 2.0, child: child!),
        home: Builder(
          builder: (context) {
            logical = MediaQuery.sizeOf(context);
            return Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 100,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () => taps++,
                    child: const Text('ok'),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    expect(logical, const Size(600, 450));
    // 100x50 logical → painted 200x100 on screen.
    expect(tester.getSize(find.byType(ElevatedButton)), const Size(100, 50));
    final rect = tester.getRect(find.byType(ElevatedButton));
    expect(rect.width, 200);
    expect(rect.height, 100);

    // Outside the unzoomed 100x50 but inside the zoomed 200x100.
    await tester.tapAt(const Offset(170, 80));
    expect(taps, 1);
  });
}
