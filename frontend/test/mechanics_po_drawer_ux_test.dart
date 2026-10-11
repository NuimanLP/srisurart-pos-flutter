// UI/UX pass 2026-10-11 (group E): the presentation-only cues added to the
// mechanics, purchase-order and cash-drawer screens, at phone width (390) and
// on a desktop — no overflow, and each cue says what it is meant to say.

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
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';
import 'package:srisurart_pos/presentation/screens/purchase_orders_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  Future<void> pump(
    WidgetTester tester,
    AppDatabase db,
    Widget screen,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db, useApiRepositories: false),
        child: MaterialApp(home: Scaffold(body: screen)),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> overLimit(AppDatabase db) =>
      (db.update(db.mechanics)..where((t) => t.id.equals('m1'))).write(
        const MechanicsCompanion(creditBalance: Value(6000)),
      );

  testWidgets('mechanics at 390: two-line rows, no table headings, '
      'over-limit amount on the detail, over-collection warned', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await overLimit(db);
      await pump(tester, db, const MechanicsScreen(), const Size(390, 844));
      expect(tester.takeException(), isNull);
      expect(find.text('ยอดซื้อ'), findsNothing); // compact: no headings

      await tester.tap(
        find.textContaining('ลุงมานพ', findRichText: true).first,
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('เกินวงเงิน ฿1,000'), findsOneWidget);

      await tester.tap(find.text('รับชำระ'));
      await tester.pumpAndSettle();
      final amount = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first;
      await tester.enterText(amount, '6500');
      await tester.pump();
      expect(find.text('รับเกินยอดค้าง ฿500'), findsOneWidget);
      // The quick chips set the amount; they no longer read "+฿…".
      expect(find.textContaining('+฿'), findsNothing);
      expect(tester.takeException(), isNull);
      await db.close();
    });
  });

  testWidgets('mechanics on a desktop: the table has column headings', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await pump(tester, db, const MechanicsScreen(), const Size(1600, 900));
      expect(tester.takeException(), isNull);
      expect(find.text('ยอดซื้อ'), findsOneWidget);
      expect(find.text('ยอดค้าง'), findsOneWidget);
      await db.close();
    });
  });

  testWidgets('cash drawer at 390: the close button says why it is disabled', (
    tester,
  ) async {
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
      await pump(tester, db, const CashDrawerScreen(), const Size(390, 844));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('🔒 ปิดลิ้นชัก'));
      await tester.pumpAndSettle();
      const why = 'กรอกยอดเงินที่นับได้ก่อน จึงจะปิดลิ้นชักได้';
      expect(find.text(why), findsOneWidget);

      await tester.enterText(find.byType(TextField), '900');
      await tester.pump();
      expect(find.text(why), findsNothing);
      expect(find.text('เงินขาด −฿100'), findsOneWidget);
      expect(
        find.text('นับได้น้อยกว่ายอดที่ควรมี — ลองนับใหม่อีกครั้ง'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await db.close();
    });
  });

  testWidgets('PO card at 390 lists its items on demand', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await PurchaseOrdersRepository(db).savePO(
        const PoInput(
          supplier: 'ซัพทดสอบ',
          items: [
            PoLineInput(partNo: 'ZZ-1', name: 'ไส้กรองทดสอบ', qty: 3, cost: 10),
          ],
        ),
      );
      await pump(
        tester,
        db,
        const PurchaseOrdersScreen(),
        const Size(390, 844),
      );
      expect(find.text('ไส้กรองทดสอบ'), findsNothing); // collapsed
      await tester.tap(find.text('ดูรายการสินค้า'));
      await tester.pumpAndSettle();
      expect(find.text('ไส้กรองทดสอบ'), findsOneWidget);
      expect(find.text('3 × ฿10'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await db.close();
    });
  });
}
