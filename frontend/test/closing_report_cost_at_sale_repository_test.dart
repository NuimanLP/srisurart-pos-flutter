// Repository-driven regression test for #402 (AC1): the closing report's
// profit must use `costAtSale`, the cost recorded on the bill (ADR-0008),
// not `products.cost` — which `receivePO`'s weighted-average recompute moves
// after the sale.
//
// This drives the REAL SalesRepository / PurchaseOrdersRepository /
// ProductsRepository against an in-memory Drift DB (no hand-built fixture
// costs) and assembles `ItemLite`/`SaleLite` the same way
// `_loadClosingData` does in closing_report.dart, then feeds them through
// the same `computeGrossProfit` the widget calls.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';

void main() {
  late AppDatabase db;
  late SalesRepository salesRepo;
  late PurchaseOrdersRepository poRepo;
  late ProductsRepository productsRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    salesRepo = SalesRepository(db);
    poRepo = PurchaseOrdersRepository(db);
    productsRepo = ProductsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Mirrors `_loadClosingData`'s assembly step (closing_report.dart) exactly:
  /// costAtSale from the sale line, currentCost as the today-lookup fallback.
  Future<List<SaleLite>> loadSalesAsClosingReportWould() async {
    final salesAgg = await salesRepo.getSales();
    final products = await productsRepo.getAll();
    final costByPart = {for (final p in products) p.partNo: p.cost};
    return [
      for (final s in salesAgg)
        SaleLite(
          subtotal: s.sale.subtotal,
          discount: s.sale.discount,
          total: s.sale.total,
          paymentMethod: s.sale.paymentMethod,
          items: [
            for (final i in s.items)
              ItemLite(
                partNo: i.partNo ?? '',
                name: i.name,
                qty: i.qty,
                price: i.price,
                costAtSale: i.costAtSale,
                currentCost: costByPart[i.partNo],
              ),
          ],
        ),
    ];
  }

  test(
    'a bill sold at cost 100 keeps that cost in the closing profit after '
    'receivePO raises the product cost to 120',
    () async {
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'tp1',
              partNo: 'TEST-1',
              name: 'Widget',
              nameTH: 'วิดเจ็ต',
              category: 'general',
              brand: 'X',
              price: 300,
              cost: 100,
              stock: 10,
              minStock: 0,
            ),
          );

      await salesRepo.saveSale(
        SaleInput(
          subtotal: 300,
          discount: 0,
          total: 300,
          paymentMethod: 'เงินสด',
          items: const [
            SaleLineInput(
              productId: 'tp1',
              partNo: 'TEST-1',
              name: 'Widget',
              qty: 1,
              price: 300,
            ),
          ],
        ),
      );

      final beforeReceive = await loadSalesAsClosingReportWould();
      final profitBefore = computeGrossProfit(beforeReceive, 7);
      // (300 / 1.07) - 100 = ~180.37
      expect(profitBefore.profit, closeTo(300 / 1.07 - 100, 0.01));
      expect(profitBefore.estimatedCostLines, 0);
      expect(profitBefore.unknownCostLines, 0);

      // Weighted-average PO receive moves products.cost — the sale already
      // happened, so its recorded costAtSale must not move with it.
      final po = await poRepo.savePO(
        const PoInput(
          supplier: 'Acme',
          items: [
            PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 10, cost: 140),
          ],
        ),
      );
      final unmatched = await poRepo.receivePO(po.id);
      expect(unmatched, isEmpty);

      final product = await productsRepo.getAll();
      final tp1 = product.firstWhere((p) => p.partNo == 'TEST-1');
      // Stock was 9 after the 1-unit sale, so (9@100 + 10@140)/19 ≈ 121.05 —
      // confirms the product cost really moved away from the sale-time 100.
      expect(tp1.cost, isNot(100.0));
      expect(tp1.cost, greaterThan(100.0));

      final afterReceive = await loadSalesAsClosingReportWould();
      final profitAfter = computeGrossProfit(afterReceive, 7);

      // The bill's profit must be unchanged — still costed at 100, not 120.
      expect(profitAfter.profit, closeTo(profitBefore.profit, 0.0001));
      expect(profitAfter.estimatedCostLines, 0);
      expect(profitAfter.unknownCostLines, 0);
    },
  );
}
