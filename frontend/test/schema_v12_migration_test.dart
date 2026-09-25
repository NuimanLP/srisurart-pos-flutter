// Schema v11 → v12 migration test (#417: Drift indexes).
//
// v12 only adds indexes, so a v11 file is a fresh v12 file with the indexes
// dropped and user_version set back to 11. Opening it must create every index
// a fresh install gets, keep existing rows, and let the hot lookups use them.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

const _expectedIndexes = {
  'idx_products_part_no_lower',
  'idx_products_part_no',
  'idx_sales_date',
  'idx_sale_items_sale_id',
  'idx_po_items_po_id',
  'idx_returns_sale_id',
  'idx_return_items_return_id',
  'idx_quote_items_quote_id',
  'idx_suppliers_product_id',
  'idx_drawer_entries_shift_id',
};

Future<Set<String>> _indexNames(AppDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name NOT LIKE 'sqlite_autoindex_%'",
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<String> _plan(AppDatabase db, GenerationContext ctx) async {
  final rows = await db
      .customSelect(
        'EXPLAIN QUERY PLAN ${ctx.sql}',
        variables: [for (final v in ctx.boundVariables) Variable(v)],
      )
      .get();
  return rows.map((r) => r.read<String>('detail')).join('\n');
}

void main() {
  test('a fresh install gets every #417 index', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await _indexNames(db), containsAll(_expectedIndexes));
  });

  test('v11 → v12 creates the indexes, keeps rows, and the planner uses them',
      () async {
    // Build a v11 file: fresh schema, minus the v12 indexes, one product row.
    final rawDb = raw.sqlite3.openInMemory();
    final seed = AppDatabase(
      NativeDatabase.opened(rawDb, closeUnderlyingOnClose: false),
    );
    final freshIndexes = await _indexNames(seed);
    await seed.close();
    for (final name in _expectedIndexes) {
      rawDb.execute('DROP INDEX $name');
    }
    rawDb.execute(
      "INSERT INTO products (id, part_no, name, name_t_h, category, brand, "
      "price, cost, stock, min_stock) VALUES "
      "('px', 'AB-123', 'Pad', 'ผ้าเบรก', 'เบรก', 'X', 10, 5, 3, 1)",
    );
    rawDb.execute('PRAGMA user_version = 11');
    final stripped = rawDb.select(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name LIKE 'idx_%'",
    );
    expect(stripped, isEmpty);

    final db = AppDatabase(NativeDatabase.opened(rawDb));
    addTearDown(db.close);

    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first as int)
        .getSingle();
    expect(version, 12);

    // Upgraded file has exactly the indexes a fresh install has.
    expect(await _indexNames(db), freshIndexes);
    for (final t in ['products', 'sales', 'sale_items', 'returns']) {
      final list = await db.customSelect('PRAGMA index_list($t)').get();
      expect(list, isNotEmpty, reason: '$t has no index');
    }

    final p = await (db.select(db.products)
          ..where((t) => t.partNo.lower().equals('ab-123')))
        .getSingle();
    expect(p.id, 'px');

    // The exact Drift queries the repositories issue hit the indexes.
    expect(
      await _plan(
        db,
        (db.select(db.products)
              ..where((t) => t.partNo.lower().equals('ab-123')))
            .constructQuery(),
      ),
      contains('idx_products_part_no_lower'),
    );
    expect(
      await _plan(
        db,
        (db.select(db.products)..where((t) => t.partNo.equals('AB-123')))
            .constructQuery(),
      ),
      contains('idx_products_part_no ('), // not the _lower one
    );
    expect(
      await _plan(
        db,
        (db.select(db.saleItems)..where((t) => t.saleId.equals('s1')))
            .constructQuery(),
      ),
      contains('idx_sale_items_sale_id'),
    );
    expect(
      await _plan(
        db,
        (db.select(db.returns)..where((t) => t.saleId.equals('s1')))
            .constructQuery(),
      ),
      contains('idx_returns_sale_id'),
    );
  });
}
