// Cash-out category chips + the monthly "เงินสดออกไปไหน" popup on the
// cash-drawer screen (owner 2026-10-23). The entries are saved through the
// real Drift ShiftsRepository; the popup reads them back the same way.

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/reports/drawer_expense.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/widgets/drawer_expense_summary.dart';
import 'package:srisurart_pos/presentation/widgets/thai_format.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pump(
    WidgetTester tester,
    AppDatabase db, {
    Size size = const Size(1400, 1000),
    double zoom = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db, useApiRepositories: false),
        child: MaterialApp(
          home: const Scaffold(body: CashDrawerScreen()),
          builder: (context, child) => UiZoom(zoom: zoom, child: child!),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> openShift(AppDatabase db, String id, DateTime at) => db
      .into(db.shifts)
      .insert(
        ShiftsCompanion.insert(
          id: id,
          dateStr: dateKey(at),
          startingCash: 5000,
          openedAt: at,
          isActive: Value(dateKey(at) == todayKey()),
        ),
      );

  Future<List<DrawerEntryRow>> saved(AppDatabase db) => (db.select(
    db.drawerEntries,
  )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  TextField field(WidgetTester tester, int i) =>
      tester.widget<TextField>(find.byType(TextField).at(i));

  Future<void> add(WidgetTester tester) async {
    await tester.tap(find.text('+ เพิ่ม'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testWidgets('a chip writes the standard prefix; the entry is saved through '
      'the repository with that note', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      await openShift(db, 'sh-today', DateTime.now());
      await pump(tester, db);

      for (final c in expenseCategories) {
        expect(find.text(c), findsOneWidget, reason: 'chip $c');
      }

      // Chip on an empty note, nothing typed after it.
      await tester.tap(find.text('ค่าไฟ'));
      await tester.pump();
      expect(field(tester, 1).controller!.text, 'ค่าไฟ: ');
      await tester.enterText(find.byType(TextField).at(0), '450');
      await add(tester);

      // Free text first, then a chip; a second chip replaces the first.
      await tester.enterText(find.byType(TextField).at(1), 'นาย ก');
      await tester.tap(find.text('ค่าน้ำ').first);
      await tester.pump();
      await tester.tap(find.text('ค่าแรง').first);
      await tester.pump();
      expect(field(tester, 1).controller!.text, 'ค่าแรง: นาย ก');
      await tester.enterText(find.byType(TextField).at(0), '3000');
      await add(tester);

      // No chip: the note is saved exactly as typed (as before).
      await tester.enterText(find.byType(TextField).at(1), 'เติมทอน ');
      await tester.enterText(find.byType(TextField).at(0), '20');
      await add(tester);
      // No chip, but typed with a prefix: still byte for byte (the chip used
      // for the earlier entry does not carry over).
      await tester.enterText(find.byType(TextField).at(1), 'ค่าไฟ:abc ');
      await tester.enterText(find.byType(TextField).at(0), '30');
      await add(tester);

      final rows = await saved(db);
      expect(
        [for (final r in rows) (r.type, r.amount, r.note)],
        [
          ('out', 450.0, 'ค่าไฟ'),
          ('out', 3000.0, 'ค่าแรง: นาย ก'),
          ('out', 20.0, 'เติมทอน '),
          ('out', 30.0, 'ค่าไฟ:abc '),
        ],
      );
      expect(rows.every((r) => r.shiftId == 'sh-today'), isTrue);
    });
  });

  testWidgets('chips are for cash-out only', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      await openShift(db, 'sh-today', DateTime.now());
      await pump(tester, db);
      await tester.tap(find.text('ค่าไฟ'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), 'ค่าไฟ: บิล ต.ค.');
      await tester.tap(find.text('💰 เงินเข้า'));
      await tester.pump();
      for (final c in expenseCategories) {
        expect(find.text(c), findsNothing, reason: 'chip $c');
      }
      // Leaving เงินออก drops the chip's prefix, keeps the free text.
      expect(field(tester, 1).controller!.text, 'บิล ต.ค.');

      // A cash-in typed with a prefix is saved as typed.
      await tester.enterText(find.byType(TextField).at(1), 'ค่าไฟ: ');
      await tester.enterText(find.byType(TextField).at(0), '100');
      await add(tester);
      final rows = await saved(db);
      expect([for (final r in rows) (r.type, r.note)], [('in', 'ค่าไฟ: ')]);

      await tester.tap(find.text('💸 เงินออก'));
      await tester.pump();
      expect(find.text('ค่าน้ำ'), findsOneWidget);
    });
  });

  /// This month: 3 outs (one blank) + 1 in on today's shift; last month one
  /// out on an archived shift.
  Future<void> seedMonths(AppDatabase db) async {
    final now = DateTime.now();
    final lastMonth = DateTime(now.year, now.month - 1, 15, 9);
    await openShift(db, 'sh-old', lastMonth);
    await openShift(db, 'sh-today', now);
    var n = 0;
    Future<void> entry(
      String shift,
      String type,
      double amt,
      String note,
      DateTime at,
    ) => db
        .into(db.drawerEntries)
        .insert(
          DrawerEntryRow(
            id: 'e${n++}',
            shiftId: shift,
            type: type,
            amount: amt,
            note: note,
            createdAt: at,
          ),
        );
    await entry('sh-old', 'out', 777, 'ค่าไฟ', lastMonth);
    await entry('sh-today', 'out', 450, 'ค่าไฟ', now);
    await entry('sh-today', 'out', 3000, 'ค่าแรง: นาย ก', now);
    await entry('sh-today', 'out', 33.5, '', now);
    await entry('sh-today', 'in', 2000, 'เติมทอน', now);
  }

  for (final (label, size, zoom) in const [
    ('desktop', Size(1400, 1000), 1.0),
    ('phone 390', Size(390, 844), 1.0),
    ('zoom 3x full HD', Size(1920, 1080), 3.0),
    ('zoom 2x laptop', Size(1366, 768), 2.0),
  ]) {
    testWidgets('เงินสดออกไปไหน: totals per category and month, $label', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() async {
        await seedMonths(db);
        await pump(tester, db, size: size, zoom: zoom);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.text('🧾 เงินสดออกไปไหน'));
        await tester.tap(find.text('🧾 เงินสดออกไปไหน'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);

        final dialog = find.byType(DrawerExpenseSummaryView);
        Finder inDialog(String t) =>
            find.descendant(of: dialog, matching: find.text(t));
        final now = DateTime.now();
        expect(inDialog(thaiMonthYear(now)), findsOneWidget);
        expect(inDialog('ค่าไฟ'), findsOneWidget);
        expect(inDialog('฿450'), findsOneWidget);
        expect(inDialog('ค่าแรง'), findsOneWidget);
        expect(inDialog('฿3,000'), findsOneWidget);
        expect(inDialog(blankNoteGroup), findsOneWidget);
        expect(inDialog('฿33.5'), findsOneWidget);
        // The cash-in is not counted: 450 + 3000 + 33.5.
        expect(inDialog('รวมเงินออกทั้งเดือน'), findsOneWidget);
        expect(inDialog('฿3,483.5'), findsOneWidget);
        expect(inDialog('3 รายการ'), findsOneWidget);
        expect(inDialog('฿777'), findsNothing);

        await tester.tap(find.byTooltip('เดือนก่อน'));
        await tester.pumpAndSettle();
        expect(
          inDialog(thaiMonthYear(DateTime(now.year, now.month - 1))),
          findsOneWidget,
        );
        expect(inDialog('฿777'), findsNWidgets(2)); // ค่าไฟ row + total
        expect(inDialog('฿450'), findsNothing);

        await tester.tap(find.byTooltip('เดือนก่อน'));
        await tester.pumpAndSettle();
        expect(inDialog('ไม่มีรายการเงินออกในเดือนนี้'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('the popup opens with no shift at all', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      await pump(tester, db, size: const Size(390, 844));
      await tester.tap(find.text('🧾 เงินสดออกไปไหน'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('ไม่มีรายการเงินออกในเดือนนี้'), findsOneWidget);
      // The current month is the latest one offered.
      final next = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_right),
          matching: find.byType(IconButton),
        ),
      );
      expect(next.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
