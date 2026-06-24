// Regression test for the ClosingReport responsive layout (HIGH #3).
//
// The end-of-day closing report (reachable on phones via Cash Drawer's
// "สรุปยอดปิดร้าน") used a fixed two-column Row: Expanded left + a 320px right
// pane. On a phone the left pane collapsed to ~30-80px and its KPI grid /
// payment rows overflowed. The fix wraps the body in a LayoutBuilder that stacks
// the panes vertically below ~720px. This test pumps ClosingReport at phone and
// tablet sizes and asserts it renders without a RenderFlex overflow exception.
//
// Harness mirrors route_smoke_test.dart (in-memory Drift DB, fonts disabled,
// async drained inside runAsync, DB closed in-body).

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/providers/providers.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  for (final size in const [Size(400, 800), Size(1280, 800)]) {
    final label = size.width == 400 ? 'phone' : 'tablet';

    testWidgets('ClosingReport renders without overflow at $label',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      Object? caught;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const MaterialApp(home: Scaffold(body: ClosingReport())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        caught = tester.takeException();
        await db.close();
      });

      expect(
        caught,
        isNull,
        reason:
            'ClosingReport overflowed at $label (${size.width.toInt()}x${size.height.toInt()})',
      );
    });
  }
}
