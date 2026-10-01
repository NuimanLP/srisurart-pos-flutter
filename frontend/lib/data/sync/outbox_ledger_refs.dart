// Which customers / mechanics have unsent local work moving their running
// totals — the pull's ledger guard (the customer/mechanic twin of the 08 §15
// stock guard in `ApiProductsRepository.syncFromServer`).
//
// Every money-moving `outbox_ops` row (pending, stuck or rejected — rows
// [AppDatabase.hasUnsentWork] counts) and every legacy `pending_credit_payments`
// row is a write the server has not taken yet, so the server's totals do not
// include it. A pull must not overwrite the local totals of the rows it moved.
// `customer.create` / `customer.update` move no money and protect nothing.
//
// A customer/mechanic counts as referenced when it appears as:
//  • an `aggregates` entry `customer:<id>` / `mechanic:<id>`,
//  • a `customerId` / `mechanicId` value anywhere in the op's `payload`,
//  • the `customer.id` / `mechanic.id` of the op's `op_effects` (#488), or
//  • the customer/mechanic of a local sale named by a `sale:<id>` aggregate
//    (an offline return/void queued before schema v13 has no `op_effects`).
//
// Unparseable JSON is skipped: this guard can only add ids, never fail a pull.

import 'dart:convert';

import '../db/database.dart';

typedef LedgerRefs = ({Set<String> customers, Set<String> mechanics});

/// Op types that move a customer's or mechanic's running totals.
const _moneyOps = {
  'sale.create',
  'sale.void_offline',
  'return.create',
  'credit_payment.create',
};

Future<LedgerRefs> ledgerIdsInOutbox(AppDatabase db) async =>
    ledgerIdsIn(db, await db.select(db.outboxOps).get());

/// [ledgerIdsInOutbox] over [ops] only (e.g. the ops still left after one
/// was applied), plus the queued credit payments.
Future<LedgerRefs> ledgerIdsIn(AppDatabase db, List<OutboxOpRow> ops) async {
  final customers = <String>{};
  final mechanics = <String>{};
  final saleIds = <String>{};
  final money = [for (final op in ops) if (_moneyOps.contains(op.type)) op];

  for (final op in money) {
    try {
      final aggs = jsonDecode(op.aggregates);
      if (aggs is List) {
        for (final a in aggs) {
          if (a is! String) continue;
          if (a.startsWith('customer:')) {
            customers.add(a.substring('customer:'.length));
          } else if (a.startsWith('mechanic:')) {
            mechanics.add(a.substring('mechanic:'.length));
          } else if (a.startsWith('sale:')) {
            saleIds.add(a.substring('sale:'.length));
          }
        }
      }
    } catch (_) {}
    try {
      _collect(jsonDecode(op.payload), customers, mechanics);
    } catch (_) {}
  }
  final opIds = {for (final op in money) op.opId};
  final effects = opIds.isEmpty
      ? const <OpEffectRow>[]
      : await (db.select(db.opEffects)..where((t) => t.opId.isIn(opIds))).get();
  for (final e in effects) {
    try {
      final j = jsonDecode(e.effects);
      if (j is Map) {
        final c = j['customer'];
        if (c is Map && c['id'] != null) customers.add(c['id'].toString());
        final m = j['mechanic'];
        if (m is Map && m['id'] != null) mechanics.add(m['id'].toString());
      }
    } catch (_) {}
  }
  if (saleIds.isNotEmpty) {
    final sales =
        await (db.select(db.sales)..where((t) => t.id.isIn(saleIds))).get();
    for (final s in sales) {
      if (s.customerId != null) customers.add(s.customerId!);
      if (s.mechanicId != null) mechanics.add(s.mechanicId!);
    }
  }
  for (final p in await db.select(db.pendingCreditPayments).get()) {
    mechanics.add(p.mechanicId);
  }
  return (customers: customers, mechanics: mechanics);
}

void _collect(Object? node, Set<String> customers, Set<String> mechanics) {
  if (node is Map) {
    node.forEach((k, v) {
      if (k == 'customerId' && v != null) customers.add(v.toString());
      if (k == 'mechanicId' && v != null) mechanics.add(v.toString());
      _collect(v, customers, mechanics);
    });
  } else if (node is List) {
    for (final v in node) {
      _collect(v, customers, mechanics);
    }
  }
}

/// The earlier of two server `updatedAt` stamps (microsecond precision);
/// a value that is not a parseable string is ignored.
String? earlierStamp(Object? a, Object? b) {
  final da = a is String ? DateTime.tryParse(a) : null;
  final db = b is String ? DateTime.tryParse(b) : null;
  if (da == null) return db == null ? null : b as String;
  if (db == null) return a as String;
  return db.isBefore(da) ? b as String : a as String;
}
