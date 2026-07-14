// SalesRepository — sales / checkout (sa_sales + sa_sale_items).
//
// Implementation owned by the **Sales service agent**. Ported from db.js
// saveSale / getSales / getRefundedQty (pos/db.js lines 191-270, 398-406).
//
// saveSale(SaleInput) — TRANSACTIONAL port of db.js saveSale:
//  • Pre-validate stock for every line; throw a Thai error if insufficient:
//      'สต็อกไม่พอ:\n' + lines.join('\n')
//    per-line: '<name>: ไม่พบในสต็อก' (missing) or
//              '<p.name>: สต็อก <stock> แต่ต้องการ <qty>' (short).
//  • pointsGranted = (total / 10).floor()  (money.dart pointsFor).
//  • receiptNo = docNo('RC'); id = newId('s'); date = now.
//  • Strict stock decrement — NEVER clamp at 0; underflow is a bug → throw.
//  • If customerId: totalSpend += total, points += pointsGranted.
//  • If mechanicId: totalSales += total; totalDiscount += (delta<0 ? -delta : 0);
//    totalMarkup += (delta>0 ? delta : 0); creditBalance += (method=='เครดิตช่าง' ? total : 0).
//  • Run the WHOLE thing in db.transaction(...) so any throw rolls everything back.
//  • Store pointsGranted ON the sale so refunds reverse the right count.

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../../core/utils/money.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';

class SalesRepository {
  final AppDatabase db;
  SalesRepository(this.db);

  /// Transactional. Returns the persisted SaleRow. Throws a Thai 'สต็อกไม่พอ…'
  /// error (and rolls back) on insufficient stock.
  Future<SaleRow> saveSale(SaleInput input) async {
    // ── 1. Pre-validate stock against current Products (db.js productsSnapshot) ──
    final products = await db.select(db.products).get();
    final byId = {for (final p in products) p.id: p};

    final insufficient = <String>[];
    for (final item in input.items) {
      final p = byId[item.productId];
      if (p == null) {
        insufficient.add('${item.name}: ไม่พบในสต็อก');
      } else if (p.stock < item.qty) {
        insufficient.add('${p.name}: สต็อก ${p.stock} แต่ต้องการ ${item.qty}');
      }
    }
    if (insufficient.isNotEmpty) {
      throw Exception('สต็อกไม่พอ:\n${insufficient.join('\n')}');
    }

    // ── 2. Inside a Drift transaction: any throw rolls everything back. ──
    return db.transaction(() async {
      final pointsGranted = pointsFor(input.total);
      final receiptNo = docNo('RC');
      final saleId = newId('s');
      final date = DateTime.now();

      // Strict stock decrement (no Math.max masking; pre-check guarantees enough).
      for (final item in input.items) {
        final p = byId[item.productId]!;
        final newStock = p.stock - item.qty;
        if (newStock < 0) {
          throw Exception('Stock underflow on ${p.partNo} — race condition?');
        }
        await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(
          ProductsCompanion(stock: Value(newStock)),
        );
      }

      // Customer (if any): add total to totalSpend, pointsGranted to points.
      if (input.customerId != null) {
        final c = await (db.select(
          db.customers,
        )..where((t) => t.id.equals(input.customerId!))).getSingleOrNull();
        if (c != null) {
          await (db.update(
            db.customers,
          )..where((t) => t.id.equals(input.customerId!))).write(
            CustomersCompanion(
              totalSpend: Value(c.totalSpend + input.total),
              points: Value(c.points + pointsGranted),
            ),
          );
        }
      }

      // Mechanic (if any).
      if (input.mechanicId != null) {
        final m = await (db.select(
          db.mechanics,
        )..where((t) => t.id.equals(input.mechanicId!))).getSingleOrNull();
        if (m != null) {
          final delta = input.mechanicDelta ?? 0;
          final isCredit = input.paymentMethod == 'เครดิตช่าง';
          await (db.update(
            db.mechanics,
          )..where((t) => t.id.equals(input.mechanicId!))).write(
            MechanicsCompanion(
              totalSales: Value(m.totalSales + input.total),
              totalDiscount: Value(m.totalDiscount + (delta < 0 ? -delta : 0)),
              totalMarkup: Value(m.totalMarkup + (delta > 0 ? delta : 0)),
              creditBalance: Value(
                m.creditBalance + (isCredit ? input.total : 0),
              ),
            ),
          );
        }
      }

      // Insert the Sale header.
      final sale = SaleRow(
        id: saleId,
        receiptNo: receiptNo,
        subtotal: input.subtotal,
        discount: input.discount,
        total: input.total,
        paymentMethod: input.paymentMethod,
        customerId: input.customerId,
        customerName: input.customerName,
        mechanicId: input.mechanicId,
        mechanicName: input.mechanicName,
        mechanicDelta: input.mechanicDelta,
        pointsGranted: pointsGranted,
        date: date,
        voided: false,
        voidedAt: null,
      );
      await db.into(db.sales).insert(sale);

      // Insert the SaleItems.
      await db.batch((b) {
        for (final item in input.items) {
          b.insert(
            db.saleItems,
            SaleItemsCompanion.insert(
              saleId: saleId,
              productId: item.productId,
              partNo: Value(item.partNo),
              name: item.name,
              nameTH: Value(item.nameTH),
              qty: item.qty,
              price: item.price,
            ),
          );
        }
      });

      return sale;
    });
  }

  /// All sales, newest first (with their items).
  Future<List<SaleWithItems>> getSales() async {
    final sales = await (db.select(
      db.sales,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    return _attachItems(sales);
  }

  Stream<List<SaleWithItems>> watchSales() {
    final query = db.select(db.sales)
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    return query.watch().asyncMap(_attachItems);
  }

  /// Map of productId → already-refunded qty for a sale (db.js getRefundedQty).
  /// Sums ReturnItems across every Return whose saleId matches.
  Future<Map<String, int>> getRefundedQty(String saleId) async {
    final returns = await (db.select(
      db.returns,
    )..where((t) => t.saleId.equals(saleId))).get();
    final result = <String, int>{};
    if (returns.isEmpty) return result;
    final returnIds = returns.map((r) => r.id).toList();
    final items = await (db.select(
      db.returnItems,
    )..where((t) => t.returnId.isIn(returnIds))).get();
    for (final i in items) {
      result[i.productId] = (result[i.productId] ?? 0) + i.qty;
    }
    return result;
  }

  /// Loads SaleItems for each sale, preserving the given sale order.
  Future<List<SaleWithItems>> _attachItems(List<SaleRow> sales) async {
    if (sales.isEmpty) return const [];
    final ids = sales.map((s) => s.id).toList();
    final allItems = await (db.select(
      db.saleItems,
    )..where((t) => t.saleId.isIn(ids))).get();
    final bySale = <String, List<SaleItemRow>>{};
    for (final it in allItems) {
      (bySale[it.saleId] ??= []).add(it);
    }
    return [for (final s in sales) SaleWithItems(s, bySale[s.id] ?? const [])];
  }
}
