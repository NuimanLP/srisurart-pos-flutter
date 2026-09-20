import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_sales_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/returns_screen.dart';

import 'support/fake_sync_facade.dart';

void setWideViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
  });
  group('SalesRepository.voidSaleOffline', () {
    late AppDatabase db;
    late SalesRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = SalesRepository(db);

      // Seed product
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'p_test',
              partNo: 'PN-001',
              name: 'Brake Pad',
              nameTH: 'ผ้าเบรก',
              category: 'เบรก',
              brand: 'Honda',
              price: 200,
              cost: 100,
              stock: 10,
              minStock: 2,
            ),
          );

      // Seed customer
      await db.into(db.customers).insert(
            CustomersCompanion.insert(
              id: 'c_test',
              code: 'CUS-001',
              name: 'สมชาย',
              nameTH: 'สมชาย',
              phone: const Value('0812345678'),
              points: const Value(50),
              totalSpend: const Value(500),
              createdAt: '2026-09-01',
            ),
          );

      // Seed mechanic
      await db.into(db.mechanics).insert(
            MechanicsCompanion.insert(
              id: 'm_test',
              code: 'MEC-001',
              name: 'ช่างศักดิ์',
              phone: const Value('0898765432'),
              totalSales: const Value(1000),
              totalDiscount: const Value(100),
              creditBalance: const Value(600),
              createdAt: '2026-09-01',
            ),
          );
    });

    tearDown(() async {
      await db.close();
    });

    test('successfully voids bill, restores stock, and reverses customer/mechanic ledger', () async {
      const saleId = 's_void_1';
      final saleDate = DateTime(2026, 9, 20, 10, 0);

      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC-2569-09-001',
              subtotal: 400,
              discount: 0,
              total: 400,
              paymentMethod: 'เครดิตช่าง',
              customerId: 'c_test',
              customerName: 'สมชาย',
              mechanicId: 'm_test',
              mechanicName: 'ช่างศักดิ์',
              mechanicDelta: -40,
              pointsGranted: 40,
              date: saleDate,
              voided: false,
              voidedAt: null,
              soldOffline: true,
              voidReason: null,
            ),
          );

      await db.into(db.saleItems).insert(
            SaleItemsCompanion.insert(
              saleId: saleId,
              productId: 'p_test',
              partNo: const Value('PN-001'),
              name: 'Brake Pad',
              qty: 2,
              price: 200,
            ),
          );

      final voidedSale = await repo.voidSaleOffline(saleId, 'ลูกค้าขอยกเลิกและเปลี่ยนสินค้า');

      expect(voidedSale.voided, isTrue);
      expect(voidedSale.voidReason, 'ลูกค้าขอยกเลิกและเปลี่ยนสินค้า');
      expect(voidedSale.voidedAt, isNotNull);

      // Product stock restored from 10 to 12
      final p = await (db.select(db.products)..where((t) => t.id.equals('p_test'))).getSingle();
      expect(p.stock, 12);

      // Customer spend & points reversed
      final c = await (db.select(db.customers)..where((t) => t.id.equals('c_test'))).getSingle();
      expect(c.totalSpend, 100); // 500 - 400
      expect(c.points, 10); // 50 - 40

      // Mechanic ledger reversed
      final m = await (db.select(db.mechanics)..where((t) => t.id.equals('m_test'))).getSingle();
      expect(m.totalSales, 600); // 1000 - 400
      expect(m.creditBalance, 200); // 600 - 400 (since paymentMethod == 'เครดิตช่าง')
      expect(m.totalDiscount, 60); // 100 - 40
    });

    test('throws ArgumentError if reason is empty or whitespace', () async {
      const saleId = 's_void_2';
      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC-2569-09-002',
              subtotal: 200,
              discount: 0,
              total: 200,
              paymentMethod: 'เงินสด',
              pointsGranted: 20,
              date: DateTime.now(),
              voided: false,
              soldOffline: true,
            ),
          );

      expect(
        () => repo.voidSaleOffline(saleId, '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws Exception if sale does not exist', () async {
      expect(
        () => repo.voidSaleOffline('non_existent', 'เหตุผล'),
        throwsA(predicate((e) => e.toString().contains('Sale not found'))),
      );
    });

    test('throws Exception if sale is already voided', () async {
      const saleId = 's_void_3';
      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC-2569-09-003',
              subtotal: 200,
              discount: 0,
              total: 200,
              paymentMethod: 'เงินสด',
              pointsGranted: 20,
              date: DateTime.now(),
              voided: true,
              voidedAt: DateTime.now(),
              soldOffline: true,
            ),
          );

      expect(
        () => repo.voidSaleOffline(saleId, 'เหตุผล'),
        throwsA(predicate((e) => e.toString().contains('already voided'))),
      );
    });

    test('throws Exception if sale has returns', () async {
      const saleId = 's_void_4';
      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC-2569-09-004',
              subtotal: 200,
              discount: 0,
              total: 200,
              paymentMethod: 'เงินสด',
              pointsGranted: 20,
              date: DateTime.now(),
              voided: false,
              soldOffline: true,
            ),
          );

      await db.into(db.returns).insert(
            ReturnRow(
              id: 'ret_001',
              cnNo: 'CN-001',
              saleId: saleId,
              receiptNo: 'RC-2569-09-004',
              refundSubtotal: 200,
              refundDiscount: 0,
              refundTotal: 200,
              refundMethod: 'เงินสด',
              reason: 'คืนสินค้า',
              date: DateTime.now(),
            ),
          );

      expect(
        () => repo.voidSaleOffline(saleId, 'เหตุผล'),
        throwsA(predicate((e) => e.toString().contains('บิลนี้มีการคืนสินค้าแล้ว'))),
      );
    });
  });

  group('ApiSalesRepository.voidSaleOffline', () {
    late AppDatabase db;
    late SalesRepository driftRepo;
    late ApiSalesRepository apiRepo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      driftRepo = SalesRepository(db);
      apiRepo = ApiSalesRepository(
        api: ApiClient(baseUrl: 'http://localhost:3000'),
        db: db,
        drift: driftRepo,
      );

      // Seed product
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'p_api_test',
              partNo: 'PN-002',
              name: 'Engine Oil',
              nameTH: 'น้ำมันเครื่อง',
              category: 'น้ำมัน',
              brand: 'Motul',
              price: 350,
              cost: 200,
              stock: 5,
              minStock: 1,
            ),
          );
    });

    tearDown(() async {
      await db.close();
    });

    test('rejects online bill with VOID_NEEDS_ONLINE', () async {
      const saleId = 's_online_bill';
      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC-ONLINE-001',
              subtotal: 350,
              discount: 0,
              total: 350,
              paymentMethod: 'เงินสด',
              pointsGranted: 35,
              date: DateTime.now(),
              voided: false,
              soldOffline: false, // ONLINE BILL
            ),
          );

      try {
        await apiRepo.voidSaleOffline(saleId, 'ขอยกเลิก');
        fail('Should throw VOID_NEEDS_ONLINE');
      } on PosException catch (e) {
        expect(e.code, 'VOID_NEEDS_ONLINE');
        expect(e.message, 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น');
      }

      // Assert bill was NOT voided in database
      final sale = await (db.select(db.sales)..where((t) => t.id.equals(saleId))).getSingle();
      expect(sale.voided, isFalse);
    });

    test('voids soldOffline bill and writes sale.void_offline op to outbox_ops', () async {
      const saleId = 's_offline_bill';
      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC-OFFLINE-001',
              subtotal: 350,
              discount: 0,
              total: 350,
              paymentMethod: 'เงินสด',
              pointsGranted: 35,
              date: DateTime.now(),
              voided: false,
              soldOffline: true, // OFFLINE BILL
              shiftId: 'sh_01',
            ),
          );

      await db.into(db.saleItems).insert(
            SaleItemsCompanion.insert(
              saleId: saleId,
              productId: 'p_api_test',
              partNo: const Value('PN-002'),
              name: 'Engine Oil',
              qty: 1,
              price: 350,
            ),
          );

      final result = await apiRepo.voidSaleOffline(saleId, 'ลูกค้าเปลี่ยนใจ');

      expect(result.voided, isTrue);
      expect(result.voidReason, 'ลูกค้าเปลี่ยนใจ');

      // Product stock restored from 5 to 6
      final p = await (db.select(db.products)..where((t) => t.id.equals('p_api_test'))).getSingle();
      expect(p.stock, 6);

      // Verify outbox_ops has sale.void_offline op
      final ops = await db.select(db.outboxOps).get();
      expect(ops.length, 1);
      final op = ops.first;
      expect(op.type, 'sale.void_offline');
      expect(op.status, 'pending');

      final payload = jsonDecode(op.payload) as Map<String, dynamic>;
      expect(payload['saleId'], saleId);
      expect(payload['reason'], 'ลูกค้าเปลี่ยนใจ');

      final aggregates = (jsonDecode(op.aggregates) as List).cast<String>();
      expect(aggregates, contains('sale:$saleId'));
      expect(aggregates, contains('shift:sh_01'));
    });
  });

  group('ReturnsScreen UI for Offline Void (Slice 11-c / #276)', () {
    testWidgets('shows "✕ ยกเลิกบิลออฟไลน์" only on soldOffline bills in Degraded mode', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Seed offline bill
      const offlineSaleId = 's_ui_offline';
      await db.into(db.sales).insert(
            SaleRow(
              id: offlineSaleId,
              receiptNo: 'RC-OFF-01',
              subtotal: 100,
              discount: 0,
              total: 100,
              paymentMethod: 'เงินสด',
              pointsGranted: 10,
              date: DateTime.now(),
              voided: false,
              soldOffline: true,
            ),
          );
      await db.into(db.saleItems).insert(
            SaleItemsCompanion.insert(
              saleId: offlineSaleId,
              productId: 'p1',
              name: 'Part 1',
              qty: 1,
              price: 100,
            ),
          );

      // Seed online bill
      const onlineSaleId = 's_ui_online';
      await db.into(db.sales).insert(
            SaleRow(
              id: onlineSaleId,
              receiptNo: 'RC-ON-01',
              subtotal: 200,
              discount: 0,
              total: 200,
              paymentMethod: 'เงินสด',
              pointsGranted: 20,
              date: DateTime.now(),
              voided: false,
              soldOffline: false,
            ),
          );
      await db.into(db.saleItems).insert(
            SaleItemsCompanion.insert(
              saleId: onlineSaleId,
              productId: 'p2',
              name: 'Part 2',
              qty: 2,
              price: 100,
            ),
          );

      final fakeSync = FakeSyncFacade(initialStatus: SyncStatus.degraded);

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, syncFacade: fakeSync),
          child: const MaterialApp(home: Scaffold(body: ReturnsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      // Select offline bill
      await tester.tap(find.text('RC-OFF-01'));
      await tester.pumpAndSettle();

      // "✕ ยกเลิกบิลออฟไลน์" should be visible
      expect(find.text('✕ ยกเลิกบิลออฟไลน์'), findsOneWidget);
      expect(find.text('✕ ยกเลิกบิลทั้งบิล'), findsNothing);

      // Select online bill
      await tester.tap(find.text('RC-ON-01'));
      await tester.pumpAndSettle();

      // Online bill in Degraded mode must NOT show offline void button
      expect(find.text('✕ ยกเลิกบิลออฟไลน์'), findsNothing);
      expect(find.text('✕ ยกเลิกบิลทั้งบิล'), findsNothing);

      // Switch to Online mode
      fakeSync.emitStatus(SyncStatus.online);
      await tester.pumpAndSettle();

      // In Online mode, standard "✕ ยกเลิกบิลทั้งบิล" shows for bills
      expect(find.text('✕ ยกเลิกบิลทั้งบิล'), findsOneWidget);
      expect(find.text('✕ ยกเลิกบิลออฟไลน์'), findsNothing);
    });

    testWidgets('cancelling offline bill enforces mandatory reason and marks bill voided', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      const offlineSaleId = 's_ui_reason_test';
      await db.into(db.sales).insert(
            SaleRow(
              id: offlineSaleId,
              receiptNo: 'RC-OFF-99',
              subtotal: 150,
              discount: 0,
              total: 150,
              paymentMethod: 'เงินสด',
              pointsGranted: 15,
              date: DateTime.now(),
              voided: false,
              soldOffline: true,
            ),
          );
      await db.into(db.saleItems).insert(
            SaleItemsCompanion.insert(
              saleId: offlineSaleId,
              productId: 'p99',
              name: 'Part 99',
              qty: 1,
              price: 150,
            ),
          );

      final fakeSync = FakeSyncFacade(initialStatus: SyncStatus.degraded);

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, syncFacade: fakeSync),
          child: const MaterialApp(home: Scaffold(body: ReturnsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      // Select offline bill
      await tester.tap(find.text('RC-OFF-99'));
      await tester.pumpAndSettle();

      // Tap "✕ ยกเลิกบิลออฟไลน์"
      await tester.tap(find.text('✕ ยกเลิกบิลออฟไลน์'));
      await tester.pumpAndSettle();

      // Dialog opens
      expect(find.text('ยกเลิกบิลออฟไลน์'), findsOneWidget);
      expect(find.text('เหตุผลในการยกเลิกบิล'), findsOneWidget);

      // Try confirming without reason -> validation error
      await tester.tap(find.text('ยืนยันยกเลิกบิล'));
      await tester.pumpAndSettle();

      expect(find.text('กรุณาระบุเหตุผลในการยกเลิกบิล'), findsOneWidget);

      // Enter valid reason
      await tester.enterText(find.byType(TextFormField), 'ลูกค้าไม่ต้องการสินค้าแล้ว');
      await tester.pumpAndSettle();

      // Confirm void
      await tester.tap(find.text('ยืนยันยกเลิกบิล'));
      await tester.pumpAndSettle();

      // Toast / dialog closes, bill is voided
      expect(find.text('ยกเลิกบิลสำเร็จ'), findsOneWidget);

      final saleInDb = await (db.select(db.sales)..where((t) => t.id.equals(offlineSaleId))).getSingle();
      expect(saleInDb.voided, isTrue);
      expect(saleInDb.voidReason, 'ลูกค้าไม่ต้องการสินค้าแล้ว');
    });
  });
}
