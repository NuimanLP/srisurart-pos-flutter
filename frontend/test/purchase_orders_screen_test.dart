// PurchaseOrdersScreen UX fixes: a received PO has no delete button (the server
// refuses it), a failing delete/cancel/receive shows its message instead of
// vanishing silently, and a create-dialog search with no match says ไม่พบสินค้า.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/screens/purchase_orders_screen.dart';

class _FailingPoRepo extends PurchaseOrdersRepository {
  _FailingPoRepo(super.db);

  @override
  Future<void> deletePO(String id) async =>
      throw const PosException('PO_ALREADY_RECEIVED', 'ลบไม่ได้: ข้อความทดสอบ');

  @override
  Future<void> cancelPO(String id) async =>
      throw const PosException('X', 'ยกเลิกไม่ได้: ข้อความทดสอบ');

  @override
  Future<List<String>> receivePO(String id) async =>
      throw const PosException('X', 'รับไม่ได้: ข้อความทดสอบ');
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pump(
    WidgetTester tester,
    AppDatabase db,
    PurchaseOrdersRepository po,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PurchaseOrdersRepository>.value(value: po),
          RepositoryProvider<ProductsRepository>.value(
            value: ProductsRepository(db),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: PurchaseOrdersScreen())),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  const input = PoInput(
    supplier: 'ซัพทดสอบ',
    items: [PoLineInput(partNo: 'ZZ-NONE', name: 'x', qty: 1, cost: 10)],
  );

  testWidgets('received PO has no delete button; open PO keeps it', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final repo = PurchaseOrdersRepository(db);
      final a = await repo.savePO(input);
      await repo.receivePO(a.id);
      await repo.savePO(input);
      await pump(tester, db, repo);
      expect(find.byTooltip('ลบถาวร'), findsOneWidget); // only the open PO
    });
  });

  for (final c in const [
    ('ลบถาวร', 'ลบไม่ได้: ข้อความทดสอบ'),
    ('ยกเลิก', 'ยกเลิกไม่ได้: ข้อความทดสอบ'),
    ('รับสินค้า', 'รับไม่ได้: ข้อความทดสอบ'),
  ]) {
    testWidgets('failing ${c.$1} shows the error message', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() async {
        await PurchaseOrdersRepository(db).savePO(input);
        await pump(tester, db, _FailingPoRepo(db));
        final trigger = c.$1 == 'ลบถาวร'
            ? find.byTooltip('ลบถาวร')
            : find.text(c.$1);
        await tester.tap(trigger);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await settle(tester);
        final confirm = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        );
        await tester.tap(confirm.last);
        await settle(tester);
        expect(find.text(c.$2), findsOneWidget);
      });
    });
  }

  testWidgets('create dialog: no-match search shows ไม่พบสินค้า', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      await pump(tester, db, PurchaseOrdersRepository(db));
      await tester.tap(find.text('สร้างใบสั่งซื้อ'));
      await settle(tester);
      expect(find.text('ไม่พบสินค้า'), findsNothing);
      await tester.enterText(find.byType(TextField).last, 'zzzz-no-such');
      await settle(tester);
      expect(find.text('ไม่พบสินค้า'), findsOneWidget);
    });
  });
}
