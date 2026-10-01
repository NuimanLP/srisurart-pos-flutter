// Which products an unsent outbox op still points at (bulk delete guard).
//
// An `outbox_ops` row is deleted once the server applies it, so EVERY row left
// — `pending`, `stuck` or `rejected`, of any type — is a write the server has
// not taken yet. Its products must not disappear under it: the replay, and a
// discard's exact reversal (#488, `op_effects`), both need the product row.
//
// A product counts as referenced when it appears as:
//  • an `aggregates` entry `product:<id>`,
//  • any `productId` value anywhere in the op's `payload` JSON
//    (`sale.create` / `return.create` items), or
//  • a key of the op's recorded `op_effects.stock` deltas (offline void etc.).
//
// Unparseable JSON is skipped rather than thrown: this is a guard that can only
// add ids, never a reason to stop the screen.

import 'dart:convert';

import '../db/database.dart';

Future<Set<String>> productIdsInOutbox(AppDatabase db) async {
  final ids = <String>{};
  for (final op in await db.select(db.outboxOps).get()) {
    try {
      final aggs = jsonDecode(op.aggregates);
      if (aggs is List) {
        for (final a in aggs) {
          if (a is String && a.startsWith('product:')) {
            ids.add(a.substring('product:'.length));
          }
        }
      }
    } catch (_) {}
    try {
      _collectProductIds(jsonDecode(op.payload), ids);
    } catch (_) {}
  }
  for (final e in await db.select(db.opEffects).get()) {
    try {
      final j = jsonDecode(e.effects);
      if (j is Map && j['stock'] is Map) {
        for (final k in (j['stock'] as Map).keys) {
          ids.add(k.toString());
        }
      }
    } catch (_) {}
  }
  return ids;
}

void _collectProductIds(Object? node, Set<String> out) {
  if (node is Map) {
    node.forEach((k, v) {
      if (k == 'productId' && v != null) out.add(v.toString());
      _collectProductIds(v, out);
    });
  } else if (node is List) {
    for (final v in node) {
      _collectProductIds(v, out);
    }
  }
}
