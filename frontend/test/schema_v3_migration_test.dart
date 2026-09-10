// Schema v2 → v3 migration, run against a REAL v2 database file.
//
// This is the one change in schema v3 that can lose the shop's data:
// Shifts.id stops being an autoincrement integer and becomes TEXT, so both
// `shifts` and the `drawer_entries` that point at it are rebuilt by
// TableMigration. A fresh onCreate proves nothing here — the DDL below is the
// exact schema v2 emitted (dumped from sqlite_master before the change), and
// the assertions check that every drawer entry comes out attached to the same
// shift it went in with.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';

// Verbatim schema v2, as `sqlite_master` reported it on the commit before this
// migration. Do not tidy these strings — they are evidence, not source code.
const _v2Ddl = [
  'CREATE TABLE "shifts" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"date_str" TEXT NOT NULL, "starting_cash" REAL NOT NULL, '
      '"opened_at" INTEGER NOT NULL, "closed_at" INTEGER NULL, '
      '"physical_cash" REAL NULL, "is_active" INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("is_active" IN (0, 1)), "auto_archived" INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("auto_archived" IN (0, 1)), "archived_at" INTEGER NULL)',
  'CREATE TABLE "drawer_entries" ("id" TEXT NOT NULL, "shift_id" INTEGER NOT NULL '
      'REFERENCES shifts (id), "type" TEXT NOT NULL, "amount" REAL NOT NULL, '
      '"note" TEXT NULL, "created_at" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "sales" ("id" TEXT NOT NULL, "receipt_no" TEXT NOT NULL, '
      '"subtotal" REAL NOT NULL, "discount" REAL NOT NULL DEFAULT 0.0, '
      '"total" REAL NOT NULL, "payment_method" TEXT NOT NULL, '
      '"customer_id" TEXT NULL, "customer_name" TEXT NULL, "mechanic_id" TEXT NULL, '
      '"mechanic_name" TEXT NULL, "mechanic_delta" REAL NULL, '
      '"points_granted" INTEGER NOT NULL DEFAULT 0, "date" INTEGER NOT NULL, '
      '"voided" INTEGER NOT NULL DEFAULT 0 CHECK ("voided" IN (0, 1)), '
      '"voided_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "products" ("id" TEXT NOT NULL, "part_no" TEXT NOT NULL, '
      '"name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "category" TEXT NOT NULL, '
      '"brand" TEXT NOT NULL, "price" REAL NOT NULL, "cost" REAL NOT NULL, '
      '"stock" INTEGER NOT NULL, "min_stock" INTEGER NOT NULL, "compat" TEXT NULL, '
      '"zone" TEXT NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
];

/// Drift stores DateTime as unix **seconds** by default.
int _secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  late Directory dir;
  late File file;
  late AppDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sri_v2_');
    file = File('${dir.path}/app.sqlite');

    final v2 = raw.sqlite3.open(file.path);
    for (final ddl in _v2Ddl) {
      v2.execute(ddl);
    }
    // Two shifts: 1 = an archived day, 2 = the drawer that was left open.
    v2.execute(
      'INSERT INTO shifts (date_str, starting_cash, opened_at, closed_at, '
      'physical_cash, is_active, auto_archived, archived_at) VALUES '
      "('2026-09-01', 500.0, ${_secs(DateTime(2026, 9, 1, 8))}, "
      '${_secs(DateTime(2026, 9, 1, 18))}, 480.0, 0, 1, '
      '${_secs(DateTime(2026, 9, 2, 8))})',
    );
    v2.execute(
      'INSERT INTO shifts (date_str, starting_cash, opened_at, is_active) VALUES '
      "('2026-09-02', 1000.0, ${_secs(DateTime(2026, 9, 2, 8))}, 1)",
    );
    // Entries: one on the archived shift, two on the open one.
    v2.execute(
      'INSERT INTO drawer_entries (id, shift_id, type, amount, note, created_at) '
      "VALUES ('de1', 1, 'in', 200.0, 'ขายสด', ${_secs(DateTime(2026, 9, 1, 9))})",
    );
    v2.execute(
      'INSERT INTO drawer_entries (id, shift_id, type, amount, note, created_at) '
      "VALUES ('de2', 2, 'in', 300.0, NULL, ${_secs(DateTime(2026, 9, 2, 9))})",
    );
    v2.execute(
      'INSERT INTO drawer_entries (id, shift_id, type, amount, note, created_at) '
      "VALUES ('de3', 2, 'out', 50.0, 'ค่ากาแฟ', ${_secs(DateTime(2026, 9, 2, 10))})",
    );
    v2.execute(
      'INSERT INTO sales (id, receipt_no, subtotal, total, payment_method, date) '
      "VALUES ('s1', 'RC12345678ABCD', 100.0, 100.0, 'เงินสด', "
      '${_secs(DateTime(2026, 9, 2, 9, 30))})',
    );
    v2.execute(
      'INSERT INTO products (id, part_no, name, name_t_h, category, brand, price, '
      'cost, stock, min_stock) VALUES '
      "('p1', 'BP-001', 'Brake Pad', 'ผ้าเบรกหน้า', 'เบรก', 'TRW', 500.0, 300.0, 7, 2)",
    );
    v2.execute('PRAGMA user_version = 2');
    v2.close();

    db = AppDatabase(NativeDatabase(file));
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('upgrades a v2 file to v3 and keeps every shift', () async {
    final shifts = await (db.select(
      db.shifts,
    )..orderBy([(t) => OrderingTerm.asc(t.openedAt)])).get();

    expect(shifts.map((s) => s.id), ['1', '2']);
    expect(shifts.first.dateStr, '2026-09-01');
    expect(shifts.first.startingCash, 500.0);
    expect(shifts.first.isActive, isFalse);
    expect(shifts.first.autoArchived, isTrue);
    expect(shifts.first.physicalCash, 480.0);
    expect(shifts.first.closedAt, DateTime(2026, 9, 1, 18));
    expect(shifts.last.isActive, isTrue);
    expect(shifts.last.closedAt, isNull);

    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first)
        .getSingle();
    expect(version, 3);
  });

  test('every drawer entry stays attached to the shift it had', () async {
    final entries = await (db.select(
      db.drawerEntries,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

    expect(entries.length, 3);
    expect(
      {for (final e in entries) e.id: e.shiftId},
      {'de1': '1', 'de2': '2', 'de3': '2'},
    );
    // The amounts and Thai notes must survive the table rebuild too.
    expect(entries.map((e) => e.amount), [200.0, 300.0, 50.0]);
    expect(entries.map((e) => e.note), ['ขายสด', null, 'ค่ากาแฟ']);
  });

  test('the repository still reads the drawer through the new TEXT id', () async {
    final drawer = await ShiftsRepository(db).getCashDrawer();
    expect(drawer, isNotNull);
    expect(drawer!.shift.id, '2');
    // Newest first, per the repository contract.
    expect(drawer.entries.map((e) => e.id), ['de3', 'de2']);

    final history = await ShiftsRepository(db).getShiftHistory();
    expect(history.map((h) => h.shift.id), ['1']);
    expect(history.single.entries.map((e) => e.id), ['de1']);
  });

  test('a shift opened after the upgrade gets a newId and archives the old one',
      () async {
    final repo = ShiftsRepository(db);
    final fresh = await repo.openShift(2000);

    expect(fresh.id, startsWith('sh'));
    expect(fresh.id, isNot(anyOf('1', '2')));
    expect(fresh.isActive, isTrue);

    final prior = await (db.select(
      db.shifts,
    )..where((t) => t.id.equals('2'))).getSingle();
    expect(prior.isActive, isFalse);
    expect(prior.autoArchived, isTrue); // it was never closed

    // The archived shift keeps its entries; the new one starts empty.
    final drawer = await repo.getCashDrawer();
    expect(drawer!.shift.id, fresh.id);
    expect(drawer.entries, isEmpty);
  });

  test('the new columns arrive with the documented defaults', () async {
    final sale = await (db.select(
      db.sales,
    )..where((t) => t.id.equals('s1'))).getSingle();
    expect(sale.shiftId, isNull); // no bill written offline has one
    expect(sale.receiptNo, 'RC12345678ABCD');
    expect(sale.paymentMethod, 'เงินสด');

    final product = await (db.select(
      db.products,
    )..where((t) => t.id.equals('p1'))).getSingle();
    expect(product.offlineOk, isFalse); // unknown ⇒ not sellable offline
    expect(product.stock, 7);
    expect(product.nameTH, 'ผ้าเบรกหน้า');
  });
}
