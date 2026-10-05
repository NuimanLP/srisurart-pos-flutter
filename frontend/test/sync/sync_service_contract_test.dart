// Contract tests for SyncService against fake server using the committed fixtures
// (docs/Backend_design/fixtures/sync-push/*.json) per Phase 2 Slice 20-c (#193)
// and 09_PHASE2_LANES.md §4.1, §5.
//
// 18 fixture files tested:
//   - sale.create (applied, rejected-stock, replay-by-key, replay-by-id, client-id-reused)
//   - return.create (applied, rejected-price)
//   - drawer.entry (applied)
//   - shift.open (applied, archived-previous)
//   - credit_payment.create (applied, rejected-overpayment)
//   - customer.create (applied)
//   - customer.update (applied)
//   - sale.void_offline (applied, rejected-online-bill)
//   - batch (stop-at-retry, no-active-user-403)

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import '../support/test_ids.dart';

class FixtureFile {
  final String name;
  final String description;
  final Map<String, dynamic> requestHeaders;
  final Map<String, dynamic> requestBody;
  final int responseStatus;
  final Map<String, dynamic> responseBody;

  FixtureFile({
    required this.name,
    required this.description,
    required this.requestHeaders,
    required this.requestBody,
    required this.responseStatus,
    required this.responseBody,
  });

  factory FixtureFile.fromMap(Map<String, dynamic> json) {
    final req = json['request'] as Map<String, dynamic>;
    final resp = json['response'] as Map<String, dynamic>;
    return FixtureFile(
      name: json['name'] as String,
      description: json['description'] as String,
      requestHeaders: (req['headers'] as Map?)?.cast<String, dynamic>() ?? {},
      requestBody: req['body'] as Map<String, dynamic>,
      responseStatus: resp['status'] as int,
      responseBody: resp['body'] as Map<String, dynamic>,
    );
  }
}

File findFixture(String filename) {
  final candidate1 = File('../docs/Backend_design/fixtures/sync-push/$filename');
  if (candidate1.existsSync()) return candidate1;
  final candidate2 = File('docs/Backend_design/fixtures/sync-push/$filename');
  if (candidate2.existsSync()) return candidate2;
  throw StateError('Fixture $filename not found in search paths');
}

FixtureFile loadFixture(String filename) {
  final file = findFixture(filename);
  final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return FixtureFile.fromMap(map);
}

class InMemoryTokenStorage implements TokenStorage {
  String? deviceToken = 'pos-device-token-01';
  String? accessToken = 'test-access-token';
  String? refreshToken = 'test-refresh-token';

  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<void> setAccessToken(String? token) async => accessToken = token;

  @override
  Future<String?> getRefreshToken() async => refreshToken;
  @override
  Future<void> setRefreshToken(String? token) async => refreshToken = token;

  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<void> setDeviceToken(String? token) async => deviceToken = token;

  @override
  Future<AuthUser?> getUser() async => null;
  @override
  Future<void> setUser(AuthUser? user) async {}

  @override
  Future<void> clearAuthTokens() async {
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<void> clearAll() async {
    accessToken = null;
    refreshToken = null;
    deviceToken = null;
  }
}

class FakeSyncServer {
  final FixtureFile fixture;
  http.Request? lastRequest;
  Map<String, dynamic>? lastDecodedBody;

  FakeSyncServer(this.fixture);

  http.Client createHttpClient() {
    return MockClient((request) async {
      if (request.url.path == '/api/v1/sync/push' && request.method == 'POST') {
        lastRequest = request;
        lastDecodedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(fixture.responseBody),
          fixture.responseStatus,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","message":"not found"}', 404);
    });
  }
}

Future<void> enqueueOpsFromFixture(AppDatabase db, FixtureFile fixture) async {
  final ops = fixture.requestBody['ops'] as List;
  for (final opRaw in ops) {
    final op = opRaw as Map<String, dynamic>;
    final opId = op['opId'] as String;
    final key = op['idempotencyKey'] as String;
    final type = op['type'] as String;
    final payload = op['payload'] as Map<String, dynamic>;

    final aggregates = <String>[];
    if (payload.containsKey('id')) {
      aggregates.add('${type.split('.').first}:${payload['id']}');
    } else if (payload.containsKey('saleId')) {
      aggregates.add('sale:${payload['saleId']}');
    }
    if (payload.containsKey('shiftId') && payload['shiftId'] != null) {
      aggregates.add('shift:${payload['shiftId']}');
    }
    if (payload.containsKey('mechanicId') && payload['mechanicId'] != null) {
      aggregates.add('mechanic:${payload['mechanicId']}');
    }

    await db.into(db.outboxOps).insert(
      OutboxOpsCompanion(
        opId: drift.Value(opId),
        idempotencyKey: drift.Value(key),
        type: drift.Value(type),
        payload: drift.Value(jsonEncode(payload)),
        aggregates: drift.Value(jsonEncode(aggregates)),
        createdAt: drift.Value(DateTime.now().toUtc()),
        status: const drift.Value('pending'),
        attempts: const drift.Value(0),
      ),
    );
  }
}

void main() {
  late AppDatabase db;
  late InMemoryTokenStorage tokenStorage;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tokenStorage = InMemoryTokenStorage();
    // #616: the shared sync-push fixtures name the seeded demo rows by testId(label).
    await db.customStatement("UPDATE products SET id = ? WHERE id = 'p1'", [testId('p1')]);
    await db.customStatement("UPDATE mechanics SET id = ? WHERE id = 'm1'", [testId('m1')]);
  });

  tearDown(() async {
    await db.close();
  });

  group('SyncService Contract Tests with Fixtures (09 §4.1, Slice 20-c / #193)', () {
    // ── 1. sale.create ───────────────────────────────────────────────────────
    group('1. sale.create fixtures', () {
      test('sale-create.applied.json: deletes op and patches product stock', () async {
        final fixture = loadFixture('sale-create.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        // Seed product p1 with stock 48
        await (db.update(db.products)..where((t) => t.id.equals(testId('p1')))).write(
          const ProductsCompanion(stock: drift.Value(48)),
        );

        await enqueueOpsFromFixture(db, fixture);
        expect((await db.select(db.outboxOps).get()).length, 1);

        await sync.push();

        // Op applied and deleted from outbox
        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);

        // Product stock patched to 45 from server response
        final p1 = await (db.select(db.products)..where((t) => t.id.equals(testId('p1')))).getSingle();
        expect(p1.stock, 45);

        // Request header verification
        expect(server.lastRequest?.headers['x-device-token'], 'pos-device-token-01');
      });

      for (final file in [
        'sale-create.applied.json',
        'sale-create.replay-by-key.json',
        'sale-create.replay-by-id.json',
      ]) {
        test('$file: patches the offline bill from the full POST /sales reply (#455)', () async {
          final fixture = loadFixture(file);
          final server = FakeSyncServer(fixture);
          final mockHttp = server.createHttpClient();
          final sync = SyncService(
            db: db,
            apiClient: ApiClient(httpClient: mockHttp),
            tokenStorage: tokenStorage,
            httpClient: mockHttp,
            autoStartHealthProbe: false,
          );

          // The bill as `_saveOffline` left it: device clock, local shift, no cost.
          await db.into(db.sales).insert(
                SaleRow(
                  id: testId('s_off_001'),
                  receiptNo: 'RC01-2569-09-0042',
                  subtotal: 255,
                  discount: 0,
                  total: 255,
                  paymentMethod: 'เงินสด',
                  // Deliberately not the server's 25: the reply's value must win.
                  pointsGranted: 0,
                  date: DateTime.utc(2026, 9, 15, 1, 0),
                  voided: false,
                  shiftId: 'sh_local',
                  soldOffline: true,
                ),
              );
          await db.into(db.saleItems).insert(
                SaleItemsCompanion.insert(
                  saleId: testId('s_off_001'),
                  productId: testId('p1'),
                  name: 'Oil Filter',
                  qty: 3,
                  price: 85,
                ),
              );
          await enqueueOpsFromFixture(db, fixture);

          await sync.push();

          expect(await db.select(db.outboxOps).get(), isEmpty);
          final reply = ((fixture.responseBody['data'] as Map)['results'] as List)
              .first['response'] as Map<String, dynamic>;
          final sale = await (db.select(db.sales)
                ..where((t) => t.id.equals(testId('s_off_001'))))
              .getSingle();
          expect(sale.shiftId, testId('sh_off_001'));
          expect(sale.pointsGranted, 25);
          expect(sale.date.isAtSameMomentAs(DateTime.parse(reply['date'] as String)), isTrue);
          final line = await (db.select(db.saleItems)
                ..where((t) => t.saleId.equals(testId('s_off_001'))))
              .getSingle();
          expect(line.costAtSale, 50.0);
          final movements = await (db.select(db.movements)
                ..where((t) => t.productId.equals(testId('p1')) & t.type.equals('sale')))
              .get();
          expect(movements, hasLength(1));
          expect(movements.single.delta, -3);
          expect(movements.single.stockAfter, 45);
        });
      }

      test('sale-create.rejected-stock.json: marks op rejected with code and message', () async {
        final fixture = loadFixture('sale-create.rejected-stock.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);

        await sync.push();

        // Op remains with status rejected
        final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_sale_002')))).getSingle();
        expect(op.status, 'rejected');
        expect(op.attempts, 0);
        expect(op.lastCode, 'INSUFFICIENT_STOCK');
        expect(op.lastMessage, 'สต็อกไม่พอ');

        // Visible in needsOwner stream
        final needsOwner = await sync.needsOwner.first;
        expect(needsOwner.any((o) => o.opId == testId('op_sale_002') && o.status == OutboxOpStatus.rejected), isTrue);
      });

      test('sale-create.replay-by-key.json: idempotent replay by key succeeds', () async {
        final fixture = loadFixture('sale-create.replay-by-key.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);
      });

      test('sale-create.replay-by-id.json: idempotent replay by client saleId succeeds', () async {
        final fixture = loadFixture('sale-create.replay-by-id.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);
      });

      test('sale-create.client-id-reused.json: marks op rejected with CLIENT_ID_REUSED', () async {
        final fixture = loadFixture('sale-create.client-id-reused.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_sale_mismatch')))).getSingle();
        expect(op.status, 'rejected');
        expect(op.lastCode, 'CLIENT_ID_REUSED');
      });
    });

    // ── 2. return.create ─────────────────────────────────────────────────────
    group('2. return.create fixtures', () {
      test('return-create.applied.json: deletes op and restores product stock', () async {
        final fixture = loadFixture('return-create.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await (db.update(db.products)..where((t) => t.id.equals(testId('p1')))).write(
          const ProductsCompanion(stock: drift.Value(45)),
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);

        final p1 = await (db.select(db.products)..where((t) => t.id.equals(testId('p1')))).getSingle();
        expect(p1.stock, 46);
      });

      test('return-create.rejected-price.json: marks op rejected with RETURN_PRICE_MISMATCH', () async {
        final fixture = loadFixture('return-create.rejected-price.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_ret_002')))).getSingle();
        expect(op.status, 'rejected');
        expect(op.lastCode, 'RETURN_PRICE_MISMATCH');
      });
    });

    // ── 3. drawer.entry & shift.open ─────────────────────────────────────────
    group('3. drawer.entry and shift.open fixtures', () {
      test('drawer-entry.applied.json: deletes drawer entry op upon applied', () async {
        final fixture = loadFixture('drawer-entry.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);
      });

      test('shift-open.applied.json: deletes shift open op upon applied', () async {
        final fixture = loadFixture('shift-open.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);
      });

      test('shift-open.archived-previous.json: acknowledges archived previous shift and deletes op', () async {
        final fixture = loadFixture('shift-open.archived-previous.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);
      });
    });

    // ── 4. credit_payment.create ─────────────────────────────────────────────
    group('4. credit_payment.create fixtures', () {
      test('credit-payment.applied.json: deletes op, patches mechanic credit balance and inserts credit payment', () async {
        final fixture = loadFixture('credit-payment.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await (db.update(db.mechanics)..where((t) => t.id.equals(testId('m1')))).write(
          const MechanicsCompanion(creditBalance: drift.Value(2000.0)),
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);

        // Authoritative balance from server patched
        final m1 = await (db.select(db.mechanics)..where((t) => t.id.equals(testId('m1')))).getSingle();
        expect(m1.creditBalance, 1000.0);

        // Credit payment row recorded
        final cp = await (db.select(db.creditPayments)..where((t) => t.id.equals(testId('cp_off_001')))).getSingle();
        expect(cp.amount, 500.0);
      });

      test('credit-payment.rejected-overpayment.json: marks op rejected with CREDIT_OVERPAYMENT', () async {
        final fixture = loadFixture('credit-payment.rejected-overpayment.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_cp_002')))).getSingle();
        expect(op.status, 'rejected');
        expect(op.lastCode, 'OVERPAYMENT');
      });
    });

    // ── 5. customer.create & customer.update ─────────────────────────────────
    group('5. customer.create and customer.update fixtures', () {
      test('customer-create.applied.json: deletes op and patches customer in Drift', () async {
        final fixture = loadFixture('customer-create.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);

        final c1 = await (db.select(db.customers)..where((t) => t.id.equals(testId('c_off_001')))).getSingle();
        expect(c1.name, 'สมชาย สายลม');
        expect(c1.points, 0);
      });

      test('customer-update.applied.json: deletes op and patches updated phone while preserving code and name', () async {
        final fixture = loadFixture('customer-update.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: testId('c_off_001'),
            code: 'CUS-PRESERVE',
            name: 'สมชาย ขายดี',
            nameTH: 'สมชาย ขายดี',
            phone: const drift.Value('0800000000'),
            createdAt: '2026-09-15T04:00:00.000Z',
          ),
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);

        final c1 = await (db.select(db.customers)..where((t) => t.id.equals(testId('c_off_001')))).getSingle();
        expect(c1.code, 'CUS-PRESERVE');
        expect(c1.name, 'สมชาย ขายดี');
        expect(c1.phone, '0899999999');
      });
    });

    // ── 6. sale.void_offline ─────────────────────────────────────────────────
    group('6. sale.void_offline fixtures', () {
      test('sale-void-offline.applied.json: deletes op and restores stock via productId key', () async {
        final fixture = loadFixture('sale-void-offline.applied.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await (db.update(db.products)..where((t) => t.id.equals(testId('p1')))).write(
          const ProductsCompanion(stock: drift.Value(45)),
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final ops = await db.select(db.outboxOps).get();
        expect(ops, isEmpty);

        final p1 = await (db.select(db.products)..where((t) => t.id.equals(testId('p1')))).getSingle();
        expect(p1.stock, 48);
      });

      test('sale-void-offline.rejected-online-bill.json: marks op rejected with VOID_NEEDS_ONLINE', () async {
        final fixture = loadFixture('sale-void-offline.rejected-online-bill.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        await sync.push();

        final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_void_002')))).getSingle();
        expect(op.status, 'rejected');
        expect(op.lastCode, 'VOID_NEEDS_ONLINE');
      });
    });

    // ── 7. Batch Behavior & Head-of-Line Blocking ────────────────────────────
    group('7. Batch fixtures (retry & 403)', () {
      test('batch.stop-at-retry.json: op 1 applied, op 2 retry stops subsequent ops and transitions op 2 to stuck after 3 retries', () async {
        final fixture = loadFixture('batch.stop-at-retry.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        expect((await db.select(db.outboxOps).get()).length, 4);

        // Push 1: op_1 is applied (deleted), op_2 receives retry -> attempts becomes 1
        await sync.push();

        final op1 = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_1')))).getSingleOrNull();
        expect(op1, isNull, reason: 'op_1 was applied and deleted');

        var op2 = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_2')))).getSingle();
        var op3 = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_3')))).getSingle();
        var op4 = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_4')))).getSingle();

        expect(op2.attempts, 1);
        expect(op2.status, 'pending');
        expect(op3.status, 'pending');
        expect(op4.status, 'pending');

        // Push 2: op_2 attempts becomes 2
        await sync.push();
        op2 = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_2')))).getSingle();
        expect(op2.attempts, 2);
        expect(op2.status, 'pending');

        // Push 3: op_2 attempts reaches 3 -> transitions to stuck (B3 / §8.4)
        await sync.push();
        op2 = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_2')))).getSingle();
        expect(op2.attempts, 3);
        expect(op2.status, 'stuck');

        // Visible in needsOwner as stuck
        final needsOwner = await sync.needsOwner.first;
        expect(needsOwner.any((o) => o.opId == testId('op_2') && o.status == OutboxOpStatus.stuck), isTrue);
      });

      test('batch.no-active-user-403.json: request-level 403 leaves all ops pending in outbox', () async {
        final fixture = loadFixture('batch.no-active-user-403.json');
        final server = FakeSyncServer(fixture);
        final mockHttp = server.createHttpClient();
        final apiClient = ApiClient(httpClient: mockHttp);
        final sync = SyncService(
          db: db,
          apiClient: apiClient,
          tokenStorage: tokenStorage,
          httpClient: mockHttp,
          autoStartHealthProbe: false,
        );

        await enqueueOpsFromFixture(db, fixture);
        expect((await db.select(db.outboxOps).get()).length, 1);

        await sync.push();

        // 403 does NOT mark op rejected or change attempts (Spec §8.1)
        final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(testId('op_1')))).getSingle();
        expect(op.status, 'pending');
        expect(op.attempts, 0);
      });
    });

    // ── 8. Replay semantics of the #452 ops (08 §6.4 AC) ─────────────────────
    //
    // The server half (replay by key / by id, `CLIENT_ID_REUSED`) is
    // `server/test/sync-push.e2e-spec.ts`. These tie the CLIENT to it, using the
    // committed `.applied` fixtures for the reply and the
    // `sale-create.client-id-reused` fixture for the refusal shape (retargeted at
    // each op — no new fixture file, the server e2e consumes that directory).
    group('8. replay semantics: shift.open / drawer.entry / return.create (#452)', () {
      /// A push server that answers each call with the next of [replies]; a
      /// null reply is a lost reply (the request went out, nothing came back).
      ({http.Client client, List<Map<String, dynamic>> bodies}) scripted(
        List<Map<String, dynamic>?> replies,
      ) {
        final bodies = <Map<String, dynamic>>[];
        var call = 0;
        final client = MockClient((request) async {
          expect(request.url.path, '/api/v1/sync/push');
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          final reply = replies[call++];
          if (reply == null) throw http.ClientException('reply lost');
          return http.Response.bytes(
            utf8.encode(jsonEncode(reply)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        return (client: client, bodies: bodies);
      }

      SyncService syncWith(http.Client client) {
        final sync = SyncService(
          db: db,
          apiClient: ApiClient(httpClient: client),
          tokenStorage: tokenStorage,
          httpClient: client,
          autoStartHealthProbe: false,
        );
        addTearDown(sync.dispose);
        return sync;
      }

      /// `sale-create.client-id-reused.json`'s refusal, retargeted at [op].
      Map<String, dynamic> clientIdReusedFor(Map<String, dynamic> op) {
        final base = loadFixture('sale-create.client-id-reused.json');
        final result = Map<String, dynamic>.from(
          ((base.responseBody['data'] as Map)['results'] as List).single as Map,
        );
        result['opId'] = op['opId'];
        result['details'] = {
          'type': op['type'],
          'id': (op['payload'] as Map)['id'],
        };
        return {
          'status': 'success',
          'data': {
            'results': [result],
          },
        };
      }

      Map<String, dynamic> opOf(FixtureFile f) =>
          (f.requestBody['ops'] as List).single as Map<String, dynamic>;

      Future<void> seedLocalRowsFor(String type) async {
        switch (type) {
          case 'shift.open':
            await db.into(db.shifts).insert(
                  ShiftsCompanion.insert(
                    id: testId('sh_off_001'),
                    dateStr: '2026-09-15',
                    startingCash: 1000,
                    // The device clock — the reply's openedAt must win.
                    openedAt: DateTime.utc(2026, 9, 15, 0, 55),
                    isActive: const drift.Value(true),
                  ),
                );
          case 'drawer.entry':
            await db.into(db.shifts).insert(
                  ShiftsCompanion.insert(
                    id: 'sh_local',
                    dateStr: '2026-09-15',
                    startingCash: 1000,
                    openedAt: DateTime.utc(2026, 9, 15, 1),
                    isActive: const drift.Value(true),
                  ),
                );
            await db.into(db.drawerEntries).insert(
                  DrawerEntryRow(
                    id: testId('de_off_001'),
                    shiftId: 'sh_local',
                    type: 'in',
                    amount: 500,
                    note: 'สำรองเงินทอน',
                    createdAt: DateTime.utc(2026, 9, 15, 1, 30),
                  ),
                );
          case 'return.create':
            // Stock as the offline credit note left it (45 + 1 back = 46 on
            // the server; the local cache says 45 before the reply lands).
            await (db.update(db.products)..where((t) => t.id.equals(testId('p1'))))
                .write(const ProductsCompanion(stock: drift.Value(45)));
            await db.into(db.returns).insert(
                  ReturnsCompanion.insert(
                    id: testId('ret_off_001'),
                    cnNo: 'CN01-2569-09-0005',
                    saleId: testId('s_off_001'),
                    receiptNo: 'RC01-2569-09-0042',
                    refundSubtotal: 85,
                    refundDiscount: 0,
                    refundTotal: 85,
                    refundMethod: 'เงินสด',
                    date: DateTime.utc(2026, 9, 15, 3),
                  ),
                );
        }
      }

      Future<void> expectPatchedOnceFor(String type) async {
        switch (type) {
          case 'shift.open':
            final shift = await (db.select(db.shifts)
                  ..where((t) => t.id.equals(testId('sh_off_001'))))
                .getSingle();
            expect(
              shift.openedAt.isAtSameMomentAs(
                DateTime.parse('2026-09-15T01:00:00.000Z'),
              ),
              isTrue,
            );
            expect(await db.select(db.shifts).get(), hasLength(1));
          case 'drawer.entry':
            // One entry — the replay did not add a second one.
            expect(await db.select(db.drawerEntries).get(), hasLength(1));
          case 'return.create':
            final p1 = await (db.select(db.products)
                  ..where((t) => t.id.equals(testId('p1'))))
                .getSingle();
            // The server's number once — never 45 + 1 + 1.
            expect(p1.stock, 46);
            final ret = await db.select(db.returns).get();
            expect(ret, hasLength(1));
            expect(ret.single.cnNo, 'CN01-2569-09-0005');
        }
      }

      for (final (file, type) in [
        ('shift-open.applied.json', 'shift.open'),
        ('drawer-entry.applied.json', 'drawer.entry'),
        ('return-create.applied.json', 'return.create'),
      ]) {
        test(
          '$type: a lost push reply is re-sent under the SAME key + payload, and '
          'the replayed reply is patched once',
          () async {
            final fixture = loadFixture(file);
            await seedLocalRowsFor(type);
            await enqueueOpsFromFixture(db, fixture);
            final server = scripted([null, fixture.responseBody]);
            final sync = syncWith(server.client);

            await sync.push(); // committed server-side, reply lost
            final parked = await db.select(db.outboxOps).getSingle();
            expect(parked.status, 'pending');
            expect(parked.attempts, 1);

            await sync.push(); // the server replays by key → same result

            expect(await db.select(db.outboxOps).get(), isEmpty);
            expect(server.bodies, hasLength(2));
            final first = (server.bodies[0]['ops'] as List).single as Map;
            final second = (server.bodies[1]['ops'] as List).single as Map;
            expect(second['idempotencyKey'], first['idempotencyKey']);
            expect(second['idempotencyKey'], opOf(fixture)['idempotencyKey']);
            expect(second['payload'], first['payload']);
            expect(second['payload'], opOf(fixture)['payload']);
            await expectPatchedOnceFor(type);
          },
        );

        test(
          '$type: replay by id — under a key the server no longer holds, the '
          'op still carries the local row\'s client id, and the replayed reply '
          'is patched once',
          () async {
            final fixture = loadFixture(file);
            await seedLocalRowsFor(type);
            await enqueueOpsFromFixture(db, fixture);
            // As in `sale-create.replay-by-id.json`: a fresh key, the same id.
            await db.update(db.outboxOps).write(
                  const OutboxOpsCompanion(
                    idempotencyKey: drift.Value('k_fresh_key'),
                  ),
                );
            final server = scripted([fixture.responseBody]);
            final sync = syncWith(server.client);

            await sync.push();

            expect(await db.select(db.outboxOps).get(), isEmpty);
            final sent = (server.bodies.single['ops'] as List).single as Map;
            expect(sent['idempotencyKey'], 'k_fresh_key');
            final id = (opOf(fixture)['payload'] as Map)['id'];
            expect((sent['payload'] as Map)['id'], id);
            expect(
              ((fixture.responseBody['data'] as Map)['results'] as List)
                  .single['response']['id'],
              id,
              reason: 'the server answers with the row it holds under that id',
            );
            await expectPatchedOnceFor(type);
          },
        );

        test(
          '$type: same id, different compared fields → rejected '
          'CLIENT_ID_REUSED, local rows kept, shown to the owner',
          () async {
            final fixture = loadFixture(file);
            await seedLocalRowsFor(type);
            await enqueueOpsFromFixture(db, fixture);
            final op = opOf(fixture);
            final sync = syncWith(scripted([clientIdReusedFor(op)]).client);

            await sync.push();

            final row = await db.select(db.outboxOps).getSingle();
            expect(row.status, 'rejected');
            expect(row.attempts, 0);
            expect(row.lastCode, 'CLIENT_ID_REUSED');
            expect(jsonDecode(row.lastDetails!), {
              'type': type,
              'id': (op['payload'] as Map)['id'],
            });
            // Nothing is rolled back locally: the owner decides (08 §14).
            switch (type) {
              case 'shift.open':
                expect(await db.select(db.shifts).get(), hasLength(1));
              case 'drawer.entry':
                expect(await db.select(db.drawerEntries).get(), hasLength(1));
              case 'return.create':
                expect(await db.select(db.returns).get(), hasLength(1));
            }
            final needsOwner = await sync.needsOwner.first;
            expect(
              needsOwner.any(
                (o) =>
                    o.opId == op['opId'] &&
                    o.status == OutboxOpStatus.rejected &&
                    o.lastCode == 'CLIENT_ID_REUSED',
              ),
              isTrue,
            );
          },
        );
      }
    });
  });
}
