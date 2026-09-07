// ParkedRepository — parked / held bills (sa_parked).
//
// Implementation owned by the **Parked service agent**.
//
// db.js methods ported (parked bills are cart snapshots only, NEVER touch stock):
//  • getParked()          → all parked bills newest-first.
//  • parkSale(ParkedInput) → id newId('pk'), parkedAt now. The cart blob is
//    serialized into ParkedSales.payload (JSON string). Returns the ParkedSaleRow.
//  • deleteParked(id)     → remove.
//
// db.js (lines 387-395):
//   getParked() { return this.get(DB_KEYS.parked) || []; }
//   parkSale(data) {
//     const all = this.getParked();
//     const newP = { ...data, id: _newId('pk'), parkedAt: new Date().toISOString() };
//     this.set(DB_KEYS.parked, [newP, ...all]);   // prepend → newest first
//     return newP;
//   }
//   deleteParked(id) { ...filter(p => p.id !== id) }
//
// In Drift the cart blob (items + customer/mechanic/discount + extra) is stored
// as a JSON string in ParkedSales.payload, and the timestamp lives in the
// dedicated ParkedSales.parkedAt DateTime column. The JSON payload also carries
// a `parkedAt` ISO string to stay byte-parity with the legacy localStorage shape
// the CheckoutScreen consumes when it decodes the blob.
//
// NOTE: resume-time stock re-validation lives in the CheckoutScreen
// (validateItems), NOT here — this repo only stores/loads/deletes snapshots.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';

class ParkedRepository {
  final AppDatabase db;
  ParkedRepository(this.db);

  /// All parked bills, newest first.
  /// db.js prepends new entries to an array → newest-first by insertion order.
  /// We order by parkedAt desc, then by the implicit monotonic rowid desc as a
  /// deterministic tiebreaker (two parks in the same millisecond keep insertion
  /// order: the later insert — higher rowid — comes first).
  Future<List<ParkedSaleRow>> getParked() {
    return (db.select(db.parkedSales)..orderBy([
          (t) => OrderingTerm.desc(t.parkedAt),
          (t) => OrderingTerm.desc(t.rowId),
        ]))
        .get();
  }

  /// Park a cart snapshot. Assigns id via newId('pk') and parkedAt = now.
  /// The cart blob is serialized into the payload JSON string. Returns the row.
  Future<ParkedSaleRow> parkSale(ParkedInput input) async {
    final id = newId('pk');
    final parkedAt = DateTime.now();

    // Build the cart blob exactly like the JS `{ ...data, id, parkedAt }` object,
    // serialized as JSON so the CheckoutScreen can decode it back verbatim.
    final blob = <String, dynamic>{
      // Caller-supplied extra cart-state fields first; explicit fields below
      // win on key collision so the modeled shape is authoritative.
      ...input.extra,
      'items': input.items
          .map(
            (it) => <String, dynamic>{
              'productId': it.productId,
              'name': it.name,
              'qty': it.qty,
              'price': it.price,
              if (it.partNo != null) 'partNo': it.partNo,
              if (it.nameTH != null) 'nameTH': it.nameTH,
            },
          )
          .toList(),
      'customerId': input.customerId,
      'customerName': input.customerName,
      'mechanicId': input.mechanicId,
      'mechanicName': input.mechanicName,
      'discount': input.discount,
      'id': id,
      'parkedAt': parkedAt.toIso8601String(),
    };

    final row = ParkedSaleRow(
      id: id,
      parkedAt: parkedAt,
      payload: jsonEncode(blob),
    );
    await db.into(db.parkedSales).insert(row);
    return row;
  }

  /// Remove a parked bill by id.
  /// db.js: filter(p => p.id !== id).
  Future<void> deleteParked(String id) async {
    await (db.delete(db.parkedSales)..where((t) => t.id.equals(id))).go();
  }
}
