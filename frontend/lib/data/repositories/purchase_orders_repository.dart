// PurchaseOrdersRepository — purchase orders (sa_pos + sa_po_items).
//
// Ported from pos/db.js lines 443-485. Behaviour parity with the JS data layer:
//  • getPOs()                → all POs newest-first (with items).
//  • savePO(PoInput)         → id newId('po'), poNo docNo('PO'), createdAt now,
//                              status 'open'. Returns the PurchaseOrderRow.
//  • receivePO(id)           → WEIGHTED-AVERAGE cost. Returns List<String> of
//    UNMATCHED partNos. For each line whose partNo matches a product
//    (case-insensitive):
//      wac = round2((oldStock*oldCost + newQty*newCost) / (oldStock+newQty))
//      (newCost = item.cost>0 ? item.cost : oldCost; if totalQty==0 → newCost)
//      update product { stock: totalQty, cost: wac }; add a 'receive' movement
//      note: 'PO <poNo> จาก <supplier> · ทุนใหม่ ฿<wac>'. Then mark PO
//      status='received', receivedAt=now. Wrapped in a transaction.
//  • cancelPO(id)            → status='cancelled', cancelledAt=now.
//  • deletePO(id)            → remove PO (and its items).

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../../core/utils/money.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';

/// Renders a [round2] result the way JS interpolates a number into a template
/// literal: `120.0` → `"120"`, `133.33` → `"133.33"`. db.js writes the raw
/// number into the movement note, so an integer-valued cost must NOT carry a
/// trailing `.0` (behaviour parity for the Thai movement note string).
String _jsNum(double v) {
  if (v == v.truncateToDouble() && v.isFinite) {
    return v.toInt().toString();
  }
  return v.toString();
}

class PurchaseOrdersRepository {
  final AppDatabase db;
  PurchaseOrdersRepository(this.db);

  /// All purchase orders, newest first (db.js prepends new POs).
  Future<List<PurchaseOrderWithItems>> getPOs() async {
    final pos = await (db.select(
      db.purchaseOrders,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    final result = <PurchaseOrderWithItems>[];
    for (final po in pos) {
      final items = await (db.select(
        db.poItems,
      )..where((t) => t.poId.equals(po.id))).get();
      result.add(PurchaseOrderWithItems(po, items));
    }
    return result;
  }

  /// Create a new PO. Mirrors db.js savePO: id newId('po'), poNo docNo('PO'),
  /// createdAt now, status 'open'.
  Future<PurchaseOrderRow> savePO(PoInput input) async {
    final id = newId('po');
    final poNo = docNo('PO');
    final createdAt = DateTime.now();
    final po = PurchaseOrderRow(
      id: id,
      poNo: poNo,
      supplier: input.supplier,
      status: 'open',
      createdAt: createdAt,
    );
    await db.transaction(() async {
      await db.into(db.purchaseOrders).insert(po);
      for (final item in input.items) {
        await db
            .into(db.poItems)
            .insert(
              PoItemsCompanion.insert(
                poId: id,
                partNo: item.partNo,
                name: item.name,
                qty: item.qty,
                cost: item.cost,
              ),
            );
      }
    });
    return po;
  }

  /// Receives stock via weighted-average cost. Returns the unmatched partNos.
  /// Mirrors db.js receivePO: per item, match a product by partNo
  /// (case-insensitive); if found, recompute weighted-average cost and write a
  /// 'receive' movement; otherwise collect the partNo as unmatched. Marks the PO
  /// 'received'. The whole operation runs in a transaction (atomic like the JS
  /// snapshot/rollback).
  Future<List<String>> receivePO(String id) async {
    return db.transaction(() async {
      final po = await (db.select(
        db.purchaseOrders,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (po == null) return <String>[];

      final items = await (db.select(
        db.poItems,
      )..where((t) => t.poId.equals(id))).get();

      final unmatched = <String>[];
      for (final item in items) {
        // Match product by partNo, case-insensitive (db.js toLowerCase compare).
        final allProducts = await db.select(db.products).get();
        final partNoLower = item.partNo.toLowerCase();
        ProductRow? p;
        for (final prod in allProducts) {
          if (prod.partNo.toLowerCase() == partNoLower) {
            p = prod;
            break;
          }
        }

        if (p != null) {
          // Weighted-average cost: (oldQty*oldCost + newQty*newCost)/(oldQty+newQty).
          // Prevents 1 expensive PO unit from corrupting unit cost of existing units.
          final oldStock = p.stock;
          final oldCost = p.cost;
          final newQty = item.qty;
          final newCost = item.cost > 0 ? item.cost : oldCost;
          final totalQty = oldStock + newQty;
          final wac = totalQty > 0
              ? round2((oldStock * oldCost + newQty * newCost) / totalQty)
              : newCost;

          await (db.update(
            db.products,
          )..where((t) => t.id.equals(p!.id))).write(
            ProductsCompanion(
              stock: Value(totalQty),
              cost: Value(wac),
              updatedAt: Value(DateTime.now()),
            ),
          );

          await db
              .into(db.movements)
              .insert(
                MovementRow(
                  id: newId('mv'),
                  productId: p.id,
                  partNo: p.partNo,
                  name: p.name,
                  delta: newQty,
                  type: 'receive',
                  note:
                      'PO ${po.poNo} จาก ${po.supplier} · ทุนใหม่ ฿${_jsNum(wac)}',
                  stockAfter: totalQty,
                  date: DateTime.now(),
                ),
              );
        } else {
          unmatched.add(item.partNo);
        }
      }

      await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
        PurchaseOrdersCompanion(
          status: const Value('received'),
          receivedAt: Value(DateTime.now()),
        ),
      );

      return unmatched;
    });
  }

  /// Cancel a PO. Mirrors db.js cancelPO: status 'cancelled', cancelledAt now.
  Future<void> cancelPO(String id) async {
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
      PurchaseOrdersCompanion(
        status: const Value('cancelled'),
        cancelledAt: Value(DateTime.now()),
      ),
    );
  }

  /// Delete a PO and its items. Mirrors db.js deletePO (filters it out).
  Future<void> deletePO(String id) async {
    await db.transaction(() async {
      await (db.delete(db.poItems)..where((t) => t.poId.equals(id))).go();
      await (db.delete(db.purchaseOrders)..where((t) => t.id.equals(id))).go();
    });
  }
}
