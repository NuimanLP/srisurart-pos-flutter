// SuppliersRepository — per-product suppliers (sa_suppliers in db.js).
//
// db.js methods ported:
//   getSuppliers()                    → all suppliers
//   getSuppliersForProduct(productId) → suppliers filtered by productId
//   addSupplier(s)   → inserts { ...s, id:_newId('sup') } and returns it
//   updateSupplier(id, data)          → patch
//   deleteSupplier(id)                → remove
//
// SEED_SUPPLIERS is seeded by AppDatabase.onCreate (NOT here).
// FULLY IMPLEMENTED (low-risk, other agents depend on it).

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../db/database.dart';

class SuppliersRepository {
  final AppDatabase db;
  SuppliersRepository(this.db);

  Future<List<SupplierRow>> getSuppliers() => db.select(db.suppliers).get();

  Future<List<SupplierRow>> getSuppliersForProduct(String productId) {
    return (db.select(db.suppliers)
          ..where((t) => t.productId.equals(productId)))
        .get();
  }

  /// Insert a supplier (id from newId('sup')) and return the stored row.
  Future<SupplierRow> addSupplier({
    required String productId,
    required String name,
    required double unitCost,
    double freight = 0,
  }) async {
    final row = SupplierRow(
      id: newId('sup'),
      productId: productId,
      name: name,
      unitCost: unitCost,
      freight: freight,
    );
    await db.into(db.suppliers).insert(row);
    return row;
  }

  /// Patch a supplier by id. Pass only the fields to change (Value.absent for rest).
  Future<void> updateSupplier(
    String id, {
    Value<String> productId = const Value.absent(),
    Value<String> name = const Value.absent(),
    Value<double> unitCost = const Value.absent(),
    Value<double> freight = const Value.absent(),
  }) async {
    await (db.update(db.suppliers)..where((t) => t.id.equals(id))).write(
      SuppliersCompanion(
        productId: productId,
        name: name,
        unitCost: unitCost,
        freight: freight,
      ),
    );
  }

  Future<void> deleteSupplier(String id) async {
    await (db.delete(db.suppliers)..where((t) => t.id.equals(id))).go();
  }
}
