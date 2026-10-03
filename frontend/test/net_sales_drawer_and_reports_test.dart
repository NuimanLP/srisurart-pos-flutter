// Follow-ups to #569, owner decisions 2026-10-03 (domain/reports/net_sales.dart):
//
// 1. Average per bill = NET revenue ÷ counted bills, like the server's
//    `avgTicket` now is (`reports.service.ts` summary).
// 2. Expected drawer cash leaves out a manually voided cash bill (the money
//    went back), and keeps an auto-voided one (its cash refund is already
//    subtracted) — `drawerCashSalesOf`, used by BOTH the cash-drawer screen
//    and the closing report's drawer check.
// 3. The reports screen and products_screen's ranking use `NetSales` too:
//    net items, top items keyed by part number, no tax rate needed.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/reports/net_sales.dart';

ItemLite _item(String partNo, int qty, {double price = 100}) => ItemLite(
  partNo: partNo,
  name: 'item $partNo',
  qty: qty,
  price: price,
  costAtSale: 50,
  currentCost: 50,
);

SaleLite _sale(String id, List<ItemLite> items, {bool voided = false}) {
  final total = items.fold<double>(0, (a, i) => a + i.price * i.qty);
  return SaleLite(
    id: id,
    subtotal: total,
    discount: 0,
    total: total,
    paymentMethod: 'เงินสด',
    voided: voided,
    items: items,
  );
}

ReturnLite _return(String saleId, List<ItemLite> items) => ReturnLite(
  saleId: saleId,
  refundTotal: items.fold<double>(0, (a, i) => a + i.price * i.qty),
  refundMethod: 'เงินสด',
  items: items,
);

void main() {
  group('NetSales — average, items, top items (pure)', () {
    test('a fully refunded period averages ฿0 per bill', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item('A', 2)]),
        ],
        [
          _return('s1', [_item('A', 2)]),
        ],
      );
      expect(net.billCount, 1);
      expect(net.netRevenue, 0);
      expect(net.avgPerBill, 0);
    });

    test('average is net revenue ÷ counted bills', () {
      // s1 200, s2 100 with 100 back, s3 manual void (excluded).
      final net = NetSales.of(
        [
          _sale('s1', [_item('A', 2)]),
          _sale('s2', [_item('B', 1)]),
          _sale('s3', [_item('A', 5)], voided: true),
        ],
        [
          _return('s2', [_item('B', 1)]),
        ],
      );
      expect(net.billCount, 2);
      expect(net.netRevenue, 200);
      expect(net.avgPerBill, 100);
    });

    test('netItems counts counted sale lines minus credit-note lines', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item('A', 3), _item('B', 1)]),
          _sale('v', [_item('A', 9)], voided: true),
        ],
        [
          _return('s1', [_item('A', 1)]),
          _return('old', [_item('C', 2)]),
        ],
      );
      expect(net.netItems, 3 + 1 - 1 - 2);
    });

    test('top items carry their part number and drop manual voids', () {
      final net = NetSales.of(
        [
          _sale('s1', [_item('A', 1), _item('B', 3)]),
          _sale('v', [_item('C', 10)], voided: true),
        ],
        [
          _return('s1', [_item('B', 1)]),
        ],
      );
      expect({for (final t in net.topItems) t.partNo: t.qty}, {'A': 1, 'B': 2});
    });

    test('profit needs a tax rate; without one it is never computed', () {
      final net = NetSales.of([
        _sale('s1', [_item('A', 1)]),
      ], const []);
      expect(net.netRevenue, 100);
      expect(() => net.profit, throwsStateError);
      expect(
        NetSales.of(
          [
            _sale('s1', [_item('A', 1)]),
          ],
          const [],
          7,
        ).profit.profit,
        closeTo(100 / 1.07 - 50, 1e-9),
      );
    });
  });

  group('drawerCashSalesOf + expected drawer cash (real Drift)', () {
    late AppDatabase db;
    late SalesRepository sales;
    late ReturnsRepository returns;
    late ShiftsRepository shifts;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      sales = SalesRepository(db);
      returns = ReturnsRepository(db);
      shifts = ShiftsRepository(db);
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'drw1',
              partNo: 'DRW-1',
              name: 'Widget',
              nameTH: 'วิดเจ็ต',
              category: 'general',
              brand: 'X',
              price: 150,
              cost: 80,
              stock: 50,
              minStock: 0,
            ),
          );
    });

    tearDown(() => db.close());

    Future<SaleRow> sell({String method = 'เงินสด'}) => sales.saveSale(
      SaleInput(
        subtotal: 150,
        discount: 0,
        total: 150,
        paymentMethod: method,
        items: const [
          SaleLineInput(
            productId: 'drw1',
            partNo: 'DRW-1',
            name: 'Widget',
            qty: 1,
            price: 150,
          ),
        ],
      ),
    );

    Future<void> returnInFull(String saleId) => returns.createReturn(
      ReturnInput(
        saleId: saleId,
        items: const [
          ReturnLineInput(
            productId: 'drw1',
            name: 'Widget',
            qty: 1,
            price: 150,
          ),
        ],
        refundMethod: 'เงินสด',
      ),
    );

    /// Expected cash as both screens compute it, from the cash-drawer
    /// screen's own reads: sales/returns from [from].
    Future<double> expectedCash(double starting, DateTime from) async {
      final day = dayBounds(DateTime.now());
      final s = await sales.getSales(from: from, to: day.to);
      final r = await returns.getReturns(from: from, to: day.to);
      final cashRefunds = r
          .where((x) => x.ret.refundMethod == 'เงินสด')
          .fold<double>(0, (a, x) => a + x.ret.refundTotal);
      return starting + drawerCashSalesOf(s, r, from: from) - cashRefunds;
    }

    test('a manually voided cash bill is not expected in the drawer', () async {
      final day = dayBounds(DateTime.now());
      await sell();
      final voided = await sell();
      await sales.voidSaleOffline(voided.id, 'ลูกค้ายกเลิก');

      final s = await sales.getSales(from: day.from, to: day.to);
      final r = await returns.getReturns(from: day.from, to: day.to);
      expect(drawerCashSalesOf(s, r, from: day.from), 150);
      expect(await expectedCash(500, day.from), 650);
    });

    test(
      'a full cash return keeps the sale and subtracts the refund → net 0',
      () async {
        final day = dayBounds(DateTime.now());
        final sale = await sell();
        await returnInFull(sale.id);

        final s = await sales.getSales(from: day.from, to: day.to);
        final r = await returns.getReturns(from: day.from, to: day.to);
        expect(
          s.single.sale.voided,
          isTrue,
          reason: 'a full return auto-voids the bill',
        );
        expect(
          drawerCashSalesOf(s, r, from: day.from),
          150,
          reason: 'the auto-voided bill stays counted',
        );
        expect(await expectedCash(500, day.from), 500);
      },
    );

    test('the cash-drawer screen and the closing report get the same number '
        '(later shift of the day)', () async {
      final now = DateTime.now();
      final day = dayBounds(now);
      // Shift 1 opened at midnight with one cash bill in it; shift 2 opened
      // a moment ago. Drift stores whole seconds, so the rows are placed
      // explicitly rather than raced against the clock.
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh1',
              dateStr: todayKey(),
              startingCash: 300,
              openedAt: day.from,
              isActive: const Value(false),
            ),
          );
      await db
          .into(db.sales)
          .insert(
            SalesCompanion.insert(
              id: 'early',
              receiptNo: 'RC-EARLY',
              subtotal: 999,
              total: 999,
              paymentMethod: 'เงินสด',
              date: day.from.add(const Duration(seconds: 1)),
            ),
          );
      final shift2Opened = now.subtract(const Duration(seconds: 2));
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh2',
              dateStr: todayKey(),
              startingCash: 500,
              openedAt: shift2Opened,
              isActive: const Value(true),
            ),
          );

      await sell(); // counted: +150
      final voided = await sell();
      await sales.voidSaleOffline(voided.id, 'ลูกค้ายกเลิก'); // dropped
      final returned = await sell();
      await returnInFull(returned.id); // +150 sale, −150 refund
      await sell(method: 'โอน/QR'); // not cash

      final drawer = (await shifts.getCashDrawer())!;
      expect(drawer.shift.id, 'sh2');
      final countFrom = await shifts.cashCountFrom(drawer.shift) ?? day.from;
      expect(countFrom, isNot(day.from), reason: 'a later shift');

      // Cash-drawer screen: sales and returns read from countFrom.
      final drawerSales = await sales.getSales(from: countFrom, to: day.to);
      final windowReturns = await returns.getReturns(
        from: countFrom,
        to: day.to,
      );
      final onDrawerScreen = drawerCashSalesOf(
        drawerSales,
        windowReturns,
        from: countFrom,
      );

      // Closing report: the WHOLE day's sales, the drawer's returns window.
      final daySales = await sales.getSales(from: day.from, to: day.to);
      final onClosingReport = drawerCashSalesOf(
        daySales,
        windowReturns,
        from: countFrom,
      );

      expect(onDrawerScreen, 300);
      expect(onClosingReport, onDrawerScreen);
      expect(await expectedCash(500, countFrom), 650);
    });
  });
}
