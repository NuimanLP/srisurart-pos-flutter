// PurchaseOrdersScreen UX fixes: a received PO has no delete button (the server
// refuses it), a failing delete/cancel/receive shows its message instead of
// vanishing silently, and a create-dialog search with no match says ไม่พบสินค้า.
// Create dialog: supplier search-as-you-type, the picked supplier's products
// priced from its quote, Enter adds the first match, phone/desktop layout.

import 'package:drift/drift.dart' show Value;
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
import 'package:srisurart_pos/data/repositories/suppliers_repository.dart';
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
    PurchaseOrdersRepository po, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
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
          RepositoryProvider<SuppliersRepository>.value(
            value: SuppliersRepository(db),
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

  Finder dialogText(String t) =>
      find.descendant(of: find.byType(Dialog), matching: find.text(t));

  Future<void> openCreate(WidgetTester tester) async {
    await tester.tap(find.text('สร้างใบสั่งซื้อ'));
    await settle(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('บันทึกใบสั่งซื้อ'));
    await settle(tester);
  }

  testWidgets('create dialog: "jin" suggests Jin Seng Huat; its products use '
      'the supplier unit cost', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final product = (await ProductsRepository(db).getAll()).first;
      await SuppliersRepository(db).addSupplier(
        productId: product.id,
        name: 'Jin Seng Huat',
        unitCost: 123,
      );
      final repo = PurchaseOrdersRepository(db);
      await pump(tester, db, repo);
      await openCreate(tester);

      await tester.enterText(find.byType(TextField).first, 'jin');
      await settle(tester);
      expect(dialogText('Jin Seng Huat'), findsOneWidget);

      await tester.tap(dialogText('Jin Seng Huat'));
      await settle(tester);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'Jin Seng Huat');
      expect(dialogText('สินค้าของซัพพลายเออร์นี้'), findsOneWidget);

      await tester.tap(dialogText(product.name));
      await settle(tester);
      await save(tester);

      final saved = (await repo.getPOs()).single;
      expect(saved.po.supplier, 'Jin Seng Huat');
      expect(saved.items.single.partNo, product.partNo);
      expect(saved.items.single.cost, 123);
    });
  });

  testWidgets('create dialog: unknown supplier saves as free text; Enter in '
      'the item search adds the exact part, not a longer one listed first', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final products = await ProductsRepository(db).getAll();
      // products[0] is listed first and its partNo contains the typed one.
      await setProduct(db, products[0].id, partNo: 'EXACT-1-LONG');
      await setProduct(db, products[1].id, partNo: 'EXACT-1');
      final repo = PurchaseOrdersRepository(db);
      await pump(tester, db, repo);
      await openCreate(tester);
      expect(
        dialogText('เลือกซัพพลายเออร์และเพิ่มสินค้าอย่างน้อย 1 รายการ'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField).first, 'ร้านใหม่ทดสอบ');
      await settle(tester);
      expect(
        dialogText('ไม่พบซัพพลายเออร์นี้ — จะบันทึกเป็นซัพพลายเออร์ใหม่'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField).at(1), 'exact-1');
      await settle(tester);
      // The longer part is the first listed suggestion...
      final tiles = find.descendant(
        of: find.byType(Dialog),
        matching: find.textContaining('EXACT-1'),
      );
      expect(tester.widget<Text>(tiles.first).data, 'EXACT-1-LONG');
      // ...but Enter adds the exact one.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await save(tester);

      final saved = (await repo.getPOs()).single;
      expect(saved.po.supplier, 'ร้านใหม่ทดสอบ');
      expect(saved.items.single.partNo, 'EXACT-1');
      expect(saved.items.single.cost, products[1].cost);
    });
  });

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    testWidgets('create dialog lays out at ${size.width.toInt()}x'
        '${size.height.toInt()}', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() async {
        await PurchaseOrdersRepository(db).savePO(input);
        final low = (await ProductsRepository(db).getAll())[1];
        await setProduct(db, low.id, stock: 0, minStock: 5);
        await SuppliersRepository(
          db,
        ).addSupplier(productId: low.id, name: 'ซัพทดสอบ', unitCost: 10);
        await pump(tester, db, PurchaseOrdersRepository(db), size: size);
        await openCreate(tester);
        // Focus the empty supplier field: every known supplier is listed.
        await tester.tap(find.byType(TextField).first);
        await settle(tester);
        expect(dialogText('ซัพทดสอบ'), findsOneWidget);
        await tester.tap(dialogText('ซัพทดสอบ'));
        await settle(tester);
        // A draft line: the narrow (<440) stacked row layout at 390.
        final product = (await ProductsRepository(db).getAll()).first;
        await tester.enterText(find.byType(TextField).at(1), product.partNo);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
        expect(dialogText(product.name), findsOneWidget);
        await tester.tap(find.textContaining('เพิ่มสินค้าสต็อกต่ำ'));
        await settle(tester);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('low-stock button: absent for an unknown supplier; for a known '
      'one adds only its low-stock products not yet in the draft, qty = '
      'max(1, minStock - stock)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final ps = await ProductsRepository(db).getAll();
      final a = ps[0], b = ps[1], c = ps[2], d = ps[3];
      await setProduct(db, a.id, stock: 1, minStock: 5); // low → qty 4
      await setProduct(db, b.id, stock: 3, minStock: 3); // low → qty 1
      await setProduct(db, c.id, stock: 10, minStock: 2); // not low
      await setProduct(db, d.id, stock: 0, minStock: 5); // low, other supplier
      final sup = SuppliersRepository(db);
      for (final p in [a, b, c]) {
        await sup.addSupplier(productId: p.id, name: 'Alpha', unitCost: 1);
      }
      final repo = PurchaseOrdersRepository(db);
      await pump(tester, db, repo);
      await openCreate(tester);
      final lowBtn = find.textContaining('เพิ่มสินค้าสต็อกต่ำ');

      await tester.enterText(find.byType(TextField).first, 'ร้านใหม่ทดสอบ');
      await settle(tester);
      expect(lowBtn, findsNothing);

      await tester.enterText(find.byType(TextField).first, 'Alpha');
      await settle(tester);
      expect(dialogText('เพิ่มสินค้าสต็อกต่ำ (2 รายการ)'), findsOneWidget);
      await tester.tap(dialogText(b.name)); // b already in the draft
      await settle(tester);
      expect(dialogText('เพิ่มสินค้าสต็อกต่ำ (1 รายการ)'), findsOneWidget);
      await tester.tap(lowBtn);
      await settle(tester);
      expect(lowBtn, findsNothing);
      await save(tester);

      final items = {
        for (final i in (await repo.getPOs()).single.items) i.partNo: i.qty,
      };
      expect(items, {b.partNo: 1, a.partNo: 4});
    });
  });

  testWidgets('supplier list: deduped case/space-insensitively, past PO '
      'suppliers first (newest first)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final repo = PurchaseOrdersRepository(db);
      PoInput po(String s) => PoInput(supplier: s, items: input.items);
      await repo.savePO(po('Zeta Old'));
      // createdAt is stored at whole-second precision.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await repo.savePO(po('Zeta New'));
      final product = (await ProductsRepository(db).getAll()).first;
      final sup = SuppliersRepository(db);
      await sup.addSupplier(
        productId: product.id,
        name: 'Zeta Quote',
        unitCost: 1,
      );
      await sup.addSupplier(
        productId: product.id,
        name: '  zeta new ',
        unitCost: 1,
      );
      await pump(tester, db, repo);
      await openCreate(tester);
      await tester.enterText(find.byType(TextField).first, 'zeta');
      await settle(tester);

      expect(dialogText('Zeta New'), findsOneWidget);
      expect(find.textContaining('zeta new'), findsNothing);
      double y(String t) => tester.getTopLeft(dialogText(t)).dy;
      expect(y('Zeta New'), lessThan(y('Zeta Old')));
      expect(y('Zeta Old'), lessThan(y('Zeta Quote')));
    });
  });

  testWidgets('Thai supplier name is found by typing its start', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final product = (await ProductsRepository(db).getAll()).first;
      await SuppliersRepository(db).addSupplier(
        productId: product.id,
        name: 'จิ้นเซ่งฮวดอะไหล่ยนต์',
        unitCost: 1,
      );
      await pump(tester, db, PurchaseOrdersRepository(db));
      await openCreate(tester);
      await tester.enterText(find.byType(TextField).first, 'จิ้น');
      await settle(tester);
      expect(dialogText('จิ้นเซ่งฮวดอะไหล่ยนต์'), findsOneWidget);
    });
  });

  testWidgets('supplier change re-prices unedited lines only (lowest quote '
      'wins)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final ps = await ProductsRepository(db).getAll();
      final p = ps[0], r = ps[1], q = ps[2];
      final sup = SuppliersRepository(db);
      await sup.addSupplier(productId: p.id, name: 'Alpha', unitCost: 50);
      await sup.addSupplier(productId: p.id, name: 'Alpha', unitCost: 45);
      await sup.addSupplier(productId: r.id, name: 'Alpha', unitCost: 40);
      await sup.addSupplier(productId: p.id, name: 'Beta', unitCost: 70);
      await sup.addSupplier(productId: r.id, name: 'Beta', unitCost: 90);
      final repo = PurchaseOrdersRepository(db);
      await pump(tester, db, repo);
      await openCreate(tester);

      await tester.enterText(find.byType(TextField).first, 'Alpha');
      await settle(tester);
      await tester.tap(dialogText(p.name)); // 45 (lowest Alpha quote)
      await settle(tester);
      await tester.tap(dialogText(r.name)); // 40
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), q.partNo);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester); // q: no quote → product cost
      // Fields: supplier, search, then qty/cost per line (p, r, q).
      await tester.enterText(find.byType(TextField).at(5), '99'); // r edited
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'Beta');
      await settle(tester);
      await save(tester);

      final cost = {
        for (final i in (await repo.getPOs()).single.items) i.partNo: i.cost,
      };
      expect(cost, {p.partNo: 70, r.partNo: 99, q.partNo: q.cost});
    });
  });
}

Future<void> setProduct(
  AppDatabase db,
  String id, {
  String? partNo,
  int? stock,
  int? minStock,
}) => (db.update(db.products)..where((t) => t.id.equals(id))).write(
  ProductsCompanion(
    partNo: partNo == null ? const Value.absent() : Value(partNo),
    stock: stock == null ? const Value.absent() : Value(stock),
    minStock: minStock == null ? const Value.absent() : Value(minStock),
  ),
);
