// Patches an offline bill from its `sale.create` push reply (#455).
//
// Since #455 the `applied` reply for `sale.create` IS the `POST /sales` reply
// (08 §8.2): `date`, `shiftId`, `items[].costAtSale`, `movements[]`,
// `customerAfter` and `mechanicAfter`. The bill already sits in Drift — the till
// wrote it offline with `costAtSale` null, its own clock and its own ledger
// arithmetic — so this copies the server's numbers over it, exactly as
// `ApiSalesRepository._patchFromResponse` does for an online bill.
//
// ADR-0010 §3 applies verbatim: every value is read off the reply, and a field
// the reply does not carry (a key recorded before #455 still replays the thin
// shape for its 24 h) leaves its row alone — never "work it out locally".

import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../repositories/api/api_wire.dart';
import 'sync_service.dart';

/// Copies [response] onto the local rows of the bill [op] queued. Runs inside
/// the caller's transaction (the one that deletes [op]), so the patch and the
/// outbox delete land together or not at all.
///
/// [remainingOps] are the outbox ops still queued after [op]. A customer or
/// mechanic one of them names is left alone — their local running totals still
/// hold those ops' offline increments, which the server has not seen yet. Same
/// rule as the stock patch in `SyncService._patchAppliedEntity`.
Future<void> patchSaleFromPushReply(
  AppDatabase db,
  OutboxOpRow op,
  Map<String, dynamic>? response,
  List<OutboxOpRow> remainingOps,
) async {
  if (response == null || op.type != 'sale.create') return;
  final Object? payload;
  try {
    payload = jsonDecode(op.payload);
  } catch (_) {
    return;
  }
  if (payload is! Map) return;
  final saleId = payload['id'];
  if (saleId is! String) return;

  // Header: the date the server stored (clamped into the shift, 08 §10) and the
  // drawer it filed the bill under. A null `shiftId` (a bill predating #28)
  // does not wipe the local one.
  final date = response['date'];
  final shiftId = response['shiftId'];
  final header = SalesCompanion(
    date: date is String ? Value(stamp(date)) : const Value.absent(),
    shiftId: shiftId is String ? Value(shiftId) : const Value.absent(),
  );
  if (header != const SalesCompanion()) {
    await (db.update(db.sales)..where((t) => t.id.equals(saleId))).write(header);
  }

  // Lines: the cost the SERVER locked at the moment of sale (ADR-0008), joined
  // on `lineNo` — never `productId`, one bill can carry a product twice.
  // `SaleItems` has no `lineNo` column; `_saveOffline` inserts the lines in
  // payload order, so row order pairs each row with its payload line. Any
  // disagreement (count or product) leaves every cost null — `tables.dart`
  // defines null as "estimated", a wrong cost is worse.
  final costByLineNo = <int, double>{};
  for (final raw in (response['items'] as List? ?? const [])) {
    if (raw is! Map) continue;
    final lineNo = raw['lineNo'];
    final cost = moneyOrNull(raw['costAtSale']);
    if (lineNo is int && cost != null) costByLineNo[lineNo] = cost;
  }
  final payloadItems = payload['items'];
  if (costByLineNo.isNotEmpty && payloadItems is List) {
    final lines = await (db.select(db.saleItems)
          ..where((t) => t.saleId.equals(saleId))
          ..orderBy([(t) => OrderingTerm.asc(t.rowId)]))
        .get();
    final paired = lines.length == payloadItems.length &&
        [
          for (var i = 0; i < lines.length; i++)
            payloadItems[i] is Map &&
                (payloadItems[i] as Map)['productId'] == lines[i].productId,
        ].every((ok) => ok);
    if (paired) {
      for (var i = 0; i < lines.length; i++) {
        final cost = costByLineNo[(payloadItems[i] as Map)['lineNo']];
        if (cost == null) continue;
        await (db.update(db.saleItems)
              ..where((t) => t.rowId.equals(lines[i].rowId)))
            .write(SaleItemsCompanion(costAtSale: Value(cost)));
      }
    }
  }

  final pending = {
    for (final o in remainingOps) ...SyncService.parseAggregates(o.aggregates),
  };

  // Customer: points and spend as the server has them.
  final c = response['customerAfter'];
  if (c is Map && c['id'] is String && !pending.contains('customer:${c['id']}')) {
    final points = c['points'];
    final companion = CustomersCompanion(
      points: points is int ? Value(points) : const Value.absent(),
      totalSpend: keepMoney(moneyOrNull(c['totalSpend'])),
    );
    if (companion != const CustomersCompanion()) {
      await (db.update(db.customers)
            ..where((t) => t.id.equals(c['id'] as String)))
          .write(companion);
    }
  }

  // Mechanic: all four running totals as the server has them (never
  // `totalCredit`, the legacy alias the server does not move — #11).
  final m = response['mechanicAfter'];
  if (m is Map && m['id'] is String && !pending.contains('mechanic:${m['id']}')) {
    final companion = MechanicsCompanion(
      totalSales: keepMoney(moneyOrNull(m['totalSales'])),
      totalDiscount: keepMoney(moneyOrNull(m['totalDiscount'])),
      totalMarkup: keepMoney(moneyOrNull(m['totalMarkup'])),
      creditBalance: keepMoney(moneyOrNull(m['creditBalance'])),
    );
    if (companion != const MechanicsCompanion()) {
      await (db.update(db.mechanics)
            ..where((t) => t.id.equals(m['id'] as String)))
          .write(companion);
    }
  }

  // The สต็อก log rows the server wrote for this bill. The offline write adds
  // none, so there is nothing local to double; upsert so a replayed reply is a
  // no-op.
  final movements = response['movements'];
  if (movements is List && movements.isNotEmpty) {
    await db.batch((b) {
      b.insertAllOnConflictUpdate(db.movements, [
        for (final mv in movements)
          if (mv is Map) movementRowFromWire(mv.cast<String, dynamic>()),
      ]);
    });
  }
}
