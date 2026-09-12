// Schema v3 → v4 migration, run against a REAL v3 database file.
//
// Ticket #55 owns adding Products.deletedAt for soft delete sync (ADR-0010
// decision 2: the ?updatedSince= cursor sees creates and edits but needs
// deletedAt to detect soft-deleted products).

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

const _v3Ddl = [
  'CREATE TABLE "shifts" ("id" TEXT NOT NULL, "date_str" TEXT NOT NULL, '
      '"starting_cash" REAL NOT NULL, "opened_at" INTEGER NOT NULL, '
      '"closed_at" INTEGER NULL, "physical_cash" REAL NULL, '
      '"is_active" INTEGER NOT NULL DEFAULT 0 CHECK ("is_active" IN (0, 1)), '
      '"auto_archived" INTEGER NOT NULL DEFAULT 0 CHECK ("auto_archived" IN (0, 1)), '
      '"archived_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "drawer_entries" ("id" TEXT NOT NULL, "shift_id" TEXT NOT NULL '
      'REFERENCES shifts (id), "type" TEXT NOT NULL, "amount" REAL NOT NULL, '
      '"note" TEXT NULL, "created_at" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "sales" ("id" TEXT NOT NULL, "receipt_no" TEXT NOT NULL, '
      '"subtotal" REAL NOT NULL, "discount" REAL NOT NULL DEFAULT 0.0, '
      '"total" REAL NOT NULL, "payment_method" TEXT NOT NULL, '
      '"customer_id" TEXT NULL, "customer_name" TEXT NULL, "mechanic_id" TEXT NULL, '
      '"mechanic_name" TEXT NULL, "mechanic_delta" REAL NULL, '
      '"points_granted" INTEGER NOT NULL DEFAULT 0, "date" INTEGER NOT NULL, '
      '"voided" INTEGER NOT NULL DEFAULT 0 CHECK ("voided" IN (0, 1)), '
      '"voided_at" INTEGER NULL, "shift_id" TEXT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "products" ("id" TEXT NOT NULL, "part_no" TEXT NOT NULL, '
      '"name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "category" TEXT NOT NULL, '
      '"brand" TEXT NOT NULL, "price" REAL NOT NULL, "cost" REAL NOT NULL, '
      '"stock" INTEGER NOT NULL, "min_stock" INTEGER NOT NULL, "compat" TEXT NULL, '
      '"zone" TEXT NULL, "updated_at" INTEGER NULL, "offline_ok" INTEGER NOT NULL '
      'DEFAULT 0 CHECK ("offline_ok" IN (0, 1)), PRIMARY KEY ("id"))',
  'CREATE TABLE "customers" ("id" TEXT NOT NULL, "code" TEXT NOT NULL, '
      '"name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "phone" TEXT NULL, '
      '"address" TEXT NULL, "points" INTEGER NOT NULL DEFAULT 0, '
      '"total_spend" REAL NOT NULL DEFAULT 0.0, "created_at" TEXT NOT NULL, '
      '"updated_at" INTEGER NULL, "deleted_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "mechanics" ("id" TEXT NOT NULL, "code" TEXT NOT NULL, '
      '"name" TEXT NOT NULL, "name_t_h" TEXT NULL, "nickname" TEXT NULL, '
      '"shop_name" TEXT NULL, "phone" TEXT NULL, "note" TEXT NULL, '
      '"credit_limit" REAL NOT NULL DEFAULT 0.0, "credit_balance" REAL NOT NULL DEFAULT 0.0, '
      '"total_sales" REAL NOT NULL DEFAULT 0.0, "total_credit" REAL NOT NULL DEFAULT 0.0, '
      '"total_markup" REAL NOT NULL DEFAULT 0.0, "total_discount" REAL NOT NULL DEFAULT 0.0, '
      '"created_at" TEXT NOT NULL, "updated_at" INTEGER NULL, "deleted_at" INTEGER NULL, '
      'PRIMARY KEY ("id"))',
];

int _secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  late Directory dir;
  late File file;
  late AppDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sri_v3_');
    file = File('${dir.path}/app.sqlite');

    final v3 = raw.sqlite3.open(file.path);
    for (final ddl in _v3Ddl) {
      v3.execute(ddl);
    }
    v3.execute(
      'INSERT INTO products (id, part_no, name, name_t_h, category, brand, price, '
      'cost, stock, min_stock, offline_ok) VALUES '
      "('p1', 'OIL-001', 'Engine Oil', 'น้ำมันเครื่อง', 'น้ำมัน', 'Shell', 450.0, 320.0, 15, 3, 1)",
    );
    v3.execute(
      'INSERT INTO sales (id, receipt_no, subtotal, total, payment_method, date, shift_id) VALUES '
      "('s1', 'RC01-2026-09-0001', 450.0, 450.0, 'เงินสด', ${_secs(DateTime(2026, 9, 3, 10))}, 'sh1')",
    );
    v3.execute('PRAGMA user_version = 3');
    v3.close();

    db = AppDatabase(NativeDatabase(file));
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('upgrades a v3 file to v4 and adds deletedAt column to products', () async {
    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first)
        .getSingle();
    expect(version, 4);

    final product = await (db.select(
      db.products,
    )..where((t) => t.id.equals('p1'))).getSingle();

    expect(product.id, 'p1');
    expect(product.partNo, 'OIL-001');
    expect(product.nameTH, 'น้ำมันเครื่อง');
    expect(product.stock, 15);
    expect(product.offlineOk, isTrue);
    expect(product.deletedAt, isNull);
  });

  test('products can be soft-deleted by stamping deletedAt in v4', () async {
    final now = DateTime.now();
    await (db.update(db.products)..where((t) => t.id.equals('p1'))).write(
      ProductsCompanion(deletedAt: Value(now)),
    );

    final updated = await (db.select(
      db.products,
    )..where((t) => t.id.equals('p1'))).getSingle();
    expect(updated.deletedAt, isNotNull);
  });
}
