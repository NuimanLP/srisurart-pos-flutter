// #463 — Reports KPI cards were blank at 390px width: a fixed `childAspectRatio`
// on the 2-column narrow grid squeezed `_StatCard` below the height its
// FittedBox-wrapped value/label content needed, scaling the text down to
// near-zero instead of overflowing visibly. Fixed by giving the narrow grid a
// fixed `mainAxisExtent` instead (reports_screen.dart `_KpiRow.build`).
//
// This test seeds two sales so the four KPI values are distinct, renders
// ReportsScreen at exactly 390 logical px wide, and asserts each KPI value
// Text is laid out with a real (non-near-zero) rendered size — the failure
// mode before the fix was a technically-nonzero but visually-invisible size.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/presentation/screens/reports_screen.dart';

void main() {
  late AppDatabase db;

  setUpAll(() async {
    await initializeDateFormatting('th', null);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    // Two sales today so netRevenue/avgTicket/transactions/items are four
    // distinct values (200 / 100 / 2 / 3) — easy to locate unambiguously.
    await db.into(db.sales).insert(
          SalesCompanion.insert(
            id: 's1',
            receiptNo: 'RC1',
            subtotal: 150,
            total: 150,
            paymentMethod: 'เงินสด',
            date: now,
          ),
        );
    await db.into(db.saleItems).insert(
          SaleItemsCompanion.insert(
            saleId: 's1',
            productId: 'p1',
            partNo: const Value('X1'),
            name: 'สินค้า 1',
            qty: 2,
            price: 75,
          ),
        );
    await db.into(db.sales).insert(
          SalesCompanion.insert(
            id: 's2',
            receiptNo: 'RC2',
            subtotal: 50,
            total: 50,
            paymentMethod: 'เงินสด',
            date: now,
          ),
        );
    await db.into(db.saleItems).insert(
          SaleItemsCompanion.insert(
            saleId: 's2',
            productId: 'p2',
            partNo: const Value('X2'),
            name: 'สินค้า 2',
            qty: 1,
            price: 50,
          ),
        );
  });

  tearDown(() async => db.close());

  Future<void> pumpReports(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SalesRepository>(create: (_) => SalesRepository(db)),
          RepositoryProvider<ReturnsRepository>(create: (_) => ReturnsRepository(db)),
          RepositoryProvider<ProductsRepository>(create: (_) => ProductsRepository(db)),
        ],
        child: const MaterialApp(home: ReportsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Fails the same way the bug did: a value rendered at a few-px-tall size is
  /// technically non-zero but visually blank. Real KPI text at this viewport
  /// comfortably clears this bar; the pre-fix layout did not.
  void expectVisiblyLaidOut(WidgetTester tester, Finder finder) {
    expect(finder, findsOneWidget);
    final size = tester.getSize(finder);
    expect(size.width, greaterThan(0));
    expect(
      size.height,
      greaterThan(10),
      reason: 'KPI value text height regressed toward the invisible-but-nonzero size from #463',
    );
  }

  testWidgets('KPI values stay visible at 390px width (#463)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await pumpReports(tester);

    // Labels are always present regardless of layout.
    expect(find.text('รายได้สุทธิ'), findsOneWidget);
    expect(find.text('จำนวนบิล'), findsOneWidget);
    expect(find.text('ยอดเฉลี่ย/บิล'), findsOneWidget);
    expect(find.text('ชิ้นสินค้าที่ขาย'), findsOneWidget);

    // The KPI row is the screen's only GridView — scope the value lookups to
    // it, since the same baht amount can coincidentally also appear in the
    // category/top-products/recent-sales cards below.
    final kpiGrid = find.byType(GridView).first;

    // Values: netRevenue=200, transactions=2, avgTicket=100, items=3 — all
    // distinct so each finder is unambiguous within the KPI row.
    expectVisiblyLaidOut(tester, find.descendant(of: kpiGrid, matching: find.text('฿200')));
    expectVisiblyLaidOut(tester, find.descendant(of: kpiGrid, matching: find.text('2')));
    expectVisiblyLaidOut(tester, find.descendant(of: kpiGrid, matching: find.text('฿100')));
    expectVisiblyLaidOut(tester, find.descendant(of: kpiGrid, matching: find.text('3')));

    // Drain (don't assert on) any pending exception: at 390px the recent-sales
    // list below the KPI row has its own, separate RenderFlex overflow
    // (_RecentRow, unrelated to #463's KPI cards) — out of scope here.
    tester.takeException();
  });

  testWidgets('KPI grid keeps its 4-column desktop layout unchanged (#463)', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await pumpReports(tester);

    final kpiGrid = find.byType(GridView).first;
    final gridView = tester.widget<GridView>(kpiGrid);
    final delegate = gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 4);
    expect(delegate.childAspectRatio, 2.2);

    expectVisiblyLaidOut(tester, find.descendant(of: kpiGrid, matching: find.text('฿200')));
  });
}
