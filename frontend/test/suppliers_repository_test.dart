// Unit tests for SuppliersRepository.
//
// Invariants under test (db.js sa_suppliers parity):
//  • SEED_SUPPLIERS (6 rows) is seeded by AppDatabase.onCreate.
//  • getSuppliersForProduct filters by productId.
//  • addSupplier assigns id via newId('sup') and defaults freight to 0.
//  • updateSupplier patches ONLY the passed fields (Value.absent semantics).
//  • deleteSupplier removes the row.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/suppliers_repository.dart';

void main() {
  late AppDatabase db;
  late SuppliersRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SuppliersRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'seed data: 6 suppliers, getSuppliersForProduct filters by product',
    () async {
      expect(await repo.getSuppliers(), hasLength(6));

      final forP1 = await repo.getSuppliersForProduct('p1');
      expect(forP1.map((s) => s.name).toSet(), {
        'Honda Parts Center',
        'Auto Zone TH',
      });

      expect(await repo.getSuppliersForProduct('no_such_product'), isEmpty);
    },
  );

  test(
    'addSupplier assigns sup-prefixed id and defaults freight to 0',
    () async {
      final row = await repo.addSupplier(
        productId: 'p3',
        name: 'ร้านอะไหล่ตลาดใหม่',
        unitCost: 99.5,
      );

      expect(row.id, startsWith('sup'));
      expect(row.freight, 0);

      final stored = (await repo.getSuppliersForProduct('p3')).single;
      expect(stored.name, 'ร้านอะไหล่ตลาดใหม่');
      expect(stored.unitCost, 99.5);
      expect(stored.freight, 0);
    },
  );

  test('updateSupplier patches only the passed fields', () async {
    final row = await repo.addSupplier(
      productId: 'p3',
      name: 'Original Name',
      unitCost: 100,
      freight: 12,
    );

    await repo.updateSupplier(row.id, unitCost: const Value(85));

    final patched = (await repo.getSuppliersForProduct('p3')).single;
    expect(patched.unitCost, 85);
    // Untouched fields keep their values.
    expect(patched.name, 'Original Name');
    expect(patched.freight, 12);
    expect(patched.productId, 'p3');
  });

  test('deleteSupplier removes the row; unknown id is a no-op', () async {
    final row = await repo.addSupplier(
      productId: 'p3',
      name: 'To Delete',
      unitCost: 10,
    );
    expect(await repo.getSuppliers(), hasLength(7));

    await repo.deleteSupplier(row.id);
    expect(await repo.getSuppliers(), hasLength(6));
    expect(await repo.getSuppliersForProduct('p3'), isEmpty);

    await repo.deleteSupplier('sup_does_not_exist');
    expect(await repo.getSuppliers(), hasLength(6));
  });
}
