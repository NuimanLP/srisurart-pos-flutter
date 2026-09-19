import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/services/doc_counter_seeder.dart';
import 'package:srisurart_pos/data/services/doc_number_service.dart';

/// Schema v7 DDL (products without offline_ok, doc_counters and doc_counter_seeds present).
const _v7Ddl = [
  'CREATE TABLE "products" ("id" TEXT NOT NULL, "part_no" TEXT NOT NULL, "name" TEXT NOT NULL, "name_t_h" TEXT NOT NULL, "category" TEXT NOT NULL, "brand" TEXT NOT NULL, "price" REAL NOT NULL, "cost" REAL NOT NULL, "stock" INTEGER NOT NULL, "min_stock" INTEGER NOT NULL, "compat" TEXT NULL, "zone" TEXT NULL, "updated_at" INTEGER NULL, "deleted_at" INTEGER NULL, PRIMARY KEY ("id"))',
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
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  late AppDatabase db;
  late DocNumberService service;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    service = DocNumberService(db: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('formatPeriod', () {
    test('derives Buddhist Era year (year + 543) and 2-digit zero-padded month', () {
      expect(DocNumberService.formatPeriod(DateTime(2026, 9, 15)), '2569-09');
      expect(DocNumberService.formatPeriod(DateTime(2026, 1, 1)), '2569-01');
      expect(DocNumberService.formatPeriod(DateTime(2026, 12, 31)), '2569-12');
      expect(DocNumberService.formatPeriod(DateTime(2027, 3, 5)), '2570-03');
    });
  });

  group('parseDocNo', () {
    test('parses standard RC format', () {
      final p = DocNumberService.parseDocNo('RC01-2569-09-0042');
      expect(p.prefix, 'RC');
      expect(p.docType, 'receipt');
      expect(p.deviceNo, 1);
      expect(p.period, '2569-09');
      expect(p.seq, 42);
      expect(p.formatted, 'RC01-2569-09-0042');
    });

    test('parses CN format with 2-digit deviceNo', () {
      final p = DocNumberService.parseDocNo('CN12-2569-10-0007');
      expect(p.prefix, 'CN');
      expect(p.docType, 'cn');
      expect(p.deviceNo, 12);
      expect(p.period, '2569-10');
      expect(p.seq, 7);
      expect(p.formatted, 'CN12-2569-10-0007');
    });

    test('throws FormatException on malformed string', () {
      expect(() => DocNumberService.parseDocNo('RC1-2569-09-0001'), throwsFormatException);
      expect(() => DocNumberService.parseDocNo('RC01-2569-9-0001'), throwsFormatException);
      expect(() => DocNumberService.parseDocNo('RC00-2569-09-0001'), throwsFormatException);
      expect(() => DocNumberService.parseDocNo('RC01-2569-09-0000'), throwsFormatException);
      expect(() => DocNumberService.parseDocNo('INVALID'), throwsFormatException);
    });
  });

  group('First bill of period', () {
    test('gets 0001 with proper format for receipt and cn', () async {
      final clock = DateTime(2026, 9, 19);

      // Receipt on device 1
      final rc = await service.generateNextDocNo(
        deviceId: 'dev_pos_001',
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(rc, 'RC01-2569-09-0001');

      // Return on device 2
      final cn = await service.generateNextDocNo(
        deviceId: 'dev_pos_002',
        deviceNo: 2,
        docType: 'cn',
        now: clock,
      );
      expect(cn, 'CN02-2569-09-0001');
    });

    test('zero-pads deviceNo properly across 1..99', () async {
      final clock = DateTime(2026, 9, 1);
      final rc1 = await service.generateNextDocNo(
        deviceId: 'dev_1',
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(rc1, 'RC01-2569-09-0001');

      final rc9 = await service.generateNextDocNo(
        deviceId: 'dev_9',
        deviceNo: 9,
        docType: 'receipt',
        now: clock,
      );
      expect(rc9, 'RC09-2569-09-0001');

      final rc10 = await service.generateNextDocNo(
        deviceId: 'dev_10',
        deviceNo: 10,
        docType: 'receipt',
        now: clock,
      );
      expect(rc10, 'RC10-2569-09-0001');

      final rc99 = await service.generateNextDocNo(
        deviceId: 'dev_99',
        deviceNo: 99,
        docType: 'receipt',
        now: clock,
      );
      expect(rc99, 'RC99-2569-09-0001');
    });

    test('rejects deviceNo outside 1..99', () async {
      expect(
        () => service.generateNextDocNo(
          deviceId: 'dev_0',
          deviceNo: 0,
          docType: 'receipt',
        ),
        throwsArgumentError,
      );
      expect(
        () => service.generateNextDocNo(
          deviceId: 'dev_100',
          deviceNo: 100,
          docType: 'receipt',
        ),
        throwsArgumentError,
      );
    });
  });

  group('Moving local clock to next month', () {
    test('resets counter to 0001 and preserves previous month counter', () async {
      const devId = 'dev_pos_main';
      final sepClock = DateTime(2026, 9, 30, 23, 50);

      // Issue bills in September up to 42
      for (var i = 1; i <= 42; i++) {
        final docNo = await service.generateNextDocNo(
          deviceId: devId,
          deviceNo: 1,
          docType: 'receipt',
          now: sepClock,
        );
        expect(docNo, 'RC01-2569-09-${i.toString().padLeft(4, '0')}');
        await service.commitDocNoString(deviceId: devId, docNo: docNo);
      }

      expect(await service.getLastNo(deviceId: devId, docType: 'receipt', period: '2569-09'), 42);

      // Advance clock past midnight into October (new period 2569-10) while offline
      final octClock = DateTime(2026, 10, 1, 0, 5);

      final oct1 = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: octClock,
      );
      // Starts fresh at 0001 for the new month
      expect(oct1, 'RC01-2569-10-0001');
      await service.commitDocNoString(deviceId: devId, docNo: oct1);

      final oct2 = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: octClock,
      );
      expect(oct2, 'RC01-2569-10-0002');
      await service.commitDocNoString(deviceId: devId, docNo: oct2);

      // Verify October counter is 2 and September counter is still 42
      expect(await service.getLastNo(deviceId: devId, docType: 'receipt', period: '2569-10'), 2);
      expect(await service.getLastNo(deviceId: devId, docType: 'receipt', period: '2569-09'), 42);
    });
  });

  group('9999 exhaustion', () {
    test('sequence 9999 is valid, but attempting next bill throws DOC_NUMBER_EXHAUSTED', () async {
      const devId = 'dev_pos_busy';
      final clock = DateTime(2026, 9, 15);

      // Pre-seed counter to 9998
      await service.commitDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        period: '2569-09',
        seq: 9998,
      );

      // Bill 9999 can be generated
      final bill9999 = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(bill9999, 'RC01-2569-09-9999');

      // Commit bill 9999
      await service.commitDocNoString(deviceId: devId, docNo: bill9999);
      expect(await service.getLastNo(deviceId: devId, docType: 'receipt', period: '2569-09'), 9999);

      // Next attempt must throw DOC_NUMBER_EXHAUSTED and never wrap around to 0000 or 0001
      try {
        await service.generateNextDocNo(
          deviceId: devId,
          deviceNo: 1,
          docType: 'receipt',
          now: clock,
        );
        fail('Should have thrown DocNumberExhaustedException');
      } on DocNumberException catch (e) {
        expect(e.code, 'DOC_NUMBER_EXHAUSTED');
        expect(e.toString(), 'เลขเอกสารเต็มโควตา');
      }
    });

    test('throws DOC_NUMBER_EXHAUSTED when lastNo is already 9999', () async {
      const devId = 'dev_pos_full';
      final clock = DateTime(2026, 9, 1);

      await service.commitDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        period: '2569-09',
        seq: 9999,
      );

      expect(
        () => service.generateNextDocNo(
          deviceId: devId,
          deviceNo: 1,
          docType: 'receipt',
          now: clock,
        ),
        throwsA(
          isA<DocNumberExhaustedException>().having(
            (e) => e.code,
            'code',
            'DOC_NUMBER_EXHAUSTED',
          ),
        ),
      );
    });
  });

  group('4xx reuse behavior (number not consumed unless committed)', () {
    test('reuses same candidate number on 4xx failure and advances only after commit', () async {
      const devId = 'dev_pos_sale';
      final clock = DateTime(2026, 9, 15);

      // Step 1: Cashier clicks Pay -> candidate generated
      final cand1 = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(cand1, 'RC01-2569-09-0001');

      // Step 2: Simulated online write fails with 409 CREDIT_LIMIT_EXCEEDED
      // (Write did not succeed with 2xx and did not enter outbox queue)
      // Number is NOT committed.

      // Step 3: Cashier adjusts or clicks retry -> candidate requested again
      final cand2 = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      // Exact same number is returned! No numbers burned/exhausted on 4xx.
      expect(cand2, 'RC01-2569-09-0001');

      // Step 4: Write succeeds (201 Created) -> committed
      await service.commitDocNoString(deviceId: devId, docNo: cand2);
      expect(await service.getLastNo(deviceId: devId, docType: 'receipt', period: '2569-09'), 1);

      // Step 5: Next sale gets 0002
      final cand3 = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(cand3, 'RC01-2569-09-0002');
    });

    test('issueAndCommit commits immediately for outbox queue insertion', () async {
      const devId = 'dev_pos_offline';
      final clock = DateTime(2026, 9, 15);

      final n1 = await service.issueAndCommit(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(n1, 'RC01-2569-09-0001');

      final n2 = await service.issueAndCommit(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(n2, 'RC01-2569-09-0002');
    });
  });

  group('Isolation across deviceId and docType', () {
    test('different devices maintain independent counters', () async {
      final clock = DateTime(2026, 9, 1);

      final d1 = await service.issueAndCommit(
        deviceId: 'device_alpha',
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(d1, 'RC01-2569-09-0001');

      final d2 = await service.issueAndCommit(
        deviceId: 'device_beta',
        deviceNo: 2,
        docType: 'receipt',
        now: clock,
      );
      expect(d2, 'RC02-2569-09-0001');

      final d1Second = await service.issueAndCommit(
        deviceId: 'device_alpha',
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(d1Second, 'RC01-2569-09-0002');
    });

    test('receipt and cn counters on the same device are independent', () async {
      final clock = DateTime(2026, 9, 1);
      const devId = 'dev_shared';

      final rc1 = await service.issueAndCommit(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(rc1, 'RC01-2569-09-0001');

      final cn1 = await service.issueAndCommit(
        deviceId: devId,
        deviceNo: 1,
        docType: 'cn',
        now: clock,
      );
      expect(cn1, 'CN01-2569-09-0001');

      final rc2 = await service.issueAndCommit(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: clock,
      );
      expect(rc2, 'RC01-2569-09-0002');
    });
  });

  group('C16: Upgraded database clears doc_counter_seeds', () {
    test('migrating v7 to v8 clears doc_counter_seeds while keeping counters and other tables intact', () async {
      final rawDb = raw.sqlite3.openInMemory();
      for (final ddl in _v7Ddl) {
        rawDb.execute(ddl);
      }

      // Populate v7 data:
      // 1. Stale seed markers from before switch-over (must be cleared by upgrade)
      rawDb.execute(
        'INSERT INTO doc_counter_seeds (device_id, period, seeded_at) VALUES '
        "('dev_old', '2569-08', 1788652800), "
        "('dev_old', '2569-09', 1789000000)",
      );

      // 2. Existing doc_counters (must be preserved)
      rawDb.execute(
        'INSERT INTO doc_counters (device_id, device_no, doc_type, period, last_no) VALUES '
        "('dev_old', 1, 'receipt', '2569-09', 42), "
        "('dev_old', 1, 'cn', '2569-09', 5)",
      );

      // 3. Product row (must be preserved)
      rawDb.execute(
        'INSERT INTO products (id, part_no, name, name_t_h, category, brand, price, '
        'cost, stock, min_stock, compat, zone, updated_at, deleted_at) VALUES '
        "('p1', 'OIL-001', 'Oil Filter', 'กรองน้ำมันเครื่อง', 'เครื่องยนต์', 'Honda', 85.0, 45.0, 48, 10, NULL, NULL, NULL, NULL)",
      );

      rawDb.execute('PRAGMA user_version = 7');

      // Open database with AppDatabase, triggering onUpgrade from v7 to v8
      final upgradedDb = AppDatabase(NativeDatabase.opened(rawDb));
      addTearDown(() => upgradedDb.close());

      // Verify PRAGMA user_version is 9
      final version = await upgradedDb
          .customSelect('PRAGMA user_version')
          .map((r) => r.data.values.first)
          .getSingle();
      expect(version, 9);

      // Verify doc_counter_seeds is completely wiped (C16)
      final seeds = await upgradedDb.select(upgradedDb.docCounterSeeds).get();
      expect(seeds, isEmpty);

      // Verify doc_counters is intact
      final counters = await (upgradedDb.select(upgradedDb.docCounters)
            ..orderBy([(t) => OrderingTerm.asc(t.docType)]))
          .get();
      expect(counters.length, 2);
      expect(counters[0].docType, 'cn');
      expect(counters[0].lastNo, 5);
      expect(counters[1].docType, 'receipt');
      expect(counters[1].lastNo, 42);

      // Verify products is intact
      final products = await upgradedDb.select(upgradedDb.products).get();
      expect(products.length, 1);
      expect(products.first.id, 'p1');
      expect(products.first.name, 'Oil Filter');
    });
  });

  group('Issue #189: Seed marker guard for offline document numbering', () {
    const devId = 'dev_pos_guard';
    final sepClock = DateTime(2026, 9, 15, 10, 30);

    test('offline generation without seed marker throws OfflineSeedRequiredException with Thai message', () async {
      expect(await service.hasSeedMarker(deviceId: devId, period: '2569-09'), isFalse);

      try {
        await service.generateNextDocNo(
          deviceId: devId,
          deviceNo: 1,
          docType: 'receipt',
          now: sepClock,
          isOffline: true,
        );
        fail('Should have thrown OfflineSeedRequiredException');
      } on OfflineSeedRequiredException catch (e) {
        expect(e.code, 'OFFLINE_SEED_REQUIRED');
        expect(
          e.message,
          'ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์',
        );
        expect(
          e.toString(),
          'ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์',
        );
      }

      // Also verify SeedMarkerMissingException alias works
      expect(
        () => service.generateNextDocNo(
          deviceId: devId,
          deviceNo: 1,
          docType: 'receipt',
          now: sepClock,
          isOffline: true,
        ),
        throwsA(isA<SeedMarkerMissingException>()),
      );
    });

    test('issueAndCommit with isOffline: true without seed marker throws OfflineSeedRequiredException', () async {
      expect(
        () => service.issueAndCommit(
          deviceId: devId,
          deviceNo: 1,
          docType: 'receipt',
          now: sepClock,
          isOffline: true,
        ),
        throwsA(isA<OfflineSeedRequiredException>()),
      );
    });

    test('online generation (isOffline: false) succeeds even without seed marker', () async {
      expect(await service.hasSeedMarker(deviceId: devId, period: '2569-09'), isFalse);

      final docNo = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: sepClock,
        isOffline: false,
      );
      expect(docNo, 'RC01-2569-09-0001');
    });

    test('offline generation WITH seed marker succeeds', () async {
      await service.recordSeedMarker(
        deviceId: devId,
        period: '2569-09',
        seededAt: DateTime(2026, 9, 15, 8, 0),
      );

      expect(await service.hasSeedMarker(deviceId: devId, period: '2569-09'), isTrue);

      final docNo = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: sepClock,
        isOffline: true,
      );
      expect(docNo, 'RC01-2569-09-0001');

      // Issue and commit offline
      final committed = await service.issueAndCommit(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: sepClock,
        isOffline: true,
      );
      expect(committed, 'RC01-2569-09-0001');

      final nextDocNo = await service.generateNextDocNo(
        deviceId: devId,
        deviceNo: 1,
        docType: 'receipt',
        now: sepClock,
        isOffline: true,
      );
      expect(nextDocNo, 'RC01-2569-09-0002');
    });

    test('hasSeedMarker queries deviceId and optional period correctly', () async {
      expect(await service.hasSeedMarker(deviceId: 'dev_check'), isFalse);
      expect(await service.hasSeedMarker(deviceId: 'dev_check', period: '2569-09'), isFalse);

      await service.recordSeedMarker(deviceId: 'dev_check', period: '2569-09');

      // Checks with period
      expect(await service.hasSeedMarker(deviceId: 'dev_check', period: '2569-09'), isTrue);
      expect(await service.hasSeedMarker(deviceId: 'dev_check', period: '2569-10'), isFalse);

      // Checks without period (any period for this device)
      expect(await service.hasSeedMarker(deviceId: 'dev_check'), isTrue);
      expect(await service.hasSeedMarker(deviceId: 'dev_other'), isFalse);
    });

    test('post-upgrade: wiped seed markers force online seed before offline generation works', () async {
      final rawDb = raw.sqlite3.openInMemory();
      for (final ddl in _v7Ddl) {
        rawDb.execute(ddl);
      }

      // v7 state: stale seed marker and counters exist
      rawDb.execute(
        'INSERT INTO doc_counter_seeds (device_id, period, seeded_at) VALUES '
        "('dev_upgraded', '2569-09', 1789000000)",
      );
      rawDb.execute(
        'INSERT INTO doc_counters (device_id, device_no, doc_type, period, last_no) VALUES '
        "('dev_upgraded', 1, 'receipt', '2569-09', 15)",
      );
      rawDb.execute('PRAGMA user_version = 7');

      // Upgrade to v8
      final upgradedDb = AppDatabase(NativeDatabase.opened(rawDb));
      addTearDown(() => upgradedDb.close());
      final upgradedService = DocNumberService(db: upgradedDb);

      // Verify seed marker was wiped per C16 / Schema v8
      expect(await upgradedService.hasSeedMarker(deviceId: 'dev_upgraded', period: '2569-09'), isFalse);

      // Attempt offline generation -> rejected before write and before print!
      expect(
        () => upgradedService.generateNextDocNo(
          deviceId: 'dev_upgraded',
          deviceNo: 1,
          docType: 'receipt',
          now: sepClock,
          isOffline: true,
        ),
        throwsA(isA<OfflineSeedRequiredException>()),
      );

      // Online generation still works
      final onlineDocNo = await upgradedService.generateNextDocNo(
        deviceId: 'dev_upgraded',
        deviceNo: 1,
        docType: 'receipt',
        now: sepClock,
        isOffline: false,
      );
      expect(onlineDocNo, 'RC01-2569-09-0016');

      // Now perform online seed
      await upgradedService.recordSeedMarker(
        deviceId: 'dev_upgraded',
        period: '2569-09',
      );

      // Now offline generation succeeds!
      final offlineDocNo = await upgradedService.generateNextDocNo(
        deviceId: 'dev_upgraded',
        deviceNo: 1,
        docType: 'receipt',
        now: sepClock,
        isOffline: true,
      );
      expect(offlineDocNo, 'RC01-2569-09-0016');
    });

    test('offline cross-month with new month seed marker works correctly at 0001', () async {
      const devCross = 'dev_cross_month';
      final sepTime = DateTime(2026, 9, 30, 22, 0);

      // Seed September
      await service.recordSeedMarker(deviceId: devCross, period: '2569-09');

      // Issue offline bills in September up to 5
      for (var i = 1; i <= 5; i++) {
        final doc = await service.issueAndCommit(
          deviceId: devCross,
          deviceNo: 1,
          docType: 'receipt',
          now: sepTime,
          isOffline: true,
        );
        expect(doc, 'RC01-2569-09-${i.toString().padLeft(4, '0')}');
      }
      expect(await service.getLastNo(deviceId: devCross, docType: 'receipt', period: '2569-09'), 5);

      // Advance clock past midnight into October (new period 2569-10)
      final octTime = DateTime(2026, 10, 1, 8, 30);

      // Before October has seed marker: offline generation is prohibited!
      expect(
        () => service.generateNextDocNo(
          deviceId: devCross,
          deviceNo: 1,
          docType: 'receipt',
          now: octTime,
          isOffline: true,
        ),
        throwsA(isA<OfflineSeedRequiredException>()),
      );

      // Online generation works even without October marker
      final octOnline = await service.generateNextDocNo(
        deviceId: devCross,
        deviceNo: 1,
        docType: 'receipt',
        now: octTime,
        isOffline: false,
      );
      expect(octOnline, 'RC01-2569-10-0001');

      // Record October seed marker
      await service.recordSeedMarker(deviceId: devCross, period: '2569-10');

      // Now offline generation in October succeeds and starts at 0001!
      final oct1 = await service.issueAndCommit(
        deviceId: devCross,
        deviceNo: 1,
        docType: 'receipt',
        now: octTime,
        isOffline: true,
      );
      expect(oct1, 'RC01-2569-10-0001');

      final oct2 = await service.issueAndCommit(
        deviceId: devCross,
        deviceNo: 1,
        docType: 'receipt',
        now: octTime,
        isOffline: true,
      );
      expect(oct2, 'RC01-2569-10-0002');

      // Verify counters
      expect(await service.getLastNo(deviceId: devCross, docType: 'receipt', period: '2569-10'), 2);
      expect(await service.getLastNo(deviceId: devCross, docType: 'receipt', period: '2569-09'), 5);
    });

    test('integration with DocCounterSeeder: seeder populates marker unlocking offline numbering', () async {
      const seederDev = 'dev_pos_seeder';
      final seederTime = DateTime(2026, 9, 15, 11, 0);

      // Mock server response for GET /api/v1/doc-counters
      final client = ApiClient(
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/doc-counters');
          return http.Response(
            jsonEncode({
              'status': 'success',
              'data': {
                'deviceId': seederDev,
                'deviceNo': 1,
                'period': '2569-09',
                'counters': [
                  {'docType': 'receipt', 'period': '2569-09', 'lastNo': 10},
                  {'docType': 'cn', 'period': '2569-09', 'lastNo': 2},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final seeder = DocCounterSeeder(db: db, apiClient: client);

      // Before seeding: offline generation throws
      expect(
        () => service.generateNextDocNo(
          deviceId: seederDev,
          deviceNo: 1,
          docType: 'receipt',
          now: seederTime,
          isOffline: true,
        ),
        throwsA(isA<OfflineSeedRequiredException>()),
      );

      // Perform seed
      final seeded = await seeder.seed();
      expect(seeded, isTrue);

      // After seeding: seed marker is present
      expect(await service.hasSeedMarker(deviceId: seederDev, period: '2569-09'), isTrue);

      // Offline generation now succeeds and starts from server's high-water mark (10 + 1 = 11)
      final docNo = await service.generateNextDocNo(
        deviceId: seederDev,
        deviceNo: 1,
        docType: 'receipt',
        now: seederTime,
        isOffline: true,
      );
      expect(docNo, 'RC01-2569-09-0011');
    });
  });
}
