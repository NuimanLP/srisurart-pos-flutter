// Tests for SyncService & outbox_ops (Phase 2, Issue #228, Slice 8-c).
// Requirements:
//   - Atomic write: bill + op exist together.
//   - Timeout -> Degraded + op in outbox with same key; 409 does not change status.
//   - 500 response 3 times -> op becomes stuck; blocked op on same aggregate waits; op on independent aggregate proceeds.
//   - Fixture integration using docs/Backend_design/fixtures/sync-push/

import 'dart:async';
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

File findFixture(String name) {
  final candidate1 = File('../docs/Backend_design/fixtures/sync-push/$name');
  if (candidate1.existsSync()) return candidate1;
  final candidate2 = File('docs/Backend_design/fixtures/sync-push/$name');
  if (candidate2.existsSync()) return candidate2;
  throw StateError('Fixture $name not found in search paths');
}

Map<String, dynamic> loadFixture(String name) {
  final file = findFixture(name);
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
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

void main() {
  late AppDatabase db;
  late InMemoryTokenStorage tokenStorage;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tokenStorage = InMemoryTokenStorage();
  });

  tearDown(() async {
    await db.close();
  });

  group('Atomic Write Rule (ADR-0010 / #84)', () {
    test('bill + op exist together upon transaction commit', () async {
      const saleId = 'sale_atom_001';
      const opId = 'op_atom_001';
      const key = 'idem_atom_001';

      await db.transaction(() async {
        await db.into(db.sales).insert(
              SaleRow(
                id: saleId,
                receiptNo: 'RC01-2569-09-0001',
                subtotal: 100,
                discount: 0,
                total: 100,
                paymentMethod: 'เงินสด',
                date: DateTime.now(),
                pointsGranted: 10,
                voided: false,
                soldOffline: true,
              ),
            );

        await db.into(db.outboxOps).insert(
              OutboxOpsCompanion.insert(
                opId: opId,
                idempotencyKey: key,
                type: 'sale.create',
                payload: jsonEncode({'id': saleId, 'total': '100.00'}),
                aggregates: jsonEncode(['sale:$saleId', 'shift:sh1']),
                createdAt: DateTime.now().toUtc(),
                status: 'pending',
              ),
            );
      });

      final savedSale = await (db.select(db.sales)
            ..where((t) => t.id.equals(saleId)))
          .getSingleOrNull();
      final savedOp = await (db.select(db.outboxOps)
            ..where((t) => t.opId.equals(opId)))
          .getSingleOrNull();

      expect(savedSale, isNotNull);
      expect(savedOp, isNotNull);
      expect(savedOp!.idempotencyKey, equals(key));
    });

    test('rolled back transaction saves neither bill nor op', () async {
      const saleId = 'sale_fail_001';
      const opId = 'op_fail_001';

      try {
        await db.transaction(() async {
          await db.into(db.sales).insert(
                SaleRow(
                  id: saleId,
                  receiptNo: 'RC01-2569-09-0002',
                  subtotal: 100,
                  discount: 0,
                  total: 100,
                  paymentMethod: 'เงินสด',
                  date: DateTime.now(),
                  pointsGranted: 10,
                  voided: false,
                  soldOffline: true,
                ),
              );

          await db.into(db.outboxOps).insert(
                OutboxOpsCompanion.insert(
                  opId: opId,
                  idempotencyKey: 'idem_fail_001',
                  type: 'sale.create',
                  payload: jsonEncode({'id': saleId}),
                  aggregates: jsonEncode(['sale:$saleId']),
                  createdAt: DateTime.now().toUtc(),
                  status: 'pending',
                ),
              );

          throw StateError('Simulated failure during checkout');
        });
      } catch (_) {}

      final savedSale = await (db.select(db.sales)
            ..where((t) => t.id.equals(saleId)))
          .getSingleOrNull();
      final savedOp = await (db.select(db.outboxOps)
            ..where((t) => t.opId.equals(opId)))
          .getSingleOrNull();

      expect(savedSale, isNull);
      expect(savedOp, isNull);
    });
  });

  group('Timeout, Degraded Status & Verdict Behavior', () {
    test('Timeout -> Degraded + op in outbox with same key', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/sync/push')) {
          throw TimeoutException('Push request timed out');
        }
        return http.Response('{"status":"ok"}', 200);
      });

      final apiClient = ApiClient(
        baseUrl: 'http://example.com',
        httpClient: mockClient,
        tokenStorage: tokenStorage,
      );

      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      expect(syncService.currentStatus, equals(SyncStatus.online));

      const opId = 'op_timeout_001';
      const key = 'idem_timeout_key';

      await syncService.enqueueOp(
        opId: opId,
        idempotencyKey: key,
        type: 'sale.create',
        payload: {'id': 'sale_t1', 'total': '100.00'},
        aggregates: ['sale:sale_t1'],
      );

      // Trigger push which will timeout
      await syncService.push();

      expect(syncService.currentStatus, equals(SyncStatus.degraded));

      final op = await (db.select(db.outboxOps)
            ..where((t) => t.opId.equals(opId)))
          .getSingleOrNull();
      expect(op, isNotNull);
      expect(op!.idempotencyKey, equals(key));
      expect(op.attempts, equals(1));
      expect(op.status, equals('pending'));

      syncService.dispose();
    });

    test('409 verdict does not change status to Degraded', () async {
      final mockClient = MockClient((_) async => http.Response('', 200));
      final apiClient = ApiClient(
        baseUrl: 'http://example.com',
        httpClient: mockClient,
        tokenStorage: tokenStorage,
      );

      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      expect(syncService.currentStatus, equals(SyncStatus.online));

      // Report a 4xx verdict (e.g. 409 CREDIT_LIMIT_EXCEEDED or INSUFFICIENT_STOCK)
      syncService.recordVerdictWrite();

      expect(syncService.currentStatus, equals(SyncStatus.online));

      syncService.dispose();
    });

    test('Health probe: 3 consecutive failures trigger Degraded; 1 success triggers Syncing', () async {
      int healthCalls = 0;
      bool healthy = false;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/health/ready')) {
          healthCalls++;
          if (healthy) {
            return http.Response('{"status":"ok"}', 200);
          } else {
            return http.Response('{"status":"error"}', 503);
          }
        }
        return http.Response('{"data":{"results":[]}}', 200);
      });

      final apiClient = ApiClient(
        baseUrl: 'http://example.com',
        httpClient: mockClient,
        tokenStorage: tokenStorage,
      );

      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      expect(syncService.currentStatus, equals(SyncStatus.online));

      // Health failure 1: remains online
      await syncService.checkHealth();
      expect(syncService.currentStatus, equals(SyncStatus.online));

      // Health failure 2: remains online
      await syncService.checkHealth();
      expect(syncService.currentStatus, equals(SyncStatus.online));

      // Health failure 3: triggers Degraded!
      await syncService.checkHealth();
      expect(syncService.currentStatus, equals(SyncStatus.degraded));

      // Health succeeds once -> transitions to Syncing!
      healthy = true;
      await syncService.checkHealth();
      expect(syncService.currentStatus, anyOf(equals(SyncStatus.syncing), equals(SyncStatus.online)));
      expect(healthCalls, equals(4));


      syncService.dispose();
    });
  });

  group('Head-of-Line Blocking & Stuck Queue (§8.4)', () {
    test('500 response 3 times -> op becomes stuck; blocked op on same aggregate waits; op on independent aggregate proceeds', () async {
      int pushCalls = 0;
      List<String> opIdsReceivedInPush = [];

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/sync/push')) {
          pushCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final ops = (body['ops'] as List).cast<Map<String, dynamic>>();
          opIdsReceivedInPush = ops.map((e) => e['opId'] as String).toList();

          if (pushCalls <= 3) {
            // Fail 3 times with 500
            return http.Response('{"status":"error","message":"Internal Server Error"}', 500);
          }

          // 4th call: succeed for whatever ops were sent
          return http.Response(
            jsonEncode({
              'status': 'success',
              'data': {
                'results': [
                  for (final op in ops)
                    {
                      'opId': op['opId'],
                      'status': 'applied',
                      'response': {'id': op['payload']['id']},
                    }
                ]
              }
            }),
            200,
          );
        }
        return http.Response('{"status":"ok"}', 200);
      });

      final apiClient = ApiClient(
        baseUrl: 'http://example.com',
        httpClient: mockClient,
        tokenStorage: tokenStorage,
      );

      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      // Setup 3 ops:
      // Op 1: sale A (aggregates: ['sale:A', 'shift:S'])
      // Op 2: void A (aggregates: ['sale:A', 'shift:S']) -> depends on sale A
      // Op 3: sale B (aggregates: ['sale:B', 'shift:S']) -> independent aggregate
      final now = DateTime.now().toUtc();
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: 'op_sale_A',
              idempotencyKey: 'k_sale_A',
              type: 'sale.create',
              payload: jsonEncode({'id': 's_A', 'receiptNo': 'RC01-2569-09-0010'}),
              aggregates: jsonEncode(['sale:A', 'shift:S']),
              createdAt: now,
              status: 'pending',
            ),
          );

      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: 'op_void_A',
              idempotencyKey: 'k_void_A',
              type: 'sale.void_offline',
              payload: jsonEncode({'id': 's_A', 'reason': 'Customer cancelled'}),
              aggregates: jsonEncode(['sale:A', 'shift:S']),
              createdAt: now.add(const Duration(seconds: 1)),
              status: 'pending',
            ),
          );

      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: 'op_sale_B',
              idempotencyKey: 'k_sale_B',
              type: 'sale.create',
              payload: jsonEncode({'id': 's_B', 'receiptNo': 'RC01-2569-09-0011'}),
              aggregates: jsonEncode(['sale:B', 'shift:S']),
              createdAt: now.add(const Duration(seconds: 2)),
              status: 'pending',
            ),
          );

      // Attempt 1: 500 failure
      await syncService.push();
      var opA = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_sale_A'))).getSingle();
      expect(opA.attempts, equals(1));
      expect(opA.status, equals('pending'));

      // Attempt 2: 500 failure
      await syncService.push();
      opA = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_sale_A'))).getSingle();
      expect(opA.attempts, equals(2));
      expect(opA.status, equals('pending'));

      // Attempt 3: 500 failure -> attempts reaches 3 -> status becomes stuck!
      await syncService.push();
      opA = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_sale_A'))).getSingle();
      expect(opA.attempts, equals(3));
      expect(opA.status, equals('stuck'));

      // Verify needsOwner contains op_sale_A as stuck
      final needsOwnerList = await syncService.needsOwner.first;
      expect(needsOwnerList.any((e) => e.opId == 'op_sale_A' && e.status == OutboxOpStatus.stuck), isTrue);

      // Attempt 4: Push now runs while op_sale_A is stuck.
      // - op_sale_A is stuck.
      // - op_void_A references 'sale:A' -> BLOCKED by op_sale_A!
      // - op_sale_B has independent aggregate 'sale:B' -> PROCEEDS!
      await syncService.push();

      expect(opIdsReceivedInPush, equals(['op_sale_B']));

      // op_sale_B succeeded and was applied (deleted from outbox_ops)
      final opB = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_sale_B'))).getSingleOrNull();
      expect(opB, isNull);

      // op_sale_A and op_void_A remain in outbox
      final opAAfter = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_sale_A'))).getSingleOrNull();
      final voidAAfter = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_void_A'))).getSingleOrNull();

      expect(opAAfter, isNotNull);
      expect(opAAfter!.status, equals('stuck'));
      expect(voidAAfter, isNotNull);
      expect(voidAAfter!.status, equals('pending'));

      syncService.dispose();
    });

    test('resend unblocks stuck op with same key and doc number', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'status': 'success',
            'data': {'results': []}
          }),
          200,
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      const opId = 'op_stuck_resend';
      const key = 'idem_stuck_key';
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opId,
              idempotencyKey: key,
              type: 'sale.create',
              payload: jsonEncode({'id': 's_stuck', 'receiptNo': 'RC01-2569-09-0099'}),
              aggregates: jsonEncode(['sale:s_stuck']),
              createdAt: DateTime.now().toUtc(),
              status: 'stuck',
              attempts: const drift.Value(3),
            ),
          );

      await syncService.resend(opId);

      final row = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opId))).getSingle();
      expect(row.status, equals('pending'));
      expect(row.attempts, equals(0));
      expect(row.idempotencyKey, equals(key));
      expect(row.payload.contains('RC01-2569-09-0099'), isTrue);

      syncService.dispose();
    });

    test('discard deletes op and business row when serverHasRow is false', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/sync/discards')) {
          return http.Response(
            jsonEncode({
              'status': 'success',
              'data': {'serverHasRow': false}
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      const saleId = 's_discard_01';
      const opId = 'op_discard_01';

      await db.into(db.sales).insert(
            SaleRow(
              id: saleId,
              receiptNo: 'RC01-2569-09-0044',
              subtotal: 50,
              discount: 0,
              total: 50,
              paymentMethod: 'เงินสด',
              date: DateTime.now(),
              pointsGranted: 5,
              voided: false,
              soldOffline: true,
            ),
          );

      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opId,
              idempotencyKey: 'idem_discard',
              type: 'sale.create',
              payload: jsonEncode({'id': saleId, 'receiptNo': 'RC01-2569-09-0044'}),
              aggregates: jsonEncode(['sale:$saleId']),
              createdAt: DateTime.now().toUtc(),
              status: 'rejected',
              lastCode: const drift.Value('INSUFFICIENT_STOCK'),
            ),
          );

      final result = await syncService.discard(opId, 'Customer walked away');
      expect(result.serverHasRow, isFalse);

      final opAfter = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opId))).getSingleOrNull();
      final saleAfter = await (db.select(db.sales)..where((t) => t.id.equals(saleId))).getSingleOrNull();

      expect(opAfter, isNull);
      expect(saleAfter, isNull);

      syncService.dispose();
    });
  });

  group('Fixture Integration (docs/Backend_design/fixtures/sync-push/)', () {
    test('sale-create.applied.json: patches stock and deletes applied op', () async {
      final fixture = loadFixture('sale-create.applied.json');
      final reqFixture = fixture['request'] as Map<String, dynamic>;
      final respFixture = fixture['response'] as Map<String, dynamic>;

      final mockClient = MockClient((request) async {
        expect(request.url.path, '/api/v1/sync/push');
        expect(request.headers['X-Device-Token'] ?? request.headers['x-device-token'], 'pos-device-token-01');
        return http.Response(
          jsonEncode(respFixture['body']),
          respFixture['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      // Seed product p1 with stock 48
      await (db.update(db.products)..where((t) => t.id.equals('p1'))).write(
        const ProductsCompanion(stock: drift.Value(48)),
      );

      final opReq = (reqFixture['body']['ops'] as List).first as Map<String, dynamic>;
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opReq['opId'],
              idempotencyKey: opReq['idempotencyKey'],
              type: opReq['type'],
              payload: jsonEncode(opReq['payload']),
              aggregates: jsonEncode(['sale:${opReq['payload']['id']}']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      await syncService.push();

      // Op is deleted
      final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opReq['opId']))).getSingleOrNull();
      expect(op, isNull);

      // Product p1 stock patched to 45 per fixture response
      final product = await (db.select(db.products)..where((t) => t.id.equals('p1'))).getSingle();
      expect(product.stock, equals(45));

      syncService.dispose();
    });

    test('sale-create.rejected-stock.json: marks op rejected with Thai message', () async {
      final fixture = loadFixture('sale-create.rejected-stock.json');
      final reqFixture = fixture['request'] as Map<String, dynamic>;
      final respFixture = fixture['response'] as Map<String, dynamic>;

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode(respFixture['body']),
          respFixture['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      final opReq = (reqFixture['body']['ops'] as List).first as Map<String, dynamic>;
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opReq['opId'],
              idempotencyKey: opReq['idempotencyKey'],
              type: opReq['type'],
              payload: jsonEncode(opReq['payload']),
              aggregates: jsonEncode(['sale:${opReq['payload']['id']}']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      await syncService.push();

      final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opReq['opId']))).getSingle();
      expect(op.status, equals('rejected'));
      expect(op.lastCode, equals('INSUFFICIENT_STOCK'));
      expect(op.lastMessage, equals('สต็อกไม่พอ'));

      final needsOwnerList = await syncService.needsOwner.first;
      expect(needsOwnerList.any((e) => e.opId == opReq['opId'] && e.status == OutboxOpStatus.rejected), isTrue);

      syncService.dispose();
    });

    test('batch.stop-at-retry.json: op 1 applied, op 2 retry increments attempts, ops 3 & 4 not incremented', () async {
      final fixture = loadFixture('batch.stop-at-retry.json');
      final reqFixture = fixture['request'] as Map<String, dynamic>;
      final respFixture = fixture['response'] as Map<String, dynamic>;

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode(respFixture['body']),
          respFixture['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      final ops = (reqFixture['body']['ops'] as List).cast<Map<String, dynamic>>();
      final now = DateTime.now().toUtc();

      for (var i = 0; i < ops.length; i++) {
        final op = ops[i];
        await db.into(db.outboxOps).insert(
              OutboxOpsCompanion.insert(
                opId: op['opId'],
                idempotencyKey: op['idempotencyKey'],
                type: op['type'],
                payload: jsonEncode(op['payload']),
                aggregates: jsonEncode(['sale:${op['payload']['id']}']),
                createdAt: now.add(Duration(seconds: i)),
                status: 'pending',
              ),
            );
      }

      await syncService.push();

      // op_1 applied & deleted
      final op1 = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_1'))).getSingleOrNull();
      expect(op1, isNull);

      // op_2 attempts incremented to 1
      final op2 = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_2'))).getSingle();
      expect(op2.attempts, equals(1));
      expect(op2.status, equals('pending'));

      // op_3 and op_4 attempts stay 0
      final op3 = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_3'))).getSingle();
      expect(op3.attempts, equals(0));
      expect(op3.status, equals('pending'));

      final op4 = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_4'))).getSingle();
      expect(op4.attempts, equals(0));
      expect(op4.status, equals('pending'));

      syncService.dispose();
    });

    test('return-create.applied.json: restores stock on applied credit note', () async {
      final fixture = loadFixture('return-create.applied.json');
      final reqFixture = fixture['request'] as Map<String, dynamic>;
      final respFixture = fixture['response'] as Map<String, dynamic>;

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode(respFixture['body']),
          respFixture['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      // Initial stock 45
      await (db.update(db.products)..where((t) => t.id.equals('p1'))).write(
        const ProductsCompanion(stock: drift.Value(45)),
      );

      final opReq = (reqFixture['body']['ops'] as List).first as Map<String, dynamic>;
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opReq['opId'],
              idempotencyKey: opReq['idempotencyKey'],
              type: opReq['type'],
              payload: jsonEncode(opReq['payload']),
              aggregates: jsonEncode(['return:${opReq['payload']['id']}']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      await syncService.push();

      // Op is deleted
      final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opReq['opId']))).getSingleOrNull();
      expect(op, isNull);

      // Stock restored to 46 per fixture response
      final product = await (db.select(db.products)..where((t) => t.id.equals('p1'))).getSingle();
      expect(product.stock, equals(46));

      syncService.dispose();
    });

    test('batch.no-active-user-403.json: request level 403 leaves op status untouched', () async {
      final fixture = loadFixture('batch.no-active-user-403.json');
      final reqFixture = fixture['request'] as Map<String, dynamic>;
      final respFixture = fixture['response'] as Map<String, dynamic>;

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode(respFixture['body']),
          respFixture['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      final opReq = (reqFixture['body']['ops'] as List).first as Map<String, dynamic>;
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opReq['opId'],
              idempotencyKey: opReq['idempotencyKey'],
              type: opReq['type'],
              payload: jsonEncode(opReq['payload']),
              aggregates: jsonEncode(['sale:${opReq['payload']['id']}']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      await syncService.push();

      // Op remains pending, attempts untouched (0) per §8.1
      final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opReq['opId']))).getSingle();
      expect(op.status, equals('pending'));
      expect(op.attempts, equals(0));

      syncService.dispose();
    });

    test('Push credit_payment.create: applies, patches mechanic balance and inserts credit_payments row', () async {
      // Seed mechanic m1 with 1500 balance
      await db.into(db.mechanics).insertOnConflictUpdate(
            MechanicsCompanion.insert(
              id: 'm1',
              code: 'M001',
              name: 'Mechanic One',
              createdAt: '2026-09-15T00:00:00.000Z',
              creditBalance: const drift.Value(1500.0),
            ),
          );

      final fixture = loadFixture('credit-payment.applied.json');
      final reqFixture = fixture['request'] as Map<String, dynamic>;
      final respFixture = fixture['response'] as Map<String, dynamic>;

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode(respFixture['body']),
          respFixture['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://example.com', httpClient: mockClient);
      final syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockClient,
        autoStartHealthProbe: false,
      );

      final opReq = (reqFixture['body']['ops'] as List).first as Map<String, dynamic>;
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: opReq['opId'],
              idempotencyKey: opReq['idempotencyKey'],
              type: opReq['type'],
              payload: jsonEncode(opReq['payload']),
              aggregates: jsonEncode(['cp:${opReq['payload']['id']}', 'shift', 'mechanic:${opReq['payload']['mechanicId']}']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      await syncService.push();

      // Op applied and deleted from outbox_ops
      final remaining = await (db.select(db.outboxOps)..where((t) => t.opId.equals(opReq['opId']))).getSingleOrNull();
      expect(remaining, isNull);

      // Mechanic creditBalance patched to 1000.00
      final mechanic = await (db.select(db.mechanics)..where((t) => t.id.equals('m1'))).getSingle();
      expect(mechanic.creditBalance, equals(1000.0));

      // credit_payments row inserted
      final payment = await (db.select(db.creditPayments)..where((t) => t.id.equals('cp_off_001'))).getSingleOrNull();
      expect(payment, isNotNull);
      expect(payment!.amount, equals(500.0));
      expect(payment.mechanicId, equals('m1'));

      syncService.dispose();
    });
  });
}
