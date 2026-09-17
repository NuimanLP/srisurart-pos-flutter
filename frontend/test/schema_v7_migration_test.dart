// Schema v6 → v7 migration test (Ticket #272).
//
// Verifies that migrating an in-memory database from schema v6 to v7 drops
// the `offline_ok` column from the `products` table while keeping all existing
// product rows and columns intact.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

/// Schema v6 DDL with `products.offline_ok` present.
const _v6Ddl = [
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
  'CREATE TABLE "doc_counters" ("device_id" TEXT NOT NULL, "device_no" INTEGER NOT NULL, "doc_type" TEXT NOT NULL, "period" TEXT NOT NULL, "last_no" INTEGER NOT NULL, PRIMARY KEY ("device_id", "doc_type", "period"))',
  'CREATE TABLE "doc_counter_seeds" ("device_id" TEXT NOT NULL, "period" TEXT NOT NULL, "seeded_at" INTEGER NOT NULL, PRIMARY KEY ("device_id", "period"))',
  'CREATE TABLE "app_meta" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, PRIMARY KEY ("key"))',
];

void main() {
  test(
    'migrating an in-memory database from schema v6 to v7 drops offline_ok while keeping product rows intact',
    () async {
      final rawDb = raw.sqlite3.openInMemory();
      for (final ddl in _v6Ddl) {
        rawDb.execute(ddl);
      }

      // Populate v6 product rows: one with offline_ok = 1 and one with offline_ok = 0
      rawDb.execute(
        'INSERT INTO products (id, part_no, name, name_t_h, category, brand, price, '
        'cost, stock, min_stock, compat, zone, updated_at, offline_ok, deleted_at) VALUES '
        "('p1', 'OIL-001', 'Engine Oil', 'น้ำมันเครื่อง', 'น้ำมัน', 'Shell', 450.0, 320.0, 15, 3, 'All', 'A1', 1726000000, 1, NULL), "
        "('p2', 'BRK-002', 'Brake Pad', 'ผ้าเบรก', 'เบรก', 'Brembo', 1200.0, 800.0, 8, 2, NULL, NULL, NULL, 0, NULL)",
      );
      rawDb.execute('PRAGMA user_version = 6');

      final db = AppDatabase(NativeDatabase.opened(rawDb));
      addTearDown(() => db.close());

      // Verify PRAGMA user_version is bumped to 7
      final version = await db
          .customSelect('PRAGMA user_version')
          .map((r) => r.data.values.first)
          .getSingle();
      expect(version, 7);

      // Verify existing product rows are intact with all fields preserved
      final products = await (db.select(db.products)
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
      expect(products.length, 2);

      final p1 = products[0];
      expect(p1.id, 'p1');
      expect(p1.partNo, 'OIL-001');
      expect(p1.name, 'Engine Oil');
      expect(p1.nameTH, 'น้ำมันเครื่อง');
      expect(p1.category, 'น้ำมัน');
      expect(p1.brand, 'Shell');
      expect(p1.price, 450.0);
      expect(p1.cost, 320.0);
      expect(p1.stock, 15);
      expect(p1.minStock, 3);
      expect(p1.compat, 'All');
      expect(p1.zone, 'A1');
      expect(p1.deletedAt, isNull);

      final p2 = products[1];
      expect(p2.id, 'p2');
      expect(p2.partNo, 'BRK-002');
      expect(p2.name, 'Brake Pad');
      expect(p2.nameTH, 'ผ้าเบรก');
      expect(p2.category, 'เบรก');
      expect(p2.brand, 'Brembo');
      expect(p2.price, 1200.0);
      expect(p2.cost, 800.0);
      expect(p2.stock, 8);
      expect(p2.minStock, 2);

      // Verify offline_ok column was dropped from sqlite schema
      final tableInfo =
          await db.customSelect('PRAGMA table_info(products)').get();
      final columnNames =
          tableInfo.map((row) => row.data['name'] as String).toList();
      expect(columnNames, isNot(contains('offline_ok')));
      expect(
        columnNames,
        containsAll([
          'id',
          'part_no',
          'name',
          'name_t_h',
          'category',
          'brand',
          'price',
          'cost',
          'stock',
          'min_stock',
          'compat',
          'zone',
          'updated_at',
          'deleted_at',
        ]),
      );

      // Verify inserting and reading a new product row without offline_ok
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'p3',
              partNo: 'FLT-003',
              name: 'Air Filter',
              nameTH: 'กรองอากาศ',
              category: 'เครื่องยนต์',
              brand: 'Denso',
              price: 250.0,
              cost: 150.0,
              stock: 20,
              minStock: 5,
            ),
          );
      final p3 = await (db.select(db.products)
            ..where((t) => t.id.equals('p3')))
          .getSingle();
      expect(p3.name, 'Air Filter');
      expect(p3.stock, 20);
    },
  );
}
