// Integration test for Ticket #194 (Slice 14-c, Lane B / team/2):
// Offline Credit Limit Override (CheckoutScreen -> ApiSalesRepository -> SyncService -> outbox_ops).
//
// Verifies that:
// 1. When degraded/offline and bill exceeds mechanic credit limit:
//    - Cashier confirms warning dialog -> Sale saved locally, outbox_ops created with overrideCreditLimit: true.
// 2. When cashier cancels warning dialog -> No sale saved, outbox_ops empty.
// 3. When degraded/offline and bill is within mechanic credit limit:
//    - No dialog shown -> Sale saved locally, outbox_ops created with overrideCreditLimit: false.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_sales_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/services/doc_number_service.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

class _MockTokenStorage implements TokenStorage {
  @override
  Future<String?> getAccessToken() async => 'test-access-token';
  @override
  Future<void> setAccessToken(String? token) async {}

  @override
  Future<String?> getRefreshToken() async => 'test-refresh-token';
  @override
  Future<void> setRefreshToken(String? token) async {}

  @override
  Future<String?> getDeviceToken() async => 'test-device-token';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> setupHarness({
    required WidgetTester tester,
    required AppDatabase db,
    required bool overLimit,
    required bool confirmDialog,
    required Future<void> Function(SyncService syncService) onDegrade,
  }) async {
    tester.view.physicalSize = const Size(1800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const devId = 'pos-device-01';
    const devNo = 1;

    // Seed shift
    final now = DateTime.now();
    await db.into(db.shifts).insert(
          ShiftsCompanion.insert(
            id: 'tsh-local-open',
            dateStr: '2026-09-19',
            startingCash: 1000.0,
            openedAt: now,
            isActive: const Value(true),
          ),
        );

    // Seed doc counters & seed marker
    final period = DocNumberService.formatPeriod(now);
    await db.into(db.docCounterSeeds).insert(
          DocCounterSeedsCompanion.insert(
            deviceId: devId,
            period: period,
            seededAt: now,
          ),
        );
    await db.into(db.docCounters).insert(
          DocCountersCompanion.insert(
            deviceId: devId,
            deviceNo: devNo,
            docType: 'receipt',
            period: period,
            lastNo: 15,
          ),
        );

    final mechanics = await db.select(db.mechanics).get();
    final mech = mechanics.first;
    await db.update(db.mechanics).write(
          MechanicsCompanion(
            creditBalance: const Value(0),
            creditLimit: Value(overLimit ? 0 : 900000),
          ),
        );

    final tokenStorage = _MockTokenStorage();
    final apiClient = ApiClient(
      baseUrl: 'http://test-server.example',
      tokenStorage: tokenStorage,
      httpClient: MockClient((req) async => throw http.ClientException('Offline')),
    );
    final docNumberService = DocNumberService(db: db);
    final syncService = SyncService(
      db: db,
      apiClient: apiClient,
      tokenStorage: tokenStorage,
      httpClient: MockClient((req) async => throw http.ClientException('Offline')),
      autoStartHealthProbe: false,
    );
    addTearDown(syncService.dispose);

    await onDegrade(syncService);

    final salesRepo = ApiSalesRepository(
      api: apiClient,
      db: db,
      drift: SalesRepository(db),
      deviceId: devId,
      deviceNo: devNo,
      syncService: syncService,
      docNumberService: docNumberService,
    );

    final cartCubit = CartCubit();
    final pendingQuoteCubit = PendingQuoteCubit();
    addTearDown(cartCubit.close);
    addTearDown(pendingQuoteCubit.close);

    final p = (await ProductsRepository(db).getAll()).firstWhere((x) => x.stock >= 1);
    cartCubit.add(p);

    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(
          db,
          apiClient: apiClient,
          syncFacade: syncService,
        ),
        child: RepositoryProvider<SalesRepository>.value(
          value: salesRepo,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
              BlocProvider<CartCubit>.value(value: cartCubit),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(0.8)),
                  child: const Scaffold(body: CheckoutScreen()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // Pick mechanic
    await tester.enterText(
      find.widgetWithText(TextField, 'ค้นหาช่าง / ชื่อเล่น / เบอร์…'),
      mech.nameTH ?? mech.name,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(mech.nameTH ?? mech.name).last);
    await tester.pumpAndSettle();

    // Tap credit payment
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').startsWith('เครดิตช่าง'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    // Tap Pay button
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  '),
      ),
    );
    await tester.pumpAndSettle();

    // If over limit, confirm or cancel dialog
    if (find.text('ยืนยัน').evaluate().isNotEmpty) {
      await tester.tap(find.text(confirmDialog ? 'ยืนยัน' : 'ยกเลิก'));
      await tester.pumpAndSettle();
    }

    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  testWidgets(
    'Degraded mode: confirming credit limit dialog saves sale and outbox_ops with overrideCreditLimit: true',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.runAsync(() async {
        await setupHarness(
          tester: tester,
          db: db,
          overLimit: true,
          confirmDialog: true,
          onDegrade: (sync) async {
            sync.recordNonVerdictWrite();
            expect(sync.currentStatus, SyncStatus.degraded);
          },
        );

        // 1. Verify sale saved in Drift
        final sales = await db.select(db.sales).get();
        expect(sales, hasLength(1));
        final sale = sales.single;
        expect(sale.receiptNo, startsWith('RC01-'));
        expect(sale.paymentMethod, 'เครดิตช่าง');
        expect(sale.shiftId, 'tsh-local-open');

        // 2. Verify sale_items saved in Drift
        final items = await db.select(db.saleItems).get();
        expect(items, isNotEmpty);
        expect(items.every((i) => i.saleId == sale.id), isTrue);

        // 3. Verify outbox_ops
        final ops = await db.select(db.outboxOps).get();
        expect(ops, hasLength(1));
        final op = ops.single;
        expect(op.type, 'sale.create');
        expect(op.status, 'pending');

        final payload = jsonDecode(op.payload) as Map<String, dynamic>;
        expect(payload['id'], sale.id);
        expect(payload['receiptNo'], sale.receiptNo);
        expect(payload['paymentMethod'], 'เครดิตช่าง');
        expect(
          payload['overrideCreditLimit'],
          isTrue,
          reason: 'Slice 14-c / #194: overrideCreditLimit must be true when cashier confirms',
        );

        final aggregates = (jsonDecode(op.aggregates) as List).cast<String>();
        expect(aggregates, contains('sale:${sale.id}'));
        expect(aggregates, contains('shift:tsh-local-open'));
        expect(aggregates, contains('mechanic:${sale.mechanicId}'));
      });
    },
  );

  testWidgets(
    'Degraded mode: cancelling credit limit dialog stops checkout without saving sale or outbox op',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.runAsync(() async {
        await setupHarness(
          tester: tester,
          db: db,
          overLimit: true,
          confirmDialog: false,
          onDegrade: (sync) async {
            sync.recordNonVerdictWrite();
          },
        );

        final sales = await db.select(db.sales).get();
        expect(sales, isEmpty, reason: 'Sale should not be saved when dialog is cancelled');

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty, reason: 'Outbox op must not be queued when dialog is cancelled');
      });
    },
  );

  testWidgets(
    'Degraded mode: sale within credit limit saves sale and outbox op with overrideCreditLimit: false',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.runAsync(() async {
        await setupHarness(
          tester: tester,
          db: db,
          overLimit: false,
          confirmDialog: false,
          onDegrade: (sync) async {
            sync.recordNonVerdictWrite();
          },
        );

        final sales = await db.select(db.sales).get();
        expect(sales, hasLength(1));

        final ops = await db.select(db.outboxOps).get();
        expect(ops, hasLength(1));
        final payload = jsonDecode(ops.single.payload) as Map<String, dynamic>;
        expect(
          payload['overrideCreditLimit'],
          isFalse,
          reason: 'Sale within credit limit must carry overrideCreditLimit: false',
        );
      });
    },
  );
}
