// The close-drawer tab ("ปิดลิ้นชัก"): typing the counted cash used to make
// the variance row appear ABOVE "🔒 ยืนยันปิดลิ้นชัก", pushing the button down
// ~60 px so a click aimed at it landed on the variance row. The row's space is
// now reserved from the start (the #567 pay-button rule; owner 2026-10-03):
// the button's rect must not move when a count is entered.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/widgets/app_button.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('entering the counted cash does not move the close button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh-today',
              dateStr: todayKey(),
              startingCash: 1000,
              openedAt: DateTime.now(),
              isActive: const Value(true),
            ),
          );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: const MaterialApp(home: Scaffold(body: CashDrawerScreen())),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      await tester.tap(find.text('🔒 ปิดลิ้นชัก'));
      await tester.pumpAndSettle();

      final button = find.ancestor(
        of: find.text('🔒 ยืนยันปิดลิ้นชัก'),
        matching: find.byType(AppButton),
      );
      final before = tester.getRect(button);
      expect(
        find.text('ผลต่าง').hitTestable(),
        findsNothing,
        reason: 'hidden (space kept) until a count is typed',
      );

      await tester.enterText(find.byType(TextField), '900');
      await tester.pumpAndSettle();

      expect(find.text('ผลต่าง').hitTestable(), findsOneWidget);
      expect(find.text('เงินขาด −฿100'), findsOneWidget);
      expect(tester.getRect(button), before);
      await db.close();
    });
  });
}
