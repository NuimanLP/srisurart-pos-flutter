// Schema v1 → v3 in one open, run against a REAL v1 database file.
//
// `schema_v3_migration_test.dart` covers the v2 → v3 hop. This file covers the
// double hop, which is the one the shop can actually hit: schema v2 landed on
// 2026-09-04, so any browser whose IndexedDB was last written before that is
// still on v1 and will run `from < 2` and `from < 3` back to back on the first
// boot of a v3 build. The two blocks touch disjoint tables — v2 adds sync
// columns to customers/mechanics/settings_row/sale_items, v3 rebuilds
// shifts/drawer_entries and adds columns to sales/products — and this test is
// what holds them disjoint.
//
// The DDL below is schema v1 exactly as `sqlite_master` reported it at
// 21e7434^ (the commit before "feat(db): schema v2"). Do not tidy these
// strings — they are evidence, not source code.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';

const _v1Ddl = [
  // ── touched by the v2 block (sync bookkeeping + cost at sale) ──
  'CREATE TABLE "customers" ("id" TEXT NOT NULL, "code" TEXT NOT NULL, '
      '"name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "phone" TEXT NULL, '
      '"address" TEXT NULL, "points" INTEGER NOT NULL DEFAULT 0, '
      '"total_spend" REAL NOT NULL DEFAULT 0.0, "created_at" TEXT NOT NULL, '
      'PRIMARY KEY ("id"))',
  'CREATE TABLE "mechanics" ("id" TEXT NOT NULL, "code" TEXT NOT NULL, '
      '"name" TEXT NOT NULL, "name_t_h" TEXT NULL, "nickname" TEXT NULL, '
      '"shop_name" TEXT NULL, "phone" TEXT NULL, "note" TEXT NULL, '
      '"credit_limit" REAL NOT NULL DEFAULT 0.0, '
      '"credit_balance" REAL NOT NULL DEFAULT 0.0, '
      '"total_sales" REAL NOT NULL DEFAULT 0.0, '
      '"total_credit" REAL NOT NULL DEFAULT 0.0, '
      '"total_discount" REAL NOT NULL DEFAULT 0.0, '
      '"total_markup" REAL NOT NULL DEFAULT 0.0, "created_at" TEXT NOT NULL, '
      'PRIMARY KEY ("id"))',
  'CREATE TABLE "settings_row" ("id" INTEGER NOT NULL, "shop_name" TEXT NOT NULL, '
      '"shop_name_e_n" TEXT NOT NULL, "tax_rate" REAL NOT NULL DEFAULT 7.0, '
      '"quote_valid_days" INTEGER NOT NULL DEFAULT 30, "address" TEXT NULL, '
      '"phone" TEXT NULL, "cashier_name" TEXT NULL, "tax_id" TEXT NULL, '
      '"branch_no" TEXT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "sale_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"sale_id" TEXT NOT NULL REFERENCES sales (id), "product_id" TEXT NOT NULL, '
      '"part_no" TEXT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NULL, '
      '"qty" INTEGER NOT NULL, "price" REAL NOT NULL)',
  // ── touched by the v3 block ──
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
  // v1 products already carried updated_at — v2 never touched this table.
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
    dir = await Directory.systemTemp.createTemp('sri_v1_');
    file = File('${dir.path}/app.sqlite');

    final v1 = raw.sqlite3.open(file.path);
    for (final ddl in _v1Ddl) {
      v1.execute(ddl);
    }
    // Two shifts: 1 = an archived day, 2 = the drawer left open.
    v1.execute(
      'INSERT INTO shifts (date_str, starting_cash, opened_at, closed_at, '
      'physical_cash, is_active, auto_archived, archived_at) VALUES '
      "('2026-08-30', 500.0, ${_secs(DateTime(2026, 8, 30, 8))}, "
      '${_secs(DateTime(2026, 8, 30, 18))}, 470.0, 0, 1, '
      '${_secs(DateTime(2026, 8, 31, 8))})',
    );
    v1.execute(
      'INSERT INTO shifts (date_str, starting_cash, opened_at, is_active) VALUES '
      "('2026-08-31', 1200.0, ${_secs(DateTime(2026, 8, 31, 8))}, 1)",
    );
    v1.execute(
      'INSERT INTO drawer_entries (id, shift_id, type, amount, note, created_at) '
      "VALUES ('de1', 1, 'in', 250.0, 'ขายสด', ${_secs(DateTime(2026, 8, 30, 9))})",
    );
    v1.execute(
      'INSERT INTO drawer_entries (id, shift_id, type, amount, note, created_at) '
      "VALUES ('de2', 2, 'out', 80.0, 'ค่าน้ำมัน', ${_secs(DateTime(2026, 8, 31, 10))})",
    );
    v1.execute(
      'INSERT INTO sales (id, receipt_no, subtotal, total, payment_method, date) '
      "VALUES ('s1', 'RC87654321WXYZ', 900.0, 900.0, 'เงินสด', "
      '${_secs(DateTime(2026, 8, 31, 9, 30))})',
    );
    // A sale line written before ADR-0008 — costAtSale must stay NULL, never
    // backfilled with a guess.
    v1.execute(
      'INSERT INTO sale_items (sale_id, product_id, part_no, name, name_t_h, qty, price) '
      "VALUES ('s1', 'p1', 'BP-001', 'Brake Pad', 'ผ้าเบรกหน้า', 2, 450.0)",
    );
    v1.execute(
      'INSERT INTO products (id, part_no, name, name_t_h, category, brand, price, '
      'cost, stock, min_stock) VALUES '
      "('p1', 'BP-001', 'Brake Pad', 'ผ้าเบรกหน้า', 'เบรก', 'TRW', 500.0, 300.0, 9, 2)",
    );
    v1.execute(
      'INSERT INTO customers (id, code, name, name_t_h, points, total_spend, created_at) '
      "VALUES ('c1', 'CUS001', 'Somchai', 'สมชาย', 12, 3400.0, '2026-08-01')",
    );
    v1.execute(
      'INSERT INTO mechanics (id, code, name, created_at) '
      "VALUES ('m1', 'MEC001', 'ช่างเอ', '2026-08-01')",
    );
    v1.execute(
      'INSERT INTO settings_row (id, shop_name, shop_name_e_n) '
      "VALUES (1, 'ศรีสุราษฎร์อะไหล่ยนต์', 'Srisurart Autopart')",
    );
    v1.execute('PRAGMA user_version = 1');
    v1.close();

    db = AppDatabase(NativeDatabase(file));
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('a v1 file lands on v4 in a single open', () async {
    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first)
        .getSingle();
    expect(version, 4);
  });

  test('the v2 block still applies on the way through', () async {
    // Nullable sync columns: present, and null on rows written before v2.
    final customer = await (db.select(
      db.customers,
    )..where((t) => t.id.equals('c1'))).getSingle();
    expect(customer.updatedAt, isNull);
    expect(customer.deletedAt, isNull);
    expect(customer.nameTH, 'สมชาย');
    expect(customer.points, 12);

    final mechanic = await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals('m1'))).getSingle();
    expect(mechanic.updatedAt, isNull);
    expect(mechanic.name, 'ช่างเอ');

    final settings = await (db.select(
      db.settingsRow,
    )..where((t) => t.id.equals(1))).getSingle();
    expect(settings.updatedAt, isNull);
    expect(settings.shopName, 'ศรีสุราษฎร์อะไหล่ยนต์');

    // ADR-0008: a line sold before the upgrade keeps costAtSale NULL — a
    // guessed cost is indistinguishable from a real one once written.
    final line = await (db.select(
      db.saleItems,
    )..where((t) => t.saleId.equals('s1'))).getSingle();
    expect(line.costAtSale, isNull);
    expect(line.nameTH, 'ผ้าเบรกหน้า');
    expect(line.qty, 2);
  });

  test('the v3 block still applies on the way through', () async {
    final shifts = await (db.select(
      db.shifts,
    )..orderBy([(t) => OrderingTerm.asc(t.openedAt)])).get();
    expect(shifts.map((s) => s.id), ['1', '2']);
    expect(shifts.first.physicalCash, 470.0);
    expect(shifts.last.isActive, isTrue);

    final entries = await (db.select(
      db.drawerEntries,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();
    expect(
      {for (final e in entries) e.id: e.shiftId},
      {'de1': '1', 'de2': '2'},
    );
    expect(entries.map((e) => e.note), ['ขายสด', 'ค่าน้ำมัน']);

    final sale = await (db.select(
      db.sales,
    )..where((t) => t.id.equals('s1'))).getSingle();
    expect(sale.shiftId, isNull);
    expect(sale.total, 900.0);

    final product = await (db.select(
      db.products,
    )..where((t) => t.id.equals('p1'))).getSingle();
    expect(product.offlineOk, isFalse);
    expect(product.deletedAt, isNull);
    expect(product.stock, 9);
    expect(product.updatedAt, isNull); // never written by a v1 build
  });

  test('the drawer still opens and archives after the double hop', () async {
    final repo = ShiftsRepository(db);

    final drawer = await repo.getCashDrawer();
    expect(drawer!.shift.id, '2');
    expect(drawer.entries.map((e) => e.id), ['de2']);

    final fresh = await repo.openShift(1500);
    expect(fresh.id, startsWith('sh'));
    expect(fresh.id, isNot(anyOf('1', '2')));

    final prior = await (db.select(
      db.shifts,
    )..where((t) => t.id.equals('2'))).getSingle();
    expect(prior.isActive, isFalse);
    expect(prior.autoArchived, isTrue);
  });
}
