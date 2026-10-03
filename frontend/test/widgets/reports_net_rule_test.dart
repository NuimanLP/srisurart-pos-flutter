// The reports screen follows the closing report's rule (net_sales.dart,
// owner 2026-10-03): a manual void is dropped from revenue, bills, average,
// items and top products; an auto-voided (fully returned) bill stays counted
// with its credit note subtracted, so its product leaves the top list.

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

  Future<void> sale(
    String id,
    String partNo,
    int qty,
    double price, {
    bool voided = false,
  }) async {
    await db
        .into(db.sales)
        .insert(
          SalesCompanion.insert(
            id: id,
            receiptNo: 'RC-$id',
            subtotal: qty * price,
            total: qty * price,
            paymentMethod: 'เงินสด',
            date: DateTime.now(),
            voided: Value(voided),
          ),
        );
    await db
        .into(db.saleItems)
        .insert(
          SaleItemsCompanion.insert(
            saleId: id,
            productId: 'prod-$partNo',
            partNo: Value(partNo),
            name: 'สินค้า $partNo',
            qty: qty,
            price: price,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await sale('kept', 'KEEP', 3, 100); // 300, counted
    await sale('manual', 'VOIDED', 9, 100, voided: true); // manual void
    await sale('auto', 'BACK', 1, 500, voided: true); // auto-void below
    await db
        .into(db.returns)
        .insert(
          ReturnsCompanion.insert(
            id: 'cn-auto',
            cnNo: 'CN-auto',
            saleId: 'auto',
            receiptNo: 'RC-auto',
            date: DateTime.now(),
            refundSubtotal: 500,
            refundDiscount: 0,
            refundTotal: 500,
            refundMethod: 'เงินสด',
          ),
        );
    await db
        .into(db.returnItems)
        .insert(
          ReturnItemsCompanion.insert(
            returnId: 'cn-auto',
            productId: 'prod-BACK',
            name: 'สินค้า BACK',
            qty: 1,
            price: 500,
          ),
        );
  });

  tearDown(() async => db.close());

  testWidgets('manual voids dropped, auto-void netted', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SalesRepository>(
            create: (_) => SalesRepository(db),
          ),
          RepositoryProvider<ReturnsRepository>(
            create: (_) => ReturnsRepository(db),
          ),
          RepositoryProvider<ProductsRepository>(
            create: (_) => ProductsRepository(db),
          ),
        ],
        child: const MaterialApp(home: ReportsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final kpi = find.byType(GridView).first;
    Finder inKpi(String text) =>
        find.descendant(of: kpi, matching: find.text(text));

    // Net 300 + 500 − 500 = 300 over 2 counted bills (kept + auto).
    expect(inKpi('฿300'), findsOneWidget);
    expect(inKpi('2'), findsOneWidget, reason: 'bills: manual void dropped');
    expect(inKpi('฿150'), findsOneWidget, reason: 'avg = net ÷ bills');
    expect(inKpi('3'), findsOneWidget, reason: 'items: 3 + 1 − 1');
    expect(
      find.textContaining('ขาย ฿800 − คืน ฿500'),
      findsOneWidget,
      reason: 'gross of counted bills only',
    );

    // Top products: KEEP only — VOIDED is a manual void, BACK nets to 0.
    expect(find.text('สินค้า KEEP'), findsOneWidget);
    expect(find.text('สินค้า VOIDED'), findsNothing);
    expect(find.text('สินค้า BACK'), findsNothing);
  });
}
