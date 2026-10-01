// The db.js demo seed (products/customers/mechanics/suppliers) belongs to the
// Drift-only build only. On the API build (`USE_API_WRITES`) a fresh DB is an
// empty shop, and an existing seeded DB has its untouched seed purged on open
// — never while unsent local work exists.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/snapshot_repository.dart';

Future<Map<String, int>> _counts(AppDatabase db) async => {
  'products': (await db.select(db.products).get()).length,
  'customers': (await db.select(db.customers).get()).length,
  'mechanics': (await db.select(db.mechanics).get()).length,
  'suppliers': (await db.select(db.suppliers).get()).length,
  'categories': (await db.select(db.categories).get()).length,
  'settings': (await db.select(db.settingsRow).get()).length,
};

const _seeded = {
  'products': 12,
  'customers': 3,
  'mechanics': 3,
  'suppliers': 6,
  'categories': 5,
  'settings': 1,
};
const _empty = {
  'products': 0,
  'customers': 0,
  'mechanics': 0,
  'suppliers': 0,
  'categories': 5,
  'settings': 1,
};

void main() {
  test('Drift-only build (default) still seeds the demo data', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await _counts(db), _seeded);
  });

  test('API build: a fresh DB has no demo business data', () async {
    final db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    addTearDown(db.close);
    expect(await _counts(db), _empty);
    // Marked seed-free at create, so the purge never runs on it.
    final marker = await (db.select(
      db.appMeta,
    )..where((t) => t.key.equals(AppDatabase.demoSeedPurgedKey))).get();
    expect(marker, hasLength(1));
    expect(await db.purgeDemoSeed(), isNull);
  });

  group('API build opening a DB that was seeded earlier', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sri_seed_');
      file = File('${dir.path}/app.sqlite');
      // An older build / the Drift build created it with the seed.
      final old = AppDatabase(NativeDatabase(file));
      expect(await _counts(old), _seeded);
      await old.close();
    });
    tearDown(() => dir.delete(recursive: true));

    Future<AppDatabase> withRaw(
      Future<void> Function(AppDatabase) before,
    ) async {
      final db = AppDatabase(NativeDatabase(file));
      await before(db);
      await db.close();
      final api = AppDatabase(NativeDatabase(file), seedDemoData: false);
      addTearDown(api.close);
      return api;
    }

    test('purges the untouched seed on open', () async {
      final api = AppDatabase(NativeDatabase(file), seedDemoData: false);
      addTearDown(api.close);
      expect(await _counts(api), _empty);
      // One-time: marked, a second run does not run at all.
      expect(await api.purgeDemoSeed(), isNull);
    });

    test('keeps everything while an outbox op is unsent', () async {
      for (final status in ['pending', 'stuck', 'rejected']) {
        final api = await withRaw((db) async {
          await db.delete(db.outboxOps).go();
          await db
              .into(db.outboxOps)
              .insert(
                OutboxOpsCompanion.insert(
                  opId: 'op1',
                  idempotencyKey: 'k1',
                  type: 'sale.create',
                  payload: '{"id":"s1","items":[{"productId":"p1"}]}',
                  aggregates: '["product:p1"]',
                  createdAt: DateTime.utc(2026, 10, 1),
                  status: status,
                ),
              );
        });
        expect(await _counts(api), _seeded, reason: status);
        await api.close();
      }
    });

    test('keeps everything while a credit payment is queued, purges once it '
        'is gone', () async {
      final api = await withRaw((db) async {
        await db
            .into(db.pendingCreditPayments)
            .insert(
              PendingCreditPaymentsCompanion.insert(
                id: 'cp1',
                idempotencyKey: 'k1',
                mechanicId: 'm1',
                amount: '500.00',
                paymentMethod: 'เงินสด',
                createdAt: DateTime.utc(2026, 10, 1),
              ),
            );
      });
      expect(await _counts(api), _seeded);
      expect(await api.purgeDemoSeed(), isNull);

      await api.delete(api.pendingCreditPayments).go();
      expect(await api.purgeDemoSeed(), 12 + 3 + 3 + 6);
      expect(await _counts(api), _empty);
    });

    test(
      'keeps a seed-id row the server sent or a local edit stamped',
      () async {
        final stamp = DateTime.utc(2026, 9, 30);
        final api = await withRaw((db) async {
          // A tenant that imported a legacy backup really owns p1 (pull
          // upserts it with the server's updatedAt) …
          await (db.update(db.products)..where((t) => t.id.equals('p1'))).write(
            ProductsCompanion(updatedAt: Value(stamp)),
          );
          // … and an edited customer/mechanic carries a stamp too.
          await (db.update(db.customers)..where((t) => t.id.equals('c1')))
              .write(CustomersCompanion(updatedAt: Value(stamp)));
          await (db.update(db.mechanics)..where((t) => t.id.equals('m1')))
              .write(MechanicsCompanion(updatedAt: Value(stamp)));
        });
        final ids = (await api.select(api.products).get()).map((r) => r.id);
        expect(ids, ['p1']);
        expect((await api.select(api.customers).get()).map((r) => r.id), [
          'c1',
        ]);
        expect((await api.select(api.mechanics).get()).map((r) => r.id), [
          'm1',
        ]);
        // Suppliers of the kept product stay; the rest went with theirs.
        expect(
          (await api.select(api.suppliers).get()).map((r) => r.id).toSet(),
          {'sup1', 'sup2'},
        );
      },
    );

    test('a backup restored after the purge survives the next open', () async {
      // A legacy backup carrying the db.js seed ids with no updatedAt — the
      // shape the real shop's JS export has.
      final src = AppDatabase(NativeDatabase.memory());
      final backup = await SnapshotRepository(src).exportSnapshot();
      await src.close();

      var api = AppDatabase(NativeDatabase(file), seedDemoData: false);
      expect(await _counts(api), _empty); // purged + marked
      await SnapshotRepository(api).importLegacyBackup(backup);
      expect(await _counts(api), _seeded);
      await api.close();

      api = AppDatabase(NativeDatabase(file), seedDemoData: false);
      addTearDown(api.close);
      expect(await _counts(api), _seeded);
    });

    test('a backup restored while the purge is still blocked is never purged '
        'later', () async {
      final src = AppDatabase(NativeDatabase.memory());
      final backup = await SnapshotRepository(src).exportSnapshot();
      await src.close();

      final api = await withRaw((db) async {
        await db
            .into(db.pendingCreditPayments)
            .insert(
              PendingCreditPaymentsCompanion.insert(
                id: 'cp1',
                idempotencyKey: 'k1',
                mechanicId: 'm1',
                amount: '500.00',
                paymentMethod: 'เงินสด',
                createdAt: DateTime.utc(2026, 10, 1),
              ),
            );
      });
      await SnapshotRepository(api).importLegacyBackup(backup);
      await api.delete(api.pendingCreditPayments).go();
      expect(await api.purgeDemoSeed(), isNull);
      expect(await _counts(api), _seeded);
    });
  });
}
