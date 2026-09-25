// #417 — Reports / Closing Report load only the selected date range from the
// repository instead of every sale and return ever rung.
//
// The reference is the pre-#417 behaviour: load everything with getSales() /
// getReturns() and filter in memory with the screen's old `_inRange` (and the
// closing report's `dateKey(d) == todayKey()`). For every range the bounded
// query must return exactly the same rows in the same order.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/screens/reports_screen.dart';

/// Verbatim copy of the pre-#417 `_ReportsView._inRange` (reports_screen.dart).
bool legacyInRange(DateTime d, ReportRange range, DateTime now) {
  switch (range) {
    case ReportRange.today:
      return d.year == now.year && d.month == now.month && d.day == now.day;
    case ReportRange.week:
      final weekAgo = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 7));
      return !d.isBefore(weekAgo);
    case ReportRange.month:
      return d.year == now.year && d.month == now.month;
    case ReportRange.all:
      return true;
  }
}

/// Pre-#417 nested-loop category revenue (reports_screen.dart :186-201).
Map<String, double> legacyRevenueByCategory(
  List<SaleWithItems> filtered,
  List<ProductRow> products,
) {
  final zoneMap = <String, double>{};
  for (final t in filtered) {
    for (final item in t.items) {
      ProductRow? p;
      for (final pr in products) {
        if (pr.partNo == item.partNo) {
          p = pr;
          break;
        }
      }
      final z = (p?.category.isNotEmpty ?? false)
          ? p!.category
          : (p?.zone ?? 'อื่นๆ');
      zoneMap[z] = (zoneMap[z] ?? 0) + item.qty * item.price;
    }
  }
  return zoneMap;
}

void main() {
  late AppDatabase db;
  late SalesRepository sales;
  late ReturnsRepository returns;

  var n = 0;

  setUp(() {
    n = 0;
    db = AppDatabase(NativeDatabase.memory());
    sales = SalesRepository(db);
    returns = ReturnsRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> seedAt(
    DateTime date, {
    String partNo = 'X',
    double price = 10,
  }) async {
    n++;
    await db
        .into(db.sales)
        .insert(
          SalesCompanion.insert(
            id: 's$n',
            receiptNo: 'RC$n',
            subtotal: price,
            total: price,
            paymentMethod: 'เงินสด',
            date: date,
          ),
        );
    await db
        .into(db.saleItems)
        .insert(
          SaleItemsCompanion.insert(
            saleId: 's$n',
            productId: 'p',
            partNo: Value(partNo),
            name: 'n',
            qty: 2,
            price: price,
          ),
        );
    // A return on a DIFFERENT sale's bill date than its own date: the report
    // attributes a return by the return's own date, never the parent sale's.
    await db
        .into(db.returns)
        .insert(
          ReturnsCompanion.insert(
            id: 'r$n',
            cnNo: 'CN$n',
            saleId: 's1',
            receiptNo: 'RC1',
            refundSubtotal: 1,
            refundDiscount: 0,
            refundTotal: 1,
            refundMethod: 'เงินสด',
            date: date,
          ),
        );
  }

  /// Boundary-heavy seed around [now].
  Future<void> seedAround(DateTime now) async {
    final midnight = DateTime(now.year, now.month, now.day);
    final weekAgo = midnight.subtract(const Duration(days: 7));
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    final dates = <DateTime>[
      DateTime(2020, 1, 1),
      weekAgo.subtract(const Duration(seconds: 1)),
      weekAgo,
      monthStart.subtract(const Duration(seconds: 1)),
      monthStart,
      midnight.subtract(const Duration(seconds: 1)),
      midnight,
      now,
      midnight.add(const Duration(hours: 23, minutes: 59, seconds: 59)),
      midnight.add(const Duration(days: 1)), // future-dated: week has no cap
      nextMonth.subtract(const Duration(seconds: 1)),
      nextMonth,
    ];
    for (final d in dates) {
      await seedAt(d);
    }
  }

  for (final now in [
    DateTime(2026, 9, 25, 14, 30),
    DateTime(2026, 12, 3, 9), // month rollover into next year; week crosses Nov
    DateTime(2026, 3, 1, 0, 0, 5), // first day of month; week in prior month
  ]) {
    for (final range in ReportRange.values) {
      test(
        '$range at $now: bounded query == legacy in-memory filter',
        () async {
          await seedAround(now);
          final b = reportRangeBounds(range, now);

          final legacySales = (await sales.getSales())
              .where((s) => legacyInRange(s.sale.date, range, now))
              .map((s) => s.sale.id)
              .toList();
          final boundedSales = await sales.getSales(from: b.from, to: b.to);
          expect(boundedSales.map((s) => s.sale.id).toList(), legacySales);
          expect(
            boundedSales.every((s) => s.items.length == 1),
            isTrue,
            reason: 'items still attached',
          );

          final legacyReturns = (await returns.getReturns())
              .where((r) => legacyInRange(r.ret.date, range, now))
              .map((r) => r.ret.id)
              .toList();
          final boundedReturns = await returns.getReturns(
            from: b.from,
            to: b.to,
          );
          expect(boundedReturns.map((r) => r.ret.id).toList(), legacyReturns);
        },
      );
    }

    test('closing report "today" at $now: bounded == dateKey filter', () async {
      await seedAround(now);
      final today = dateKey(now);
      final b = dayBounds(now);

      final legacySales = (await sales.getSales())
          .where((s) => dateKey(s.sale.date) == today)
          .map((s) => s.sale.id)
          .toList();
      expect(
        (await sales.getSales(
          from: b.from,
          to: b.to,
        )).map((s) => s.sale.id).toList(),
        legacySales,
      );
      expect(legacySales, isNotEmpty);

      final legacyReturns = (await returns.getReturns())
          .where((r) => dateKey(r.ret.date) == today)
          .map((r) => r.ret.id)
          .toList();
      expect(
        (await returns.getReturns(
          from: b.from,
          to: b.to,
        )).map((r) => r.ret.id).toList(),
        legacyReturns,
      );
    });
  }

  test(
    'getSales()/getReturns() with no bounds still return everything',
    () async {
      await seedAround(DateTime(2026, 9, 25, 12));
      expect((await sales.getSales()).length, 12);
      expect((await returns.getReturns()).length, 12);
    },
  );

  test('revenueByCategory == legacy nested-loop lookup', () async {
    final products = await db.select(db.products).get();
    expect(products, isNotEmpty, reason: 'seeded catalogue');
    final withCat = products.firstWhere((p) => p.category.isNotEmpty);
    final now = DateTime(2026, 9, 25, 12);
    await seedAt(now, partNo: withCat.partNo, price: 100);
    await seedAt(now, partNo: products.last.partNo, price: 7);
    await seedAt(now, partNo: 'NOT-IN-CATALOGUE', price: 3);
    await db
        .into(db.saleItems)
        .insert(
          SaleItemsCompanion.insert(
            saleId: 's1',
            productId: 'p',
            name: 'no partNo',
            qty: 1,
            price: 5,
          ),
        );
    final all = await sales.getSales();

    expect(
      revenueByCategory(all, products),
      legacyRevenueByCategory(all, products),
    );
  });
}
