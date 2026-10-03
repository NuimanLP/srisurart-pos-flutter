// Live UX test on mob04 (2026-10-03), reports screen "วันนี้":
//   RC0001 ฿150 (product later deleted -> อื่นๆ), returned in full (CN ฿150,
//   sale auto-voided); RC0002 ฿400 (เครื่องยนต์).
// Net revenue card read ฿400 but "รายได้ตามประเภท" still read เครื่องยนต์
// ฿400 + อื่นๆ ฿150, and the returned bill looked like a live sale in
// "รายการล่าสุด". The category rows must now add up to the net revenue and the
// voided bill must carry a StatusChip.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/reports/net_sales.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/reports_screen.dart';
import 'package:srisurart_pos/presentation/widgets/status_chip.dart';

Future<void> _seedLiveData(AppDatabase db) async {
  final sales = SalesRepository(db);
  final returns = ReturnsRepository(db);
  Future<void> product(String id, String partNo, String cat, double price) => db
      .into(db.products)
      .insert(
        ProductsCompanion.insert(
          id: id,
          partNo: partNo,
          name: partNo,
          nameTH: partNo,
          category: cat,
          brand: 'X',
          price: price,
          cost: 10,
          stock: 10,
          minStock: 0,
        ),
      );
  await product('lv1', 'LIVE-1', 'ของที่ถูกลบ', 150);
  await product('lv2', 'LIVE-2', 'เครื่องยนต์', 400);

  SaleInput input(String id, String part, double price) => SaleInput(
    subtotal: price,
    discount: 0,
    total: price,
    paymentMethod: 'เงินสด',
    items: [
      SaleLineInput(
        productId: id,
        partNo: part,
        name: part,
        qty: 1,
        price: price,
      ),
    ],
  );

  final s1 = await sales.saveSale(input('lv1', 'LIVE-1', 150));
  await sales.saveSale(input('lv2', 'LIVE-2', 400));
  await returns.createReturn(
    ReturnInput(
      saleId: s1.id,
      items: const [
        ReturnLineInput(productId: 'lv1', name: 'LIVE-1', qty: 1, price: 150),
      ],
      refundMethod: 'เงินสด',
    ),
  );
  // The product is deleted afterwards -> its category falls to อื่นๆ.
  await (db.delete(db.products)..where((p) => p.id.equals('lv1'))).go();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  test(
    'category totals sum to the net revenue (400), refunded bill drops out',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _seedLiveData(db);
      final sales = await SalesRepository(db).getSales();
      final products = await ProductsRepository(db).getAll();
      final lites = toReportLites(
        sales: sales,
        returns: await ReturnsRepository(db).getReturns(),
        products: products,
      );
      final net = NetSales.of(lites.sales, lites.returns);
      final counted = sales
          .where((s) => net.counted.any((c) => c.id == s.sale.id))
          .toList();

      expect(net.netRevenue, 400);
      final cats = revenueByCategory(counted, products, returns: lites.returns);
      expect(cats, {'เครื่องยนต์': 400});
      expect(cats.values.fold<double>(0, (a, b) => a + b), net.netRevenue);

      // Without the credit notes the old (gross) figure comes back: 550.
      final gross = revenueByCategory(counted, products);
      expect(gross.values.fold<double>(0, (a, b) => a + b), 550);
    },
  );

  testWidgets('reports screen: returned bill shows the chip, no อื่นๆ row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _seedLiveData(db);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db),
          child: const MaterialApp(home: ReportsScreen()),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    });

    // Exactly one voided bill (the returned one) carries the chip.
    expect(find.byType(StatusChip), findsOneWidget);
    expect(find.text('ยกเลิกบิล'), findsOneWidget);
    expect(find.text('เครื่องยนต์'), findsWidgets);
    expect(find.text('อื่นๆ'), findsNothing);
    await tester.runAsync(db.close);
  });
}
