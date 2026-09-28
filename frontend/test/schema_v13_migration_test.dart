// Schema v12 → v13 migration test (#488: op_effects).
//
// v13 only adds the op_effects table, so a v12 file is a fresh v13 file with
// that table dropped and user_version set back to 12. Opening it must create
// the table empty and keep a queued op — which then has no record and takes
// discard's legacy path.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

void main() {
  test('v12 → v13 creates op_effects empty and keeps queued ops', () async {
    final rawDb = raw.sqlite3.openInMemory();
    final seed = AppDatabase(
      NativeDatabase.opened(rawDb, closeUnderlyingOnClose: false),
    );
    await seed.customSelect('SELECT 1').get(); // run onCreate
    await seed.close();
    rawDb.execute('DROP TABLE op_effects');
    rawDb.execute(
      "INSERT INTO outbox_ops (op_id, idempotency_key, type, payload, "
      "aggregates, created_at, status) VALUES "
      "('op-old', 'k-old', 'sale.create', '{\"id\":\"s1\"}', '[]', 0, 'stuck')",
    );
    rawDb.execute('PRAGMA user_version = 12');

    final db = AppDatabase(NativeDatabase.opened(rawDb));
    addTearDown(db.close);

    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first as int)
        .getSingle();
    expect(version, 13);
    expect(await db.select(db.opEffects).get(), isEmpty);
    expect((await db.select(db.outboxOps).getSingle()).opId, 'op-old');

    await db
        .into(db.opEffects)
        .insert(const OpEffectRow(opId: 'op-new', effects: '{}'));
    expect(await db.select(db.opEffects).get(), hasLength(1));
  });
}
