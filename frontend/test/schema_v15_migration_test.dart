// Schema v14 → v15 migration test (product images, owner 2026-10-10).
//
// v15 adds products.image_key, so a v14 file is a fresh v15 file with that
// column dropped and user_version set back to 14. Opening it must keep every
// product and add the column as NULL; a key then round-trips.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

void main() {
  test('v14 → v15 adds products.image_key as NULL and keeps every product',
      () async {
    final rawDb = raw.sqlite3.openInMemory();
    final seed = AppDatabase(
      NativeDatabase.opened(rawDb, closeUnderlyingOnClose: false),
    );
    final before = await seed.select(seed.products).get(); // runs onCreate
    await seed.close();
    expect(before, isNotEmpty);
    rawDb.execute('ALTER TABLE products DROP COLUMN image_key');
    rawDb.execute('PRAGMA user_version = 14');

    final db = AppDatabase(NativeDatabase.opened(rawDb));
    addTearDown(db.close);

    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first as int)
        .getSingle();
    expect(version, 15);
    final after = await db.select(db.products).get();
    expect(after.map((p) => p.id), before.map((p) => p.id));
    expect(after.map((p) => p.stock), before.map((p) => p.stock));
    expect(after.every((p) => p.imageKey == null), isTrue);

    const key = 'aaaaaaaabbbbbbbbccccccccdddddddd';
    await (db.update(db.products)..where((t) => t.id.equals(after.first.id)))
        .write(const ProductsCompanion(imageKey: Value(key)));
    final row = await (db.select(db.products)
          ..where((t) => t.id.equals(after.first.id)))
        .getSingle();
    expect(row.imageKey, key);
  });
}
