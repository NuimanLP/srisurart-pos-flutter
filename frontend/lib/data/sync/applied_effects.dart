// The ledger deltas one offline op actually applied (#488).
//
// An offline `sale.create`, `return.create` or `sale.void_offline` records,
// in the same Drift tx as the op, `after − before` for every running total it
// moved — so a clamp at 0 is captured as what really happened, not as what the
// arithmetic asked for. Discarding the op subtracts exactly these deltas; no
// clamp on the way back (a credit note of ฿180 against a ฿50 balance moved it
// by −50, and discard gives back 50, never 180).

import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';

class AppliedEffects {
  /// productId → stock delta.
  final Map<String, int> stock = {};

  String? customerId;
  double spend = 0;
  int points = 0;

  String? mechanicId;
  double mSales = 0;
  double mDiscount = 0;
  double mMarkup = 0;
  double mCredit = 0;

  /// The bill this op flipped to `voided` (an offline void, or a credit note's
  /// auto-void of a fully returned bill). Undo clears it again.
  String? voidedSaleId;

  AppliedEffects();

  void addStock(String productId, int delta) =>
      stock[productId] = (stock[productId] ?? 0) + delta;

  void customer(String id, CustomerRow before, double spendAfter,
      int pointsAfter) {
    customerId = id;
    spend = spendAfter - before.totalSpend;
    points = pointsAfter - before.points;
  }

  void mechanic(
    String id,
    MechanicRow before, {
    required double sales,
    required double discount,
    required double markup,
    required double credit,
  }) {
    mechanicId = id;
    mSales = sales - before.totalSales;
    mDiscount = discount - before.totalDiscount;
    mMarkup = markup - before.totalMarkup;
    mCredit = credit - before.creditBalance;
  }

  Map<String, dynamic> toJson() => {
        'stock': stock,
        if (customerId != null)
          'customer': {'id': customerId, 'spend': spend, 'points': points},
        if (mechanicId != null)
          'mechanic': {
            'id': mechanicId,
            'sales': mSales,
            'discount': mDiscount,
            'markup': mMarkup,
            'credit': mCredit,
          },
        if (voidedSaleId != null) 'voidedSaleId': voidedSaleId,
      };

  factory AppliedEffects.fromJson(Map<String, dynamic> j) {
    final e = AppliedEffects();
    (j['stock'] as Map? ?? const {}).forEach(
      (k, v) => e.stock[k as String] = (v as num).toInt(),
    );
    final c = j['customer'] as Map?;
    if (c != null) {
      e.customerId = c['id'] as String;
      e.spend = (c['spend'] as num).toDouble();
      e.points = (c['points'] as num).toInt();
    }
    final m = j['mechanic'] as Map?;
    if (m != null) {
      e.mechanicId = m['id'] as String;
      e.mSales = (m['sales'] as num).toDouble();
      e.mDiscount = (m['discount'] as num).toDouble();
      e.mMarkup = (m['markup'] as num).toDouble();
      e.mCredit = (m['credit'] as num).toDouble();
    }
    e.voidedSaleId = j['voidedSaleId'] as String?;
    return e;
  }

  /// Writes the record for [opId]. Call inside the tx that queues the op.
  Future<void> record(AppDatabase db, String opId) => db
      .into(db.opEffects)
      .insert(OpEffectRow(opId: opId, effects: jsonEncode(toJson())));

  /// The record for [opId], or null for an op queued before schema v13.
  static Future<AppliedEffects?> load(AppDatabase db, String opId) async {
    final row = await (db.select(db.opEffects)
          ..where((t) => t.opId.equals(opId)))
        .getSingleOrNull();
    if (row == null) return null;
    return AppliedEffects.fromJson(
      jsonDecode(row.effects) as Map<String, dynamic>,
    );
  }

  static Future<void> forget(AppDatabase db, String opId) =>
      (db.delete(db.opEffects)..where((t) => t.opId.equals(opId))).go();

  /// Subtracts every recorded delta and clears [voidedSaleId]'s void. Exact,
  /// no clamp. Runs inside the caller's transaction. Stock is not `.stamped`,
  /// like the offline writes it undoes: `updatedAt` is the pull cursor, and a
  /// local clock pushes it past server changes it has not seen yet.
  Future<void> undo(AppDatabase db) async {
    for (final entry in stock.entries) {
      final p = await (db.select(db.products)
            ..where((t) => t.id.equals(entry.key)))
          .getSingleOrNull();
      if (p == null) continue;
      await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(
        ProductsCompanion(stock: Value(p.stock - entry.value)),
      );
    }
    if (customerId != null) {
      final c = await (db.select(db.customers)
            ..where((t) => t.id.equals(customerId!)))
          .getSingleOrNull();
      if (c != null) {
        await (db.update(db.customers)..where((t) => t.id.equals(c.id))).write(
          CustomersCompanion(
            totalSpend: Value(c.totalSpend - spend),
            points: Value(c.points - points),
          ),
        );
      }
    }
    if (mechanicId != null) {
      final m = await (db.select(db.mechanics)
            ..where((t) => t.id.equals(mechanicId!)))
          .getSingleOrNull();
      if (m != null) {
        await (db.update(db.mechanics)..where((t) => t.id.equals(m.id))).write(
          MechanicsCompanion(
            totalSales: Value(m.totalSales - mSales),
            totalDiscount: Value(m.totalDiscount - mDiscount),
            totalMarkup: Value(m.totalMarkup - mMarkup),
            creditBalance: Value(m.creditBalance - mCredit),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    }
    if (voidedSaleId != null) {
      await (db.update(db.sales)..where((t) => t.id.equals(voidedSaleId!)))
          .write(
        const SalesCompanion(
          voided: Value(false),
          voidedAt: Value(null),
          voidReason: Value(null),
        ),
      );
    }
  }
}
