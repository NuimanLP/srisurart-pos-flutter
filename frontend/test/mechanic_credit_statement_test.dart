// Mechanic credit statement / ใบวางบิล (pain-points survey 2026-10-23 §4.2):
// the stored creditBalance is the total, spread backwards over the newest
// credit bills; what no local bill explains is the residual line.
//
// The behaviour cases run the REAL repositories (saveSale, createReturn,
// addCreditPayment, voidSaleOffline) on an in-memory Drift DB and then
// allocate from what they left behind, so the clamps and the auto-void are the
// shipped ones, not a re-implementation. The aging/edge cases are pure.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/reports/credit_statement.dart';

void main() {
  group('allocation against the real repositories', () {
    late AppDatabase db;
    late SalesRepository sales;
    late ReturnsRepository returns;
    late MechanicsRepository mechanics;
    const mid = 'm1'; // seeded ลุงมานพ, balance 0, limit 5000
    final asOf = DateTime(2026, 10, 23, 18);

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      sales = SalesRepository(db);
      returns = ReturnsRepository(db);
      mechanics = MechanicsRepository(db);
      await db
          .update(db.products)
          .write(const ProductsCompanion(stock: Value(1000)));
    });
    tearDown(() => db.close());

    /// One-line bill of [qty] × [price] on product p1 for mechanic m1.
    Future<SaleRow> sell(
      double price, {
      int qty = 1,
      String method = 'เครดิตช่าง',
      int daysAgo = 0,
    }) async {
      final total = price * qty;
      final s = await sales.saveSale(
        SaleInput(
          subtotal: total,
          discount: 0,
          total: total,
          paymentMethod: method,
          mechanicId: mid,
          mechanicName: 'ลุงมานพ',
          items: [
            SaleLineInput(
              productId: 'p1',
              name: 'กรอง',
              qty: qty,
              price: price,
            ),
          ],
          overrideCreditLimit: true,
        ),
      );
      // Back-date against the fixed statement date so ages are exact.
      final date = DateTime(asOf.year, asOf.month, asOf.day - daysAgo, 12);
      await (db.update(db.sales)..where((t) => t.id.equals(s.id))).write(
        SalesCompanion(date: Value(date)),
      );
      return (await (db.select(
        db.sales,
      )..where((t) => t.id.equals(s.id))).getSingle());
    }

    /// Credit note for [qty] units at [unitPrice] of [s]'s single line.
    Future<ReturnRow> giveBack(
      SaleRow s,
      int qty,
      double unitPrice,
      String method,
    ) => returns.createReturn(
      ReturnInput(
        saleId: s.id,
        refundMethod: method,
        items: [
          ReturnLineInput(
            productId: 'p1',
            name: 'กรอง',
            qty: qty,
            price: unitPrice,
          ),
        ],
      ),
    );

    Future<double> balance() async => (await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals(mid))).getSingle()).creditBalance;

    Future<CreditStatement> statement() async => allocateCreditStatement(
      mechanicId: mid,
      creditBalance: await balance(),
      // The same narrow reads the screen uses.
      sales: await sales.getMechanicCreditSales(mid),
      returns: await returns.getReturnsForSales(
        (await sales.getMechanicCreditSales(mid)).map((s) => s.id),
      ),
      asOf: asOf,
    );

    void expectTotals(CreditStatement st, double bal) {
      expect(st.total, bal);
      final sum =
          st.lines.fold<int>(0, (s, l) => s + (l.outstanding * 100).round()) +
          (st.residual * 100).round();
      expect(
        sum,
        (bal * 100).round(),
        reason: 'lines + residual == creditBalance',
      );
      expect(st.hasResidual, st.residual != 0);
    }

    test(
      'simple: newest bills first, the oldest one partly, no residual',
      () async {
        final a = await sell(300, daysAgo: 40);
        final b = await sell(200, daysAgo: 10);
        final c = await sell(100, daysAgo: 1);
        await mechanics.addCreditPayment(
          mechanicId: mid,
          amount: 250,
          paymentMethod: 'เงินสด',
        );
        expect(await balance(), 350);

        final st = await statement();
        expect(st.lines.map((l) => l.receiptNo), [
          c.receiptNo,
          b.receiptNo,
          a.receiptNo,
        ]);
        expect(st.lines.map((l) => l.outstanding), [100, 200, 50]);
        expect(st.lines.map((l) => l.ageDays), [1, 10, 40]);
        expect(st.residual, 0);
        expect(st.buckets[AgingBucket.d0to30], 300);
        expect(st.buckets[AgingBucket.d31to60], 50);
        expectTotals(st, 350);
      },
    );

    test(
      'overpayment clamped at 0: the newer bill carries the whole balance',
      () async {
        await sell(100, daysAgo: 20);
        await mechanics.addCreditPayment(
          mechanicId: mid,
          amount: 150,
          paymentMethod: 'เงินสด',
        );
        expect(await balance(), 0); // clamped, not -50
        final b = await sell(200, daysAgo: 2);
        expect(await balance(), 200); // bills − payments would say 150

        final st = await statement();
        expect(st.lines.single.receiptNo, b.receiptNo);
        expect(st.lines.single.outstanding, 200);
        expect(st.hasResidual, isFalse);
        expectTotals(st, 200);
      },
    );

    test(
      'balance no local bill explains (legacy import / other device) → residual line',
      () async {
        final a = await sell(200, daysAgo: 5);
        // As a legacy import (snapshot_repository) or an API pull writes it.
        await (db.update(db.mechanics)..where((t) => t.id.equals(mid))).write(
          const MechanicsCompanion(creditBalance: Value(500)),
        );

        final st = await statement();
        expect(st.lines.single.receiptNo, a.receiptNo);
        expect(st.lines.single.outstanding, 200);
        expect(st.residual, 300);
        expect(st.hasResidual, isTrue);
        expectTotals(st, 500);
      },
    );

    test(
      'หักจากเครดิต on a CASH bill lowers the balance but never makes a line',
      () async {
        final cash = await sell(500, method: 'เงินสด', daysAgo: 3);
        final credit = await sell(300, daysAgo: 8);
        await giveBack(
          cash,
          1,
          500,
          'หักจากเครดิต',
        ); // refund 500 taken off credit
        expect(await balance(), 0); // 300 − 500, clamped

        var st = await statement();
        expect(st.lines, isEmpty);
        expectTotals(st, 0);

        // Same shape, smaller credit note: only the credit bill is listed.
        final cash2 = await sell(100, qty: 2, method: 'เงินสด', daysAgo: 2);
        final credit2 = await sell(400, daysAgo: 1);
        await giveBack(cash2, 1, 100, 'หักจากเครดิต'); // −100 → 300
        expect(await balance(), 300);
        st = await statement();
        expect(st.lines.map((l) => l.receiptNo), [credit2.receiptNo]);
        expect(st.lines.single.outstanding, 300);
        expect(
          st.lines.map((l) => l.receiptNo),
          isNot(
            contains(anyOf(cash.receiptNo, cash2.receiptNo, credit.receiptNo)),
          ),
        );
        expectTotals(st, 300);
      },
    );

    test(
      'full return หักจากเครดิต auto-voids the bill: nets to 0, no line, not counted twice',
      () async {
        final a = await sell(300, daysAgo: 30);
        final b = await sell(100, qty: 2, daysAgo: 4); // 200
        await giveBack(b, 2, 100, 'หักจากเครดิต');
        final voided = await (db.select(
          db.sales,
        )..where((t) => t.id.equals(b.id))).getSingle();
        expect(voided.voided, isTrue);
        expect(voided.voidReason, isNull); // auto-void, not a manual one
        expect(await balance(), 300);

        final st = await statement();
        expect(st.lines.single.receiptNo, a.receiptNo);
        expect(st.lines.single.outstanding, 300);
        expectTotals(st, 300);
      },
    );

    test(
      'partial return หักจากเครดิต: the bill counts net of its own credit note',
      () async {
        final a = await sell(300, daysAgo: 30);
        final b = await sell(100, qty: 4, daysAgo: 4); // 400
        await giveBack(b, 1, 100, 'หักจากเครดิต'); // −100
        expect(await balance(), 600);

        final st = await statement();
        expect(st.lines.map((l) => l.receiptNo), [b.receiptNo, a.receiptNo]);
        expect(st.lines.map((l) => l.outstanding), [300, 300]);
        expectTotals(st, 600);
      },
    );

    test(
      'full return refunded in cash auto-voids but the debt stays on that bill',
      () async {
        final a = await sell(300, daysAgo: 30);
        final b = await sell(200, daysAgo: 4);
        await giveBack(b, 1, 200, 'เงินสด');
        expect(await balance(), 500); // a cash refund does not touch credit

        final st = await statement();
        expect(st.lines.map((l) => l.receiptNo), [b.receiptNo, a.receiptNo]);
        expectTotals(st, 500);
      },
    );

    test('a manual void is skipped', () async {
      final a = await sell(300, daysAgo: 30);
      final b = await sell(200, daysAgo: 4);
      await sales.voidSaleOffline(b.id, 'ลงผิดบิล');
      expect(await balance(), 300);

      final st = await statement();
      expect(st.lines.single.receiptNo, a.receiptNo);
      expectTotals(st, 300);
    });

    test('balance 0 → empty statement, no residual line', () async {
      await sell(100, daysAgo: 3);
      await mechanics.addCreditPayment(
        mechanicId: mid,
        amount: 100,
        paymentMethod: 'เงินสด',
      );

      final st = await statement();
      expect(st.lines, isEmpty);
      expect(st.residual, 0);
      expect(st.hasResidual, isFalse);
      expect(st.total, 0);
      expect(st.buckets.values, everyElement(0));
    });
  });

  group('pure rules', () {
    final asOf = DateTime(2026, 10, 23, 9, 30);

    SaleRow bill(
      String id,
      double total,
      DateTime date, {
      String mechanicId = 'm1',
      String method = 'เครดิตช่าง',
      bool voided = false,
      String? voidReason,
    }) => SaleRow(
      id: id,
      receiptNo: 'RC-$id',
      subtotal: total,
      discount: 0,
      total: total,
      paymentMethod: method,
      mechanicId: mechanicId,
      pointsGranted: 0,
      date: date,
      voided: voided,
      voidReason: voidReason,
      soldOffline: false,
    );

    test('aging buckets at the boundaries 30/31/60/61/90/91', () {
      for (final (days, bucket) in const [
        (0, AgingBucket.d0to30),
        (30, AgingBucket.d0to30),
        (31, AgingBucket.d31to60),
        (60, AgingBucket.d31to60),
        (61, AgingBucket.d61to90),
        (90, AgingBucket.d61to90),
        (91, AgingBucket.over90),
      ]) {
        expect(agingBucketOf(days), bucket, reason: '$days days');
      }
    });

    test('ages are calendar days and bucket totals follow them', () {
      // Bill at 23:59 the day before is 1 day old at 09:30 — not 0.
      final ages = [0, 30, 31, 60, 61, 90, 91];
      final sales = [
        for (var i = 0; i < ages.length; i++)
          bill('b$i', 1.0 + i, DateTime(2026, 10, 23 - ages[i], 23, 59)),
      ];
      final st = allocateCreditStatement(
        mechanicId: 'm1',
        creditBalance: 28, // 1+2+…+7
        sales: sales,
        returns: const [],
        asOf: asOf,
      );
      expect(st.lines.map((l) => l.ageDays), ages);
      expect(st.buckets, {
        AgingBucket.d0to30: 3.0, // 1 + 2
        AgingBucket.d31to60: 7.0, // 3 + 4
        AgingBucket.d61to90: 11.0, // 5 + 6
        AgingBucket.over90: 7.0,
      });
      expect(st.hasResidual, isFalse);
      expect(st.total, 28);
    });

    test(
      'a voided bill with no credit note (legacy void, no reason) is skipped',
      () {
        final st = allocateCreditStatement(
          mechanicId: 'm1',
          creditBalance: 100,
          sales: [
            bill('old', 100, DateTime(2026, 9, 1)),
            bill('legacyVoid', 250, DateTime(2026, 10, 1), voided: true),
          ],
          returns: const [],
          asOf: asOf,
        );
        expect(st.lines.single.saleId, 'old');
        expect(st.residual, 0);
      },
    );

    test('a negative balance: no lines, no residual, shown as overpaid', () {
      final st = allocateCreditStatement(
        mechanicId: 'm1',
        creditBalance: -50,
        sales: [bill('a', 100, DateTime(2026, 10, 1))],
        returns: const [],
        asOf: asOf,
      );
      expect(st.lines, isEmpty);
      expect(st.residual, 0);
      expect(st.hasResidual, isFalse);
      expect(st.noDebt, isTrue);
      expect(st.overpaid, 50);
      expect(st.total, -50);
      expect(st.buckets.values, everyElement(0));
    });

    test(
      'a bill dated after the statement date (fast clock) is 0 days old',
      () {
        final st = allocateCreditStatement(
          mechanicId: 'm1',
          creditBalance: 100,
          sales: [bill('future', 100, DateTime(2026, 10, 26))],
          returns: const [],
          asOf: asOf,
        );
        expect(st.lines.single.ageDays, 0);
        expect(st.buckets[AgingBucket.d0to30], 100);
      },
    );

    test(
      'other mechanics and non-credit bills are ignored; satang stay exact',
      () {
        final st = allocateCreditStatement(
          mechanicId: 'm1',
          creditBalance: 0.3,
          sales: [
            bill('x', 0.1, DateTime(2026, 10, 1)),
            bill('y', 0.2, DateTime(2026, 10, 2)),
            bill('other', 999, DateTime(2026, 10, 20), mechanicId: 'm2'),
            bill('cash', 999, DateTime(2026, 10, 21), method: 'เงินสด'),
          ],
          returns: const [],
          asOf: asOf,
        );
        expect(st.lines.map((l) => l.saleId), ['y', 'x']);
        expect(st.lines.map((l) => l.outstanding), [0.2, 0.1]);
        expect(st.residual, 0);
        expect(st.total, 0.3);
      },
    );
  });
}
