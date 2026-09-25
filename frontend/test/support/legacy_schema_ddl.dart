// DDL for tables that the partial v1–v3 migration fixtures leave out.
//
// A real old file has every table (onCreate ran `createAll`), and the v12 step
// (#417) creates indexes on them, so those fixtures must include them too.
// None of these tables is touched by any `onUpgrade` step, so their shape is
// the same in every schema version — copied from the sqlite_master dump in
// `schema_v6_migration_test.dart`.

const untouchedTablesDdl = [
  'CREATE TABLE "purchase_orders" ("id" TEXT NOT NULL, "po_no" TEXT NOT NULL, "supplier" TEXT NOT NULL, "status" TEXT NOT NULL DEFAULT \'open\', "created_at" INTEGER NOT NULL, "received_at" INTEGER NULL, "cancelled_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "po_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "po_id" TEXT NOT NULL REFERENCES purchase_orders (id), "part_no" TEXT NOT NULL, "name" TEXT NOT NULL, "qty" INTEGER NOT NULL, "cost" REAL NOT NULL)',
  'CREATE TABLE "returns" ("id" TEXT NOT NULL, "cn_no" TEXT NOT NULL, "sale_id" TEXT NOT NULL, "receipt_no" TEXT NOT NULL, "refund_subtotal" REAL NOT NULL, "refund_discount" REAL NOT NULL, "refund_total" REAL NOT NULL, "refund_method" TEXT NOT NULL, "reason" TEXT NOT NULL DEFAULT \'\', "customer_id" TEXT NULL, "mechanic_id" TEXT NULL, "mechanic_name" TEXT NULL, "date" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "return_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "return_id" TEXT NOT NULL REFERENCES returns (id), "product_id" TEXT NOT NULL, "name" TEXT NOT NULL, "qty" INTEGER NOT NULL, "price" REAL NOT NULL, "original_qty" INTEGER NULL)',
  'CREATE TABLE "quotes" ("id" TEXT NOT NULL, "quote_no" TEXT NOT NULL, "status" TEXT NOT NULL DEFAULT \'open\', "date" INTEGER NOT NULL, "valid_until" INTEGER NOT NULL, "converted_at" INTEGER NULL, "subtotal" REAL NULL, "discount" REAL NULL, "total" REAL NULL, "customer_name" TEXT NULL, "customer_phone" TEXT NULL, "notes" TEXT NULL, "valid_days" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "quote_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "quote_id" TEXT NOT NULL REFERENCES quotes (id), "product_id" TEXT NULL, "name" TEXT NOT NULL, "qty" INTEGER NOT NULL, "price" REAL NOT NULL, "cost_at_sale" REAL NULL)',
  'CREATE TABLE "suppliers" ("id" TEXT NOT NULL, "product_id" TEXT NOT NULL, "name" TEXT NOT NULL, "unit_cost" REAL NOT NULL, "freight" REAL NOT NULL DEFAULT 0.0, PRIMARY KEY ("id"))',
];

/// `sale_items` as it stands from v2 on (v2 added `cost_at_sale`).
const saleItemsV2Ddl =
    'CREATE TABLE "sale_items" ("row_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "sale_id" TEXT NOT NULL REFERENCES sales (id), "product_id" TEXT NOT NULL, "part_no" TEXT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NULL, "qty" INTEGER NOT NULL, "price" REAL NOT NULL, "cost_at_sale" REAL NULL)';
