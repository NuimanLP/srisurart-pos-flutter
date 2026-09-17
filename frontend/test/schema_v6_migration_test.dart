// Schema v5 → v6 migration, run against a REAL v5 database file.
//
// #188 adds the document-number counter (`doc_counters`) and its seed record
// (`doc_counter_seeds`). Without the `createTable` steps an upgraded till would
// throw "no such table" on its first seed instead of filling the counter.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

/// 🔴 Evidence, not a fixture: `SELECT sql FROM sqlite_master` of a database
/// created by `AppDatabase` at the commit before the v6 bump (origin/main
/// 261daa4), in `rowid` order (`sqlite_sequence` omitted — SQLite creates it
/// itself). Do not tidy it.
const _v5Ddl = [
  'CREATE TABLE "products" ("id" TEXT NOT NULL, "part_no" TEXT NOT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "category" TEXT NOT NULL, "brand" TEXT NOT NULL, "price" REAL NOT NULL, "cost" REAL NOT NULL, "stock" INTEGER NOT NULL, "min_stock" INTEGER NOT NULL, "compat" TEXT NULL, "zone" TEXT NULL, "updated_at" INTEGER NULL, "offline_ok" INTEGER NOT NULL DEFAULT 0 CHECK ("offline_ok" IN (0, 1)), "deleted_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "categories" ("name" TEXT NOT NULL, "position" INTEGER NOT NULL, PRIMARY KEY ("name"))',
  'CREATE TABLE "customers" ("id" TEXT NOT NULL, "code" TEXT NOT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "phone" TEXT NULL, "address" TEXT NULL, "points" INTEGER NOT NULL DEFAULT 0, "total_spend" REAL NOT NULL DEFAULT 0.0, "created_at" TEXT NOT NULL, "updated_at" INTEGER NULL, "deleted_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "mechanics" ("id" TEXT NOT NULL, "code" TEXT NOT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NULL, "nickname" TEXT NULL, "shop_name" TEXT NULL, "phone" TEXT NULL, "note" TEXT NULL, "credit_limit" REAL NOT NULL DEFAULT 0.0, "credit_balance" REAL NOT NULL DEFAULT 0.0, "total_sales" REAL NOT NULL DEFAULT 0.0, "total_credit" REAL NOT NULL DEFAULT 0.0, "total_discount" REAL NOT NULL DEFAULT 0.0, "total_markup" REAL NOT NULL DEFAULT 0.0, "created_at" TEXT NOT NULL, "updated_at" INTEGER NULL, "deleted_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "sales" ("id" TEXT NOT NULL, "receipt_no" TEXT NOT NULL, "subtotal" REAL NOT NULL, "discount" REAL NOT NULL DEFAULT 0.0, "total" REAL NOT NULL, "payment_method" TEXT NOT NULL, "customer_id" TEXT NULL, "customer_name" TEXT NULL, "mechanic_id" TEXT NULL, "mechanic_name" TEXT NULL, "mechanic_delta" REAL NULL, "points_granted" INTEGER NOT NULL DEFAULT 0, "date" INTEGER NOT NULL, "voided" INTEGER NOT NULL DEFAULT 0 CHECK ("voided" IN (0, 1)), "voided_at" INTEGER NULL, "shift_id" TEXT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "sale_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "sale_id" TEXT NOT NULL REFERENCES sales (id), "product_id" TEXT NOT NULL, "part_no" TEXT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NULL, "qty" INTEGER NOT NULL, "price" REAL NOT NULL, "cost_at_sale" REAL NULL)',
  'CREATE TABLE "purchase_orders" ("id" TEXT NOT NULL, "po_no" TEXT NOT NULL, "supplier" TEXT NOT NULL, "status" TEXT NOT NULL DEFAULT \'open\', "created_at" INTEGER NOT NULL, "received_at" INTEGER NULL, "cancelled_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "po_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "po_id" TEXT NOT NULL REFERENCES purchase_orders (id), "part_no" TEXT NOT NULL, "name" TEXT NOT NULL, "qty" INTEGER NOT NULL, "cost" REAL NOT NULL)',
  'CREATE TABLE "returns" ("id" TEXT NOT NULL, "cn_no" TEXT NOT NULL, "sale_id" TEXT NOT NULL, "receipt_no" TEXT NOT NULL, "refund_subtotal" REAL NOT NULL, "refund_discount" REAL NOT NULL, "refund_total" REAL NOT NULL, "refund_method" TEXT NOT NULL, "reason" TEXT NOT NULL DEFAULT \'\', "customer_id" TEXT NULL, "mechanic_id" TEXT NULL, "mechanic_name" TEXT NULL, "date" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "return_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "return_id" TEXT NOT NULL REFERENCES returns (id), "product_id" TEXT NOT NULL, "name" TEXT NOT NULL, "qty" INTEGER NOT NULL, "price" REAL NOT NULL, "original_qty" INTEGER NULL)',
  'CREATE TABLE "quotes" ("id" TEXT NOT NULL, "quote_no" TEXT NOT NULL, "status" TEXT NOT NULL DEFAULT \'open\', "date" INTEGER NOT NULL, "valid_until" INTEGER NOT NULL, "converted_at" INTEGER NULL, "subtotal" REAL NULL, "discount" REAL NULL, "total" REAL NULL, "customer_name" TEXT NULL, "customer_phone" TEXT NULL, "notes" TEXT NULL, "valid_days" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "quote_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "quote_id" TEXT NOT NULL REFERENCES quotes (id), "product_id" TEXT NULL, "name" TEXT NOT NULL, "qty" INTEGER NOT NULL, "price" REAL NOT NULL, "cost_at_sale" REAL NULL)',
  'CREATE TABLE "movements" ("id" TEXT NOT NULL, "product_id" TEXT NOT NULL, "part_no" TEXT NOT NULL, "name" TEXT NOT NULL, "delta" INTEGER NOT NULL, "type" TEXT NOT NULL, "note" TEXT NULL, "stock_after" INTEGER NOT NULL, "date" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "suppliers" ("id" TEXT NOT NULL, "product_id" TEXT NOT NULL, "name" TEXT NOT NULL, "unit_cost" REAL NOT NULL, "freight" REAL NOT NULL DEFAULT 0.0, PRIMARY KEY ("id"))',
  'CREATE TABLE "credit_payments" ("id" TEXT NOT NULL, "receipt_no" TEXT NOT NULL, "mechanic_id" TEXT NOT NULL, "amount" REAL NOT NULL, "date" INTEGER NOT NULL, "note" TEXT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "pending_credit_payments" ("id" TEXT NOT NULL, "idempotency_key" TEXT NOT NULL, "mechanic_id" TEXT NOT NULL, "amount" TEXT NOT NULL, "payment_method" TEXT NOT NULL, "note" TEXT NULL, "allow_overpayment" INTEGER NOT NULL DEFAULT 0 CHECK ("allow_overpayment" IN (0, 1)), "created_at" INTEGER NOT NULL, "rejected_code" TEXT NULL, "rejected_message" TEXT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "shifts" ("id" TEXT NOT NULL, "date_str" TEXT NOT NULL, "starting_cash" REAL NOT NULL, "opened_at" INTEGER NOT NULL, "closed_at" INTEGER NULL, "physical_cash" REAL NULL, "is_active" INTEGER NOT NULL DEFAULT 0 CHECK ("is_active" IN (0, 1)), "auto_archived" INTEGER NOT NULL DEFAULT 0 CHECK ("auto_archived" IN (0, 1)), "archived_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "drawer_entries" ("id" TEXT NOT NULL, "shift_id" TEXT NOT NULL REFERENCES shifts (id), "type" TEXT NOT NULL, "amount" REAL NOT NULL, "note" TEXT NULL, "created_at" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "parked_sales" ("id" TEXT NOT NULL, "parked_at" INTEGER NOT NULL, "payload" TEXT NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "settings_row" ("id" INTEGER NOT NULL, "shop_name" TEXT NOT NULL, "shop_name_e_n" TEXT NOT NULL, "tax_rate" REAL NOT NULL DEFAULT 7.0, "quote_valid_days" INTEGER NOT NULL DEFAULT 30, "address" TEXT NULL, "phone" TEXT NULL, "cashier_name" TEXT NULL, "tax_id" TEXT NULL, "branch_no" TEXT NULL, "updated_at" INTEGER NULL, "deleted_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "app_meta" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, PRIMARY KEY ("key"))',
];

void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sri_v5_');
    final file = File('${dir.path}/app.sqlite');

    final v5 = raw.sqlite3.open(file.path);
    for (final ddl in _v5Ddl) {
      v5.execute(ddl);
    }
    // A queued credit payment: v5 data the upgrade must not touch.
    v5.execute(
      'INSERT INTO pending_credit_payments (id, idempotency_key, mechanic_id, '
      "amount, payment_method, created_at) VALUES ('cp_1', 'idem_1', 'm1', "
      "'500.00', 'เงินสด', 1789000000)",
    );
    v5.execute('PRAGMA user_version = 5');
    v5.close();

    db = AppDatabase(NativeDatabase(file));
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('upgrades a v5 file to v6 with empty counter tables', () async {
    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first)
        .getSingle();
    expect(version, 6);

    expect(await db.select(db.docCounters).get(), isEmpty);
    expect(await db.select(db.docCounterSeeds).get(), isEmpty);

    final queued = await db.select(db.pendingCreditPayments).getSingle();
    expect(queued.id, 'cp_1');
    expect(queued.amount, '500.00');
  });

  test('the new tables accept a counter row and a seed row', () async {
    await db
        .into(db.docCounters)
        .insert(
          DocCountersCompanion.insert(
            deviceId: 'dv_1',
            deviceNo: 1,
            docType: 'receipt',
            period: '2569-09',
            lastNo: 42,
          ),
        );
    await db
        .into(db.docCounterSeeds)
        .insert(
          DocCounterSeedsCompanion.insert(
            deviceId: 'dv_1',
            period: '2569-09',
            seededAt: DateTime(2026, 9, 15, 9),
          ),
        );

    final counter = await db.select(db.docCounters).getSingle();
    expect(counter.lastNo, 42);
    final seed = await db.select(db.docCounterSeeds).getSingle();
    expect(seed.period, '2569-09');
  });
}
