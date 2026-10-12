// Supplier-first Suppliers tab (owner 2026-10-12,
// docs/research/supplier-first-plan-2026-10-12.md).
//  • groupSuppliers: one group per trimmed/case-insensitive name, the most used
//    spelling shown, blank names and deleted products left out, cheapest
//    compared in whole satang.
//  • The tab opens on "ตามซัพฯ": search by supplier or by a product's part no,
//    Enter opens the first match, cheapest / dearer wording, edit + add +
//    delete through the existing SuppliersRepository writes.
//  • Degraded: every write button is disabled.
//  • Narrow: list → detail push; Back (system) returns to the list — also
//    through the real router, where "สร้างใบสั่งซื้อ" opens the prefilled PO.
//  • No overflow at whole-screen zoom / 390 px in either mode.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/router/app_router.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/suppliers_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/widgets/low_stock_alert.dart';
import 'package:srisurart_pos/presentation/widgets/supplier_groups.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

import 'support/fake_sync_facade.dart';

ProductRow _p(String id, {int stock = 10, int min = 2, String? name}) =>
    ProductRow(
      id: id,
      partNo: 'PN-$id',
      name: name ?? 'Product $id',
      nameTH: '',
      category: 'x',
      brand: 'x',
      price: 100,
      cost: 50,
      stock: stock,
      minStock: min,
    );

SupplierRow _s(String id, String product, String name, double u, double f) =>
    SupplierRow(
      id: id,
      productId: product,
      name: name,
      unitCost: u,
      freight: f,
    );

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('groupSuppliers', () {
    test('trimmed, case-insensitive; most used spelling; blank and deleted '
        'products skipped', () {
      final groups = groupSuppliers(
        [_p('a'), _p('b'), _p('c')],
        [
          _s('1', 'a', ' auto zone ', 10, 0),
          _s('2', 'b', 'Auto Zone', 10, 0),
          _s('3', 'c', 'Auto Zone', 10, 0),
          _s('4', 'a', '   ', 1, 0), // blank name
          _s('5', 'gone', 'Ghost', 1, 0), // product not live
        ],
      );
      expect(groups, hasLength(1));
      expect(groups.single.name, 'Auto Zone');
      expect(groups.single.key, 'auto zone');
      expect(groups.single.productCount, 3);
    });

    test('a spelling tie goes to the first row', () {
      final g = groupSuppliers(
        [_p('a'), _p('b')],
        [_s('1', 'a', 'ngk ', 1, 0), _s('2', 'b', 'NGK', 1, 0)],
      ).single;
      expect(g.name, 'ngk');
    });

    test('cheapest compares whole satang: 0.1 + 0.2 ties 0.3', () {
      final groups = groupSuppliers(
        [_p('a')],
        [_s('1', 'a', 'X', 0.1, 0.2), _s('2', 'a', 'Y', 0.3, 0)],
      );
      expect(groups.every((g) => g.quotes.single.cheapest), isTrue);
      expect(groups.every((g) => g.cheapestCount == 1), isTrue);
    });

    test('seed p2: NGK 62+3 is cheapest, Spark King 58+8 is 1 dearer', () {
      final groups = groupSuppliers(
        [_p('p2')],
        [
          _s('sup3', 'p2', 'NGK Thailand', 62, 3),
          _s('sup4', 'p2', 'Spark King', 58, 8),
        ],
      );
      final ngk = groups.firstWhere((g) => g.name == 'NGK Thailand');
      final spark = groups.firstWhere((g) => g.name == 'Spark King');
      expect(ngk.quotes.single.cheapest, isTrue);
      expect(spark.quotes.single.cheapest, isFalse);
      expect(spark.quotes.single.overBaht, 1);
      expect(spark.quotes.single.bestName, 'NGK Thailand');
    });

    test('a single quote is not "cheapest"', () {
      final g = groupSuppliers([_p('a')], [_s('1', 'a', 'X', 5, 0)]).single;
      expect(g.quotes.single.cheapest, isFalse);
      expect(g.cheapestCount, 0);
    });

    test('reorder count + order: out, then low, then the rest; needy first',
        () {
      final groups = groupSuppliers(
        [
          _p('ok', name: 'A ok'),
          _p('low', stock: 2, min: 5, name: 'B low'),
          _p('out', stock: 0, name: 'C out'),
          _p('z'),
        ],
        [
          _s('1', 'ok', 'Zed', 1, 0),
          _s('2', 'low', 'Zed', 1, 0),
          _s('3', 'out', 'Zed', 1, 0),
          _s('4', 'z', 'Alpha', 1, 0),
        ],
      );
      expect(groups.map((g) => g.name), ['Zed', 'Alpha']);
      final zed = groups.first;
      expect(zed.reorderCount, 2);
      expect(zed.quotes.map((q) => q.level), [
        StockLevel.out,
        StockLevel.low,
        StockLevel.ok,
      ]);
    });

    test('search matches a product part no, not only the supplier name', () {
      final g = groupSuppliers([_p('a')], [_s('1', 'a', 'X', 1, 0)]).single;
      expect(g.matches('pn-a'), isTrue);
      expect(g.matches(' x '), isTrue);
      expect(g.matches('nope'), isFalse);
    });
  });

  // ── Widgets ────────────────────────────────────────────────────────────────

  Widget providers(AppDatabase db, Widget child, {SyncFacade? sync}) =>
      MultiRepositoryProvider(
        providers: repositoryProviders(
          db,
          useApiRepositories: false,
          syncFacade: sync,
        ),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
            BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
            BlocProvider<CartCubit>(create: (_) => CartCubit()),
            BlocProvider<ThemeModeCubit>(create: (_) => ThemeModeCubit()),
          ],
          child: child,
        ),
      );

  void setSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    }
  }

  Future<void> openTab(
    WidgetTester tester,
    AppDatabase db, {
    double zoom = 1,
    SyncFacade? sync,
  }) async {
    await tester.pumpWidget(
      providers(
        db,
        MaterialApp(
          home: const Scaffold(body: ProductsScreen()),
          builder: (context, child) => UiZoom(zoom: zoom, child: child!),
        ),
        sync: sync,
      ),
    );
    await settle(tester);
    final tab = find.text('ซัพพลายเออร์ · Suppliers');
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await settle(tester);
  }

  Future<void> lowP2(AppDatabase db) =>
      (db.update(db.products)..where((t) => t.id.equals('p2'))).write(
        const ProductsCompanion(stock: Value(3)),
      );

  testWidgets('opens supplier-first; search by part no; Enter opens it; '
      'cheapest and dearer wording', (tester) async {
    setSize(tester, const Size(1280, 900));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await openTab(tester, db);
      expect(find.byKey(const Key('suppliers-group-list')), findsOneWidget);
      for (final n in ['Honda Parts Center', 'Auto Zone TH', 'NGK Thailand']) {
        expect(find.byKey(ValueKey('supplier-${n.toLowerCase()}')), findsOne);
      }

      await tester.enterText(
        find.byKey(const Key('suppliers-search')),
        'ngk-br8es',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('supplier-ngk thailand')), findsOne);
      expect(find.byKey(const ValueKey('supplier-spark king')), findsOne);
      expect(find.byKey(const ValueKey('supplier-auto zone th')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('supplier-spark king')));
      await tester.pumpAndSettle();
      final detail = find.byKey(const Key('supplier-detail'));
      expect(
        find.descendant(
          of: detail,
          matching: find.text('แพงกว่า ฿1 · ถูกสุด NGK Thailand'),
        ),
        findsOne,
      );

      // Enter opens the first match (the list is in name order: NGK first).
      await tester.enterText(
        find.byKey(const Key('suppliers-search')),
        'ngk thai',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: detail, matching: find.text('NGK Thailand')),
        findsOne,
      );
      // Legend + the row's pill.
      expect(
        find.descendant(of: detail, matching: find.text('✓ ราคาถูกสุด')),
        findsNWidgets(2),
      );
      await db.close();
    });
  });

  testWidgets('edit cost, add a product, delete a row — through the repository',
      (tester) async {
    setSize(tester, const Size(1280, 900));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await openTab(tester, db);
      await tester.tap(find.byKey(const ValueKey('supplier-ngk thailand')));
      await tester.pumpAndSettle();

      // Edit: 62 + 3 → 70 + 3.
      await tester.tap(find.byTooltip('แก้ราคา'));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('edit-quote-cost')), '70');
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-quote-save')));
      await settle(tester);
      final repo = SuppliersRepository(db);
      final ngk = (await repo.getSuppliersForProduct('p2'))
          .firstWhere((s) => s.name == 'NGK Thailand');
      expect(ngk.unitCost, 70);
      expect(ngk.freight, 3);
      expect(find.text('฿73'), findsOne);

      // Add: p2 is already quoted, so searching its part no finds nothing.
      await tester.tap(find.byKey(const Key('supplier-add-product')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('add-quote-find')),
        'NGK-BR8ES',
      );
      await tester.pump();
      expect(find.text('ไม่พบสินค้า'), findsOne);
      await tester.enterText(find.byKey(const Key('add-quote-find')), 'oil f');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(find.byKey(const Key('add-quote-cost')), '40');
      await tester.enterText(find.byKey(const Key('add-quote-freight')), '2');
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-quote-save')));
      await settle(tester);
      final p1 = await repo.getSuppliersForProduct('p1');
      final added = p1.firstWhere((s) => s.name == 'NGK Thailand');
      expect(added.unitCost, 40);
      expect(added.freight, 2);
      expect(find.text('Oil Filter'), findsOne);

      // Delete the new row.
      final row = find.ancestor(
        of: find.text('Oil Filter'),
        matching: find.byType(DataTable),
      );
      expect(row, findsOne);
      final deletes = find.byTooltip('ลบ');
      expect(deletes, findsNWidgets(2));
      // Rows: Oil Filter first by name ("Oil…" < "Spark…").
      await tester.tap(deletes.first);
      await settle(tester);
      expect(
        (await repo.getSuppliersForProduct('p1'))
            .where((s) => s.name == 'NGK Thailand'),
        isEmpty,
      );
      expect(find.text('Oil Filter'), findsNothing);
      await db.close();
    });
  });

  testWidgets('new supplier: name is trimmed, then it is selected',
      (tester) async {
    setSize(tester, const Size(1280, 900));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await openTab(tester, db);
      await tester.tap(find.byKey(const Key('supplier-new')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('add-quote-name')),
        '  ร้านใหม่  ',
      );
      await tester.enterText(find.byKey(const Key('add-quote-find')), 'chain');
      await tester.pump();
      await tester.tap(find.text('Drive Chain #520').last);
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-quote-save')));
      await settle(tester);
      final rows = await SuppliersRepository(db).getSuppliersForProduct('p3');
      expect(rows.single.name, 'ร้านใหม่');
      expect(
        find.descendant(
          of: find.byKey(const Key('supplier-detail')),
          matching: find.text('ร้านใหม่'),
        ),
        findsOne,
      );
      await db.close();
    });
  });

  testWidgets('Degraded: every supplier write button is disabled',
      (tester) async {
    setSize(tester, const Size(1280, 900));
    final db = AppDatabase(NativeDatabase.memory());
    final sync = FakeSyncFacade(initialStatus: SyncStatus.degraded);
    await tester.runAsync(() async {
      await openTab(tester, db, sync: sync);
      bool enabled(Finder f) =>
          tester.widget<ButtonStyleButton>(f).onPressed != null;
      expect(
        enabled(find.byKey(const Key('supplier-create-po'))),
        isFalse,
      );
      expect(
        enabled(find.byKey(const Key('supplier-add-product'))),
        isFalse,
      );
      expect(enabled(find.byKey(const Key('supplier-new'))), isFalse);
      for (final tip in ['แก้ราคา', 'ลบ']) {
        for (final e in tester.widgetList<IconButton>(
          find.ancestor(
            of: find.byTooltip(tip),
            matching: find.byType(IconButton),
          ),
        )) {
          expect(e.onPressed, isNull, reason: tip);
        }
      }
      await db.close();
    });
  });

  testWidgets('390 px: list → detail push; system Back returns to the list',
      (tester) async {
    setSize(tester, const Size(390, 844));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await lowP2(db);
      await openTab(tester, db);
      expect(find.byKey(const Key('supplier-detail')), findsNothing);
      // Needy first: NGK Thailand and Spark King quote the low p2.
      await tester.tap(find.byKey(const ValueKey('supplier-ngk thailand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supplier-detail')), findsOne);
      expect(find.byType(DataTable), findsNothing); // cards on a phone
      expect(find.text('ใกล้หมด'), findsOne);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supplier-detail')), findsNothing);
      expect(find.byKey(const Key('suppliers-group-list')), findsOne);
      // The on-screen back button does the same.
      await tester.tap(find.byKey(const ValueKey('supplier-spark king')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('supplier-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supplier-detail')), findsNothing);
      await db.close();
    });
  });

  testWidgets('real router: Back closes the detail, then "สร้างใบสั่งซื้อ" '
      'opens the PO dialog with the supplier and its low-stock line',
      (tester) async {
    setSize(tester, const Size(390, 844));
    final db = AppDatabase(NativeDatabase.memory());
    final router = buildAppRouter(initialLocation: AppRoutes.products);
    addTearDown(router.dispose);
    await tester.runAsync(() async {
      await lowP2(db);
      await tester.pumpWidget(
        providers(db, MaterialApp.router(routerConfig: router)),
      );
      await settle(tester);
      final tab = find.text('ซัพพลายเออร์ · Suppliers');
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('supplier-ngk thailand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supplier-detail')), findsOne);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supplier-detail')), findsNothing);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        AppRoutes.products,
      );

      await tester.tap(find.byKey(const ValueKey('supplier-ngk thailand')));
      await tester.pumpAndSettle();
      final po = find.byKey(const Key('supplier-create-po'));
      await tester.ensureVisible(po);
      await tester.pumpAndSettle();
      await tester.tap(po);
      await settle(tester);
      await settle(tester);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        AppRoutes.purchaseOrders,
      );
      final dialog = find.byType(Dialog);
      expect(dialog, findsOne);
      expect(
        find.descendant(of: dialog, matching: find.text('NGK Thailand')),
        findsWidgets,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('Spark Plug NGK')),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await db.close();
    });
  });

  // Whole-screen zoom / phone: the supplier list, an open supplier, and the
  // "ตามสินค้า" view must lay out without an exception. 3x on 1920 is 640
  // logical px — under the 840 master/detail width — so it takes the push
  // layout; 1280 is the master/detail layout.
  for (final (label, size, zoom) in const [
    ('tablet', Size(1280, 800), 1.0),
    ('zoom3x-fullhd', Size(1920, 1080), 3.0),
    ('zoom2x-laptop', Size(1366, 768), 2.0),
    ('zoom3x-laptop', Size(1366, 768), 3.0),
    ('phone390', Size(390, 844), 1.0),
  ]) {
    testWidgets('supplier tab, both modes, at $label', (tester) async {
      setSize(tester, size);
      final db = AppDatabase(NativeDatabase.memory());
      final errors = <Object>[];
      void grab() {
        final e = tester.takeException();
        if (e != null) errors.add(e);
      }

      await tester.runAsync(() async {
        await lowP2(db);
        await openTab(tester, db, zoom: zoom);
        grab();
        final logicalWidth = size.width / zoom;
        final split = logicalWidth >= 840;
        // Master/detail shows the first (needy) supplier at once.
        expect(
          find.byKey(const Key('supplier-detail')),
          split ? findsOne : findsNothing,
        );
        final ngk = find.byKey(const ValueKey('supplier-ngk thailand'));
        await tester.ensureVisible(ngk);
        await tester.pumpAndSettle();
        await tester.tap(ngk);
        await tester.pumpAndSettle();
        grab();
        expect(find.byKey(const Key('supplier-detail')), findsOne);
        // Scroll the detail to its end: every card/row lays out.
        await tester.drag(
          find.byKey(const Key('supplier-detail')),
          const Offset(0, -2000),
        );
        await tester.pumpAndSettle();
        grab();

        if (!split) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        final byProduct = find.text('ตามสินค้า');
        await tester.ensureVisible(byProduct);
        await tester.pumpAndSettle();
        await tester.tap(byProduct);
        await tester.pumpAndSettle();
        grab();
        expect(find.byKey(const Key('suppliers-product-list')), findsOne);
        await db.close();
      });
      expect(errors, isEmpty, reason: 'supplier tab threw at $label');
    });
  }
}
