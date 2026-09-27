// #473 — discarding a queued sale.create / return.create must undo what the
// offline write applied locally (stock, customer spend/points, mechanic stats
// and credit, the parent bill's auto-void), not only delete the rows.
//
// Each test drives the REAL offline write path (ApiSalesRepository /
// ApiReturnsRepository), snapshots the ledger before it, discards the op, and
// compares — so any drift between the write and its reversal fails here.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_returns_repository.dart';
import 'package:srisurart_pos/data/repositories/api/api_sales_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/services/doc_number_service.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class _MemTokenStorage implements TokenStorage {
  @override
  Future<String?> getAccessToken() async => 'access-1';
  @override
  Future<void> setAccessToken(String? token) async {}
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<String?> getDeviceToken() async => 'pos-device-token-01';
  @override
  Future<void> setDeviceToken(String? token) async {}
  @override
  Future<AuthUser?> getUser() async => null;
  @override
  Future<void> setUser(AuthUser? user) async {}
  @override
  Future<void> clearAuthTokens() async {}
  @override
  Future<void> clearAll() async {}
}

/// Stock, customer and mechanic as one comparable value.
typedef Ledger = ({
  int stock,
  double spend,
  int points,
  double mSales,
  double mDiscount,
  double mMarkup,
  double mCredit,
});

void main() {
  late AppDatabase db;
  late List<http.Request> sent;
  late SyncService sync;
  late bool serverHasRow;

  ApiClient client() => ApiClient(
    baseUrl: 'http://server.test',
    tokenStorage: _MemTokenStorage(),
    httpClient: MockClient((req) async {
      sent.add(req);
      if (req.url.path == '/api/v1/sync/discards') {
        return http.Response(
          jsonEncode({
            'status': 'success',
            'data': {'serverHasRow': serverHasRow},
          }),
          200,
        );
      }
      // The offline write paths must never reach the server.
      throw http.ClientException('Offline');
    }),
  );

  Future<Ledger> ledger() async {
    final p = await (db.select(
      db.products,
    )..where((t) => t.id.equals('tp1'))).getSingle();
    final c = await (db.select(
      db.customers,
    )..where((t) => t.id.equals('tc1'))).getSingle();
    final m = await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals('tm1'))).getSingle();
    return (
      stock: p.stock,
      spend: c.totalSpend,
      points: c.points,
      mSales: m.totalSales,
      mDiscount: m.totalDiscount,
      mMarkup: m.totalMarkup,
      mCredit: m.creditBalance,
    );
  }

  Future<String> onlyOpId() async =>
      (await db.select(db.outboxOps).get()).single.opId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    serverHasRow = false;
    sync = SyncService(
      db: db,
      apiClient: client(),
      tokenStorage: _MemTokenStorage(),
      httpClient: MockClient((_) async => throw http.ClientException('x')),
      autoStartHealthProbe: false,
    );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: 'tp1',
            partNo: 'TP-1',
            name: 'Brake Pad',
            nameTH: 'ผ้าเบรก',
            category: 'เบรก',
            brand: 'X',
            price: 100,
            cost: 60,
            stock: 10,
            minStock: 1,
          ),
        );
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: 'tc1',
            code: 'C-1',
            name: 'Somchai',
            nameTH: 'สมชาย',
            createdAt: '2026-01-01',
            points: const Value(50),
            totalSpend: const Value(500),
          ),
        );
    await db
        .into(db.mechanics)
        .insert(
          MechanicsCompanion.insert(
            id: 'tm1',
            code: 'M-1',
            name: 'Chang',
            createdAt: '2026-01-01',
            creditLimit: const Value(5000),
            creditBalance: const Value(300),
            totalSales: const Value(1000),
            totalDiscount: const Value(40),
            totalMarkup: const Value(10),
          ),
        );
    await db
        .into(db.shifts)
        .insert(
          ShiftsCompanion.insert(
            id: 'sh-open',
            dateStr: '2026-09-28',
            startingCash: 500,
            openedAt: DateTime(2026, 9, 28, 8),
            isActive: const Value(true),
          ),
        );
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  group('discard sale.create', () {
    ApiSalesRepository salesRepo() => ApiSalesRepository(
      api: client(),
      db: db,
      drift: SalesRepository(db),
      isOffline: true,
    );

    const creditSale = SaleInput(
      subtotal: 215,
      discount: 0,
      total: 200,
      paymentMethod: 'เครดิตช่าง',
      customerId: 'tc1',
      customerName: 'สมชาย',
      mechanicId: 'tm1',
      mechanicName: 'ช่างเอ',
      mechanicDelta: -15,
      items: [
        SaleLineInput(
          productId: 'tp1',
          name: 'Brake Pad',
          qty: 2,
          price: 100,
          partNo: 'TP-1',
          nameTH: 'ผ้าเบรก',
        ),
      ],
    );

    test(
      'serverHasRow=false: stock, customer and mechanic return to before',
      () async {
        final before = await ledger();
        final sale = await salesRepo().saveSale(creditSale);
        expect(await ledger(), isNot(before), reason: 'the write moved them');

        final result = await sync.discard(await onlyOpId(), 'ลูกค้าไม่เอา');

        expect(result.serverHasRow, isFalse);
        expect(await ledger(), before);
        expect(
          await (db.select(
            db.sales,
          )..where((t) => t.id.equals(sale.id))).getSingleOrNull(),
          isNull,
        );
        expect(await db.select(db.saleItems).get(), isEmpty);
        expect(await db.select(db.outboxOps).get(), isEmpty);
      },
    );

    test('a cash sale never touches the mechanic credit balance', () async {
      final before = await ledger();
      await salesRepo().saveSale(
        const SaleInput(
          subtotal: 100,
          discount: 0,
          total: 110,
          paymentMethod: 'เงินสด',
          mechanicId: 'tm1',
          mechanicName: 'ช่างเอ',
          mechanicDelta: 10,
          items: [
            SaleLineInput(
              productId: 'tp1',
              name: 'Brake Pad',
              qty: 1,
              price: 100,
            ),
          ],
        ),
      );

      await sync.discard(await onlyOpId(), 'ทดสอบ');

      expect(await ledger(), before);
    });

    test('serverHasRow=true: nothing is reversed or deleted', () async {
      serverHasRow = true;
      final sale = await salesRepo().saveSale(creditSale);
      final afterWrite = await ledger();

      final result = await sync.discard(await onlyOpId(), 'ทดสอบ');

      expect(result.serverHasRow, isTrue);
      expect(await ledger(), afterWrite);
      expect(
        await (db.select(
          db.sales,
        )..where((t) => t.id.equals(sale.id))).getSingleOrNull(),
        isNotNull,
      );
    });

    test(
      'a bill with a local credit note is refused before the server hears of it',
      () async {
        final sale = await salesRepo().saveSale(creditSale);
        await db
            .into(db.returns)
            .insert(
              ReturnRow(
                id: 'r-local',
                cnNo: 'CN-1',
                saleId: sale.id,
                receiptNo: sale.receiptNo,
                refundSubtotal: 100,
                refundDiscount: 0,
                refundTotal: 100,
                refundMethod: 'เงินสด',
                reason: '',
                date: DateTime.now(),
              ),
            );
        final afterWrite = await ledger();

        await expectLater(
          sync.discard(await onlyOpId(), 'ทดสอบ'),
          throwsA(isA<StateError>()),
        );

        expect(
          sent.where((r) => r.url.path == '/api/v1/sync/discards'),
          isEmpty,
        );
        expect(await ledger(), afterWrite);
        expect(await db.select(db.outboxOps).get(), hasLength(1));
      },
    );
  });

  group('discard return.create', () {
    late DocNumberService numbers;

    ApiReturnsRepository returnsRepo() {
      numbers = DocNumberService(db: db);
      return ApiReturnsRepository(
        api: client(),
        db: db,
        drift: ReturnsRepository(db),
        syncService: sync,
        docNumberService: numbers,
      );
    }

    setUp(() async {
      // A synced parent bill: 5 pads, ฿500 less ฿50 discount, on credit, with
      // a -20 mechanic discount; its effects are already in the ledger seed.
      await db
          .into(db.sales)
          .insert(
            SaleRow(
              id: 'sale-1',
              receiptNo: 'RC-00042',
              subtotal: 500,
              discount: 50,
              total: 450,
              paymentMethod: 'เครดิตช่าง',
              customerId: 'tc1',
              customerName: 'สมชาย',
              mechanicId: 'tm1',
              mechanicName: 'ช่างเอ',
              mechanicDelta: -20,
              pointsGranted: 45,
              date: DateTime(2026, 9, 1),
              voided: false,
              soldOffline: false,
            ),
          );
      await db
          .into(db.saleItems)
          .insert(
            SaleItemsCompanion.insert(
              saleId: 'sale-1',
              productId: 'tp1',
              name: 'Brake Pad',
              qty: 5,
              price: 100,
            ),
          );
    });

    Future<void> seedDevice() async {
      final period = DocNumberService.formatPeriod(DateTime.now());
      await numbers.recordSeedMarker(deviceId: 'dev-1', period: period);
      await numbers.commitDocNo(
        deviceId: 'dev-1',
        deviceNo: 3,
        docType: 'cn',
        period: period,
        seq: 4,
      );
    }

    Future<SaleRow> parent() =>
        (db.select(db.sales)..where((t) => t.id.equals('sale-1'))).getSingle();

    ReturnInput back(int qty, String method) => ReturnInput(
      saleId: 'sale-1',
      refundMethod: method,
      items: [
        ReturnLineInput(
          productId: 'tp1',
          name: 'Brake Pad',
          qty: qty,
          price: 100,
          originalQty: 5,
        ),
      ],
    );

    test(
      'partial หักจากเครดิต note: stock, proportional reversal and credit undone',
      () async {
        final repo = returnsRepo();
        await seedDevice();
        sync.recordNonVerdictWrite();
        final before = await ledger();

        await repo.createReturn(back(2, 'หักจากเครดิต'));
        final afterWrite = await ledger();
        expect(afterWrite.stock, before.stock + 2);
        expect(afterWrite.mCredit, lessThan(before.mCredit));

        await sync.discard(await onlyOpId(), 'คืนผิดบิล');

        expect(await ledger(), before);
        expect(await db.select(db.returns).get(), isEmpty);
        expect(await db.select(db.returnItems).get(), isEmpty);
        expect((await parent()).voided, isFalse);
      },
    );

    test('a full return: the parent bill is no longer left voided', () async {
      final repo = returnsRepo();
      await seedDevice();
      sync.recordNonVerdictWrite();
      final before = await ledger();

      await repo.createReturn(back(5, 'โอน'));
      expect((await parent()).voided, isTrue);

      await sync.discard(await onlyOpId(), 'คืนผิดบิล');

      expect(await ledger(), before);
      final sale = await parent();
      expect(sale.voided, isFalse);
      expect(sale.voidedAt, isNull);
    });

    test('serverHasRow=true: the credit note and its effects stay', () async {
      serverHasRow = true;
      final repo = returnsRepo();
      await seedDevice();
      sync.recordNonVerdictWrite();

      await repo.createReturn(back(5, 'โอน'));
      final afterWrite = await ledger();

      await sync.discard(await onlyOpId(), 'ทดสอบ');

      expect(await ledger(), afterWrite);
      expect(await db.select(db.returns).get(), hasLength(1));
      expect((await parent()).voided, isTrue);
    });
  });
}
