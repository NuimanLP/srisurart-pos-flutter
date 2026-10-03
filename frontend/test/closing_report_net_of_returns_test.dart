// The closing report (and products_screen's daily/monthly report) must net
// out credit notes and drop manual voids, by the same rule as the server's
// `/reports/summary` and `/reports/closing` (`reports.service.ts`,
// `COUNTED_SALE` + `grossProfitCtes`). Found live on the demo VM 2026-10-03:
// a ฿150 cash sale returned in full still read revenue ฿150, profit ฿60.
//
// The pure maths is `NetSales.of` / `computeGrossProfit` / `countedSales`
// (domain/reports/net_sales.dart). The repository-driven group at the bottom runs the
// real Drift SalesRepository/ReturnsRepository and `toReportLites`, the same
// assembly `_loadClosingData` does.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/reports/net_sales.dart';

const _tax = 7.0;
const _vat = 1 + _tax / 100;

ItemLite _item({
  String partNo = 'P1',
  int qty = 1,
  double price = 150,
  double? costAtSale = 80,
  double? currentCost = 80,
}) => ItemLite(
  partNo: partNo,
  name: 'item $partNo',
  qty: qty,
  price: price,
  costAtSale: costAtSale,
  currentCost: currentCost,
);

SaleLite _sale(
  String id,
  List<ItemLite> items, {
  double discount = 0,
  String method = 'เงินสด',
  bool voided = false,
}) {
  final subtotal = items.fold<double>(0, (a, i) => a + i.price * i.qty);
  return SaleLite(
    id: id,
    subtotal: subtotal,
    discount: discount,
    total: subtotal - discount,
    paymentMethod: method,
    voided: voided,
    items: items,
  );
}

ReturnLite _return(
  String saleId,
  double refundTotal,
  List<ItemLite> items, {
  String method = 'เงินสด',
}) => ReturnLite(
  saleId: saleId,
  refundTotal: refundTotal,
  refundMethod: method,
  items: items,
);

void main() {
  group('NetSales (pure)', () {
    test('a full return of a cash sale nets revenue and profit to 0', () {
      // The demo-VM case: 1 × ฿150, cost ฿80, returned in full → auto-void.
      final net = NetSales.of(
        [
          _sale('s1', [_item()], voided: true),
        ],
        [
          _return('s1', 150, [_item()]),
        ],
        _tax,
      );

      expect(net.netRevenue, 0);
      expect(net.profit.profit, closeTo(0, 1e-9));
      expect(net.profit.cost, 0);
      // An auto-voided bill still counts as a bill (server totalTransactions).
      expect(net.billCount, 1);
      expect(net.avgPerBill, 0);
      expect(net.cash.bills, 1);
      expect(net.cash.net, 0);
      expect(net.topItems, isEmpty);
    });

    test('a partial return subtracts only the returned share', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item(qty: 3, price: 100, costAtSale: 60)]),
        ],
        [
          _return('s1', 100, [_item(qty: 1, price: 100, costAtSale: 60)]),
        ],
        _tax,
      );

      expect(net.netRevenue, 200);
      expect(net.profit.cost, 120);
      expect(net.profit.profit, closeTo(200 / _vat - 120, 1e-9));
      expect(net.billCount, 1);
      expect(net.avgPerBill, 200);
      expect(net.cash.net, 200);
      expect(net.topItems.single.qty, 2);
      expect(net.topItems.single.revenue, 200);
    });

    test('a manually voided bill is excluded entirely', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item()]),
          _sale('void', [_item(partNo: 'P2', price: 999)], voided: true),
        ],
        const [],
        _tax,
      );

      expect(net.billCount, 1);
      expect(net.netRevenue, 150);
      expect(net.profit.profit, closeTo(150 / _vat - 80, 1e-9));
      expect(net.cash.bills, 1);
      expect(net.cash.net, 150);
      expect(net.topItems.map((t) => t.name), ['item P1']);
    });

    test('a voided bill with a credit note is an auto-void and stays', () {
      final sales = [
        _sale('auto', [_item()], voided: true),
        _sale('manual', [_item()], voided: true),
      ];
      final returns = [
        _return('auto', 150, [_item()]),
      ];
      expect(countedSales(sales, returns).map((s) => s.id), ['auto']);
    });

    test('a refund by a different method nets against that method\'s row', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item(qty: 2, price: 100)], method: 'โอน/QR'),
          _sale('s2', [_item(price: 50)], method: 'เครดิตช่าง'),
        ],
        [
          _return('s1', 100, [_item(price: 100)], method: 'เงินสด'),
          _return('s2', 50, [_item(price: 50)], method: 'หักจากเครดิต'),
        ],
        _tax,
      );

      expect(net.qr.bills, 1);
      expect(net.qr.net, 200);
      expect(net.cash.bills, 0);
      expect(net.cash.net, -100);
      expect(net.credit.bills, 1);
      expect(net.credit.net, 0);
      expect(net.netRevenue, 100);
      expect(
        net.cash.net + net.qr.net + net.credit.net,
        net.netRevenue,
        reason: 'the three rows must still add up to รวมทั้งหมด',
      );
    });

    test('a transfer refund ("โอน") nets against the โอน/QR row', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item(qty: 2, price: 100)], method: 'โอน/QR'),
        ],
        [
          _return('s1', 100, [_item(price: 100)], method: 'โอน'),
        ],
        _tax,
      );
      expect(net.qr.net, 100);
      expect(net.cash.net, 0);
    });

    test('a bill discount with a partial return nets proportionally', () {
      // 2 × ฿100 with a ฿20 bill discount = ฿180. Returning 1 refunds ฿90
      // (createReturn's proportional discount share).
      final net = NetSales.of(
        [
          _sale('s1', [
            _item(qty: 2, price: 100, costAtSale: 50),
          ], discount: 20),
        ],
        [
          _return('s1', 90, [_item(qty: 1, price: 100, costAtSale: 50)]),
        ],
        _tax,
      );

      expect(net.netRevenue, 90);
      expect(net.profit.profit, closeTo(90 / _vat - 50, 1e-9));
      // Top items are pre-discount line revenue, like the server's
      // ITEM_EVENTS (qty × price on both sides).
      expect(net.topItems.single.qty, 1);
      expect(net.topItems.single.revenue, 100);
    });

    test('legacy lines with no costAtSale fall back and are disclosed', () {
      final net = NetSales.of(
        [
          _sale('s1', [
            _item(qty: 2, price: 100, costAtSale: null, currentCost: 40),
            _item(partNo: 'GONE', costAtSale: null, currentCost: null),
          ]),
        ],
        [
          _return('s1', 100, [
            _item(qty: 1, price: 100, costAtSale: null, currentCost: 40),
          ]),
        ],
        _tax,
      );

      // ฿200 + ฿150 (the gone product) − ฿100 refunded.
      expect(net.netRevenue, 250);
      expect(net.profit.cost, 40);
      expect(net.profit.profit, closeTo(250 / _vat - 40, 1e-9));
      // Sale line + return line on today's cost; the gone product at 0.
      expect(net.profit.estimatedCostLines, 2);
      expect(net.profit.unknownCostLines, 1);
    });

    test('a return of an earlier bill reduces this period and its top item '
        'drops out when its net quantity is not positive', () {
      final net = NetSales.of(
        [
          _sale('today', [_item(partNo: 'A', price: 30)]),
        ],
        [
          _return('yesterday', 150, [_item(partNo: 'B')]),
        ],
        _tax,
      );
      expect(net.billCount, 1);
      expect(net.netRevenue, -120);
      expect(net.profit.profit, closeTo(-120 / _vat - (80 - 80), 1e-9));
      expect(net.topItems.map((t) => t.name), ['item A']);
    });
  });

  group('repository-driven (the demo-VM steps)', () {
    late AppDatabase db;
    late SalesRepository sales;
    late ReturnsRepository returns;
    late ProductsRepository products;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      sales = SalesRepository(db);
      returns = ReturnsRepository(db);
      products = ProductsRepository(db);
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'np1',
              partNo: 'NET-1',
              name: 'Widget',
              nameTH: 'วิดเจ็ต',
              category: 'general',
              brand: 'X',
              price: 150,
              cost: 80,
              stock: 10,
              minStock: 0,
            ),
          );
    });

    tearDown(() => db.close());

    Future<SaleRow> sell({int qty = 1}) => sales.saveSale(
      SaleInput(
        subtotal: 150.0 * qty,
        discount: 0,
        total: 150.0 * qty,
        paymentMethod: 'เงินสด',
        items: [
          SaleLineInput(
            productId: 'np1',
            partNo: 'NET-1',
            name: 'Widget',
            qty: qty,
            price: 150,
          ),
        ],
      ),
    );

    Future<NetSales> load({List<String> outsideIds = const []}) async {
      final all = await sales.getSales();
      final inPeriod = all.where((s) => !outsideIds.contains(s.sale.id));
      final rets = await returns.getReturns();
      final lites = toReportLites(
        sales: inPeriod.toList(),
        returns: rets,
        products: await products.getAll(),
        originalSales: await sales.getSalesByIds(outsideIds),
      );
      return NetSales.of(lites.sales, lites.returns, _tax);
    }

    test('sell ฿150 cash, return it in full → revenue 0, profit 0', () async {
      final sale = await sell();
      await returns.createReturn(
        ReturnInput(
          saleId: sale.id,
          items: const [
            ReturnLineInput(
              productId: 'np1',
              name: 'Widget',
              qty: 1,
              price: 150,
            ),
          ],
          refundMethod: 'เงินสด',
        ),
      );

      final net = await load();
      expect(net.billCount, 1, reason: 'the auto-voided bill still counts');
      expect(net.netRevenue, 0);
      expect(net.avgPerBill, 0);
      expect(net.profit.profit, closeTo(0, 1e-9));
      expect(net.cash.net, 0);
      expect(net.topItems, isEmpty);
    });

    test('a manual void drops the bill', () async {
      final sale = await sell();
      await sales.voidSaleOffline(sale.id, 'ลูกค้ายกเลิก');

      final net = await load();
      expect(net.billCount, 0);
      expect(net.netRevenue, 0);
      expect(net.profit.profit, 0);
    });

    test('a credit note for a bill outside the period takes that bill\'s '
        'costAtSale, not today\'s product cost', () async {
      final old = await sell(qty: 2);
      // Today's product cost moves away from the sale-time 80.
      await (db.update(db.products)..where((p) => p.id.equals('np1'))).write(
        const ProductsCompanion(cost: Value(200)),
      );
      await returns.createReturn(
        ReturnInput(
          saleId: old.id,
          items: const [
            ReturnLineInput(
              productId: 'np1',
              name: 'Widget',
              qty: 1,
              price: 150,
            ),
          ],
          refundMethod: 'เงินสด',
        ),
      );

      final net = await load(outsideIds: [old.id]);
      expect(net.billCount, 0);
      expect(net.netRevenue, -150);
      expect(net.profit.cost, -80);
      expect(net.profit.estimatedCostLines, 0);
      expect(net.profit.profit, closeTo(-150 / _vat + 80, 1e-9));
    });
  });
}
