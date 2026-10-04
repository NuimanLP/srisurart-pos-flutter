// Owner 2026-10-04: a shift still OPEN after midnight is the current shift —
// the cash-drawer screen shows it and the closing report's drawer check uses
// it, whatever day it was opened. A CLOSED shift from an earlier day is not
// today's. Before this fix both screens kept only `dateStr == today`, so a
// shift opened at 20:00 vanished at 00:00 although its money still counted
// by shift (`ShiftsRepository.drawerCash`, owner 2026-10-03).
//
// "Now" is the real clock (today); the shift is dated yesterday 20:00 — the
// bug's exact shape, with no clock injection.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';
import 'package:srisurart_pos/presentation/widgets/thai_format.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  final now = DateTime.now();
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  final openedAt = DateTime(yesterday.year, yesterday.month, yesterday.day, 20);

  /// Yesterday's 20:00 shift (฿1,234 float), open unless [closed], plus a
  /// ฿100 cash bill rung just now — inside the open shift.
  Future<AppDatabase> seed({required bool closed}) async {
    final db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.shifts)
        .insert(
          ShiftsCompanion.insert(
            id: 'sh-yesterday',
            dateStr: dateKey(yesterday),
            startingCash: 1234,
            openedAt: openedAt,
            closedAt: Value(
              closed ? openedAt.add(const Duration(hours: 3)) : null,
            ),
            isActive: const Value(true),
          ),
        );
    await db
        .into(db.sales)
        .insert(
          SalesCompanion.insert(
            id: 'after-midnight',
            receiptNo: 'RC-AM',
            subtotal: 100,
            total: 100,
            paymentMethod: 'เงินสด',
            date: now,
          ),
        );
    return db;
  }

  Future<void> pump(WidgetTester tester, AppDatabase db, Widget body) async {
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db),
        child: MaterialApp(home: Scaffold(body: body)),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  group('cash-drawer screen', () {
    testWidgets('shows yesterday’s still-open shift with its expected cash', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final db = await seed(closed: false);
        await pump(tester, db, const CashDrawerScreen());

        expect(find.text('ยังไม่ได้เปิดร้านวันนี้'), findsNothing);
        // Opened yesterday: the open time carries its date.
        expect(
          find.text('เปิดร้าน ${thaiDateTime(openedAt)} · ตั้งต้น ฿1,234'),
          findsOneWidget,
        );
        // 1,234 float + 100 cash sale.
        expect(find.textContaining('1,334'), findsWidgets);
        await db.close();
      });
    });

    testWidgets('a closed shift from yesterday is not today’s', (tester) async {
      await tester.runAsync(() async {
        final db = await seed(closed: true);
        await pump(tester, db, const CashDrawerScreen());

        expect(find.text('ยังไม่ได้เปิดร้านวันนี้'), findsOneWidget);
        await db.close();
      });
    });
  });

  group('closing report drawer check', () {
    testWidgets('uses yesterday’s still-open shift', (tester) async {
      await tester.runAsync(() async {
        final db = await seed(closed: false);
        await pump(tester, db, const ClosingReport());

        expect(find.text('เงินตั้งต้น'), findsOneWidget);
        expect(find.text('฿1,234'), findsOneWidget);
        expect(find.text('฿1,334'), findsOneWidget);
        await db.close();
      });
    });

    testWidgets('ignores a closed shift from yesterday', (tester) async {
      await tester.runAsync(() async {
        final db = await seed(closed: true);
        await pump(tester, db, const ClosingReport());

        expect(find.text('เงินตั้งต้น'), findsNothing);
        expect(find.text('฿1,334'), findsNothing);
        await db.close();
      });
    });
  });
}
