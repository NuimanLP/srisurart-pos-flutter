// Unit tests for ApiCustomersRepository (Ticket #55 / ADR-0010).

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_customers_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

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

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('getCustomers fetches from server, writes through to Drift, and excludes deleted', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') {
        return http.Response(
          '''{
            "status": "success",
            "data": [
              {
                "id": "c_1",
                "code": "CUS001",
                "name": "Somchai",
                "nameTH": "สมชาย",
                "phone": "0812345678",
                "points": 50,
                "totalSpend": "1500.00",
                "createdAt": "2026-09-12T10:00:00.000Z",
                "deletedAt": null
              },
              {
                "id": "c_del",
                "code": "CUS002",
                "name": "Deleted",
                "nameTH": "ลบแล้ว",
                "points": 0,
                "totalSpend": "0.00",
                "createdAt": "2026-09-12T10:00:00.000Z",
                "deletedAt": "2026-09-12T11:00:00.000Z"
              }
            ]
          }''',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiCustomersRepository(db, apiClient);

    final customers = await repo.getCustomers();

    expect(customers.any((c) => c.id == 'c_del'), isFalse);
    final active = customers.firstWhere((c) => c.id == 'c_1');
    expect(active.nameTH, 'สมชาย');
    expect(active.code, 'CUS001');
    expect(active.points, 50);

    // Verify written through to Drift
    final inDrift = await (db.select(db.customers)..where((t) => t.id.equals('c_1'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.code, 'CUS001');
  });

  test('addCustomer posts to server, receives server code, and updates Drift', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/customers' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "c_new_server",
              "code": "CUS089",
              "name": "Somsak",
              "nameTH": "สมศักดิ์",
              "phone": "0899999999",
              "points": 0,
              "totalSpend": "0.00",
              "createdAt": "2026-09-12T12:00:00.000Z",
              "deletedAt": null
            }
          }''',
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiCustomersRepository(db, apiClient);

    final customer = await repo.addCustomer(
      CustomersCompanion.insert(
        id: 'temp_id',
        code: 'TEMP',
        name: 'Somsak',
        nameTH: 'สมศักดิ์',
        createdAt: '2026-09-12T10:00:00.000Z',
        phone: const Value('0899999999'),
      ),
    );

    expect(customer.id, 'c_new_server');
    expect(customer.code, 'CUS089');
    expect(customer.nameTH, 'สมศักดิ์');

    // Verify in Drift
    final inDrift = await (db.select(db.customers)..where((t) => t.id.equals('c_new_server'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.code, 'CUS089');
  });

  test('getCustomers falls back transparently to Drift when network fails', () async {
    // Seed Drift locally
    await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: 'c_offline',
            code: 'CUS005',
            name: 'Offline Customer',
            nameTH: 'ลูกค้าออฟไลน์',
            createdAt: '2026-09-12T10:00:00.000Z',
          ),
        );

    final errorClient = MockClient((request) async {
      throw http.ClientException('Network down');
    });

    final apiClient = ApiClient(httpClient: errorClient);
    final repo = ApiCustomersRepository(db, apiClient);

    final customers = await repo.getCustomers();
    expect(customers.any((c) => c.name == 'Offline Customer'), isTrue);
  });

  test('#183: a timed-out write does NOT fall back to a local row', () async {
    // The server receives the POST and commits after the client has given up;
    // a Drift fallback here would be a second customer for one person.
    var serverCommitted = 0;
    final slowServer = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      serverCommitted++;
      return http.Response('{"status":"success","data":{}}', 201);
    });
    final repo = ApiCustomersRepository(
      db,
      ApiClient(httpClient: slowServer, writeTimeout: const Duration(milliseconds: 200)),
    );
    final before = (await db.select(db.customers).get()).length;

    await expectLater(
      repo.addCustomer(CustomersCompanion.insert(
        id: 'c_timeout',
        code: 'CUS777',
        name: 'Timed Out',
        nameTH: 'หมดเวลา',
        createdAt: '2026-09-15T10:00:00.000Z',
      )),
      throwsA(isA<ApiTimeoutException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(serverCommitted, 1);
    expect((await db.select(db.customers).get()).length, before, reason: 'no local re-run');
  });

  test('deleteCustomer soft-deletes in Drift by setting deletedAt', () async {
    await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: 'c_to_delete',
            code: 'CUS009',
            name: 'To Delete',
            nameTH: 'ลบ',
            createdAt: '2026-09-12T10:00:00.000Z',
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/c_to_delete' && request.method == 'DELETE') {
        return http.Response('{"status":"success","data":{"success":true}}', 200);
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiCustomersRepository(db, apiClient);

    await repo.deleteCustomer('c_to_delete');

    // Should be filtered out by getCustomers
    final list = await repo.getCustomers();
    expect(list.any((c) => c.id == 'c_to_delete'), isFalse);

    // Row in DB still exists with deletedAt populated
    final row = await (db.select(db.customers)..where((t) => t.id.equals('c_to_delete'))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('addCustomer in degraded mode writes to Drift and enqueues customer.create outbox op (Ticket #229)', () async {
    final mockClient = MockClient((request) async {
      return http.Response('{"status":"error"}', 500);
    });
    final apiClient = ApiClient(httpClient: mockClient);
    final syncService = SyncService(
      db: db,
      apiClient: apiClient,
      tokenStorage: InMemoryTokenStorage(),
      autoStartHealthProbe: false,
    );
    syncService.recordNonVerdictWrite();
    expect(syncService.currentStatus, SyncStatus.degraded);

    final repo = ApiCustomersRepository(
      db,
      apiClient,
      syncService: syncService,
    );

    final customer = await repo.addCustomer(
      CustomersCompanion.insert(
        id: 'c_offline_1',
        code: 'CUS_OFF',
        name: 'Offline Man',
        nameTH: 'นายออฟไลน์',
        createdAt: '2026-09-19T10:00:00.000Z',
        phone: const Value('0811112222'),
        address: const Value('123 BKK'),
      ),
    );

    expect(customer.id, 'c_offline_1');
    expect(customer.nameTH, 'นายออฟไลน์');

    // Verify row in Drift
    final inDrift = await (db.select(db.customers)..where((t) => t.id.equals('c_offline_1'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.nameTH, 'นายออฟไลน์');
    expect(inDrift.phone, '0811112222');

    // Verify op in outboxOps
    final ops = await (db.select(db.outboxOps)..where((t) => t.type.equals('customer.create'))).get();
    expect(ops.length, 1);
    expect(ops.first.status, 'pending');
    final payload = jsonDecode(ops.first.payload) as Map<String, dynamic>;
    expect(payload['id'], 'c_offline_1');
    expect(payload['nameTH'], 'นายออฟไลน์');
    expect(payload['phone'], '0811112222');
    expect(payload['address'], '123 BKK');
  });

  test('updateCustomer in degraded mode updates Drift and enqueues customer.update outbox op (Ticket #229)', () async {
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'c_to_update',
        code: 'CUS_INIT',
        name: 'Initial Name',
        nameTH: 'ชื่อเดิม',
        createdAt: '2026-09-19T10:00:00.000Z',
        phone: const Value('0811111111'),
      ),
    );

    final mockClient = MockClient((request) async {
      return http.Response('{"status":"error"}', 500);
    });
    final apiClient = ApiClient(httpClient: mockClient);
    final syncService = SyncService(
      db: db,
      apiClient: apiClient,
      tokenStorage: InMemoryTokenStorage(),
      autoStartHealthProbe: false,
    );
    syncService.recordNonVerdictWrite();

    final repo = ApiCustomersRepository(
      db,
      apiClient,
      syncService: syncService,
    );

    await repo.updateCustomer(
      'c_to_update',
      const CustomersCompanion(
        nameTH: Value('ชื่อใหม่'),
        phone: Value('0899998888'),
      ),
    );

    // Verify Drift row updated
    final updated = await (db.select(db.customers)..where((t) => t.id.equals('c_to_update'))).getSingle();
    expect(updated.nameTH, 'ชื่อใหม่');
    expect(updated.phone, '0899998888');

    // Verify op in outboxOps
    final ops = await (db.select(db.outboxOps)..where((t) => t.type.equals('customer.update'))).get();
    expect(ops.length, 1);
    expect(ops.first.status, 'pending');
    final payload = jsonDecode(ops.first.payload) as Map<String, dynamic>;
    expect(payload['id'], 'c_to_update');
    expect(payload['nameTH'], 'ชื่อใหม่');
    expect(payload['phone'], '0899998888');
  });

  test(
    'addCustomer: an unreadable/unknown-fate error is NOT queued offline (#413) — only a transport failure may fall back',
    () async {
      // Not an ApiException (no verdict), not a transport failure either — the
      // server's fate is unknown, so queuing would risk a second customer.
      final repo = ApiCustomersRepository(
        db,
        ApiClient(httpClient: MockClient((_) async => throw Exception('unexpected'))),
      );

      await expectLater(
        repo.addCustomer(
          CustomersCompanion.insert(
            id: 'c_unknown_fate',
            code: 'CUS_X',
            name: 'Unknown Fate',
            nameTH: 'ไม่ทราบผล',
            createdAt: '2026-09-25T10:00:00.000Z',
          ),
        ),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
      );

      final row = await (db.select(db.customers)..where((t) => t.id.equals('c_unknown_fate'))).getSingleOrNull();
      expect(row, isNull, reason: 'unknown-fate errors must not create a local row');
      expect(await db.select(db.outboxOps).get(), isEmpty);
    },
  );

  test(
    'updateCustomer: an unreadable/unknown-fate error is NOT queued offline (#413) — only a transport failure may fall back',
    () async {
      await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'c_unknown_fate_2',
          code: 'CUS_Y',
          name: 'Before',
          nameTH: 'ก่อน',
          createdAt: '2026-09-25T10:00:00.000Z',
        ),
      );
      final repo = ApiCustomersRepository(
        db,
        ApiClient(httpClient: MockClient((_) async => throw Exception('unexpected'))),
      );

      await expectLater(
        repo.updateCustomer(
          'c_unknown_fate_2',
          const CustomersCompanion(nameTH: Value('หลัง')),
        ),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
      );

      final row = await (db.select(db.customers)..where((t) => t.id.equals('c_unknown_fate_2'))).getSingle();
      expect(row.nameTH, 'ก่อน', reason: 'unknown-fate errors must not patch the local row');
      expect(await db.select(db.outboxOps).get(), isEmpty);
    },
  );

  test(
    'addCustomer: TokenStoreUnavailableException surfaces as-is (#token-store-unavailable) — '
    'not UNREADABLE_RESPONSE, not queued offline',
    () async {
      // The web token store (IndexedDB) being unreachable on the 401→refresh
      // path is neither a transport failure nor "the server answered and
      // probably committed" — the 401 that triggered the refresh already
      // refused this write.
      final repo = ApiCustomersRepository(
        db,
        ApiClient(httpClient: MockClient((_) async => throw const TokenStoreUnavailableException())),
      );

      Object? thrown;
      try {
        await repo.addCustomer(
          CustomersCompanion.insert(
            id: 'c_store_unavailable',
            code: 'CUS_Z',
            name: 'Store Unavailable',
            nameTH: 'เปิดที่เก็บข้อมูลไม่ได้',
            createdAt: '2026-09-25T10:00:00.000Z',
          ),
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<TokenStoreUnavailableException>());
      expect(thrown, isNot(isA<PosException>()));
      expect(thrown.toString(), TokenStoreUnavailableException.message);

      final row = await (db.select(db.customers)..where((t) => t.id.equals('c_store_unavailable'))).getSingleOrNull();
      expect(row, isNull, reason: 'a refused write must not create a local row');
      expect(await db.select(db.outboxOps).get(), isEmpty);
    },
  );

  test(
    'updateCustomer: TokenStoreUnavailableException surfaces as-is (#token-store-unavailable) — '
    'not UNREADABLE_RESPONSE, not queued offline',
    () async {
      await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'c_store_unavailable_2',
          code: 'CUS_W',
          name: 'Before',
          nameTH: 'ก่อน',
          createdAt: '2026-09-25T10:00:00.000Z',
        ),
      );
      final repo = ApiCustomersRepository(
        db,
        ApiClient(httpClient: MockClient((_) async => throw const TokenStoreUnavailableException())),
      );

      Object? thrown;
      try {
        await repo.updateCustomer(
          'c_store_unavailable_2',
          const CustomersCompanion(nameTH: Value('หลัง')),
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<TokenStoreUnavailableException>());
      expect(thrown, isNot(isA<PosException>()));

      final row = await (db.select(db.customers)..where((t) => t.id.equals('c_store_unavailable_2'))).getSingle();
      expect(row.nameTH, 'ก่อน', reason: 'a refused write must not patch the local row');
      expect(await db.select(db.outboxOps).get(), isEmpty);
    },
  );

  // A 2xx whose body is not a customer: the server answered and may have
  // committed, so the write's fate is unknown. It must surface as the Thai
  // UNREADABLE_RESPONSE — not succeed silently (updateCustomer used to fall
  // through) and not be queued offline (addCustomer's synthesized 500 used to
  // land in its own non-verdict branch).
  group('a 2xx whose body is not a customer', () {
    late ApiClient apiClient;
    late SyncService syncService;

    setUp(() {
      apiClient = ApiClient(
        httpClient: MockClient((_) async => http.Response(
              '{"status":"success","data":["not-a-customer"]}',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      );
      syncService = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: InMemoryTokenStorage(),
        autoStartHealthProbe: false,
      );
    });

    test('updateCustomer throws UNREADABLE_RESPONSE, leaves the row alone, queues nothing', () async {
      await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: 'c_nonmap_upd',
          code: 'CUS_U',
          name: 'Before',
          nameTH: 'ก่อน',
          createdAt: '2026-09-25T10:00:00.000Z',
        ),
      );
      final repo = ApiCustomersRepository(db, apiClient, syncService: syncService);

      await expectLater(
        repo.updateCustomer('c_nonmap_upd', const CustomersCompanion(nameTH: Value('หลัง'))),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
      );

      final row = await (db.select(db.customers)..where((t) => t.id.equals('c_nonmap_upd'))).getSingle();
      expect(row.nameTH, 'ก่อน');
      expect(await db.select(db.outboxOps).get(), isEmpty);
    });

    test('addCustomer throws UNREADABLE_RESPONSE, writes no row, queues nothing', () async {
      final repo = ApiCustomersRepository(db, apiClient, syncService: syncService);

      await expectLater(
        repo.addCustomer(
          CustomersCompanion.insert(
            id: 'c_nonmap_add',
            code: 'CUS_A',
            name: 'Nobody',
            nameTH: 'ไม่มี',
            createdAt: '2026-09-25T10:00:00.000Z',
          ),
        ),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
      );

      final row = await (db.select(db.customers)..where((t) => t.id.equals('c_nonmap_add'))).getSingleOrNull();
      expect(row, isNull);
      expect(await db.select(db.outboxOps).get(), isEmpty);
    });
  });

  test('deleteCustomer in degraded mode throws PosException and does not delete locally (08 §6.2)', () async {
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'c_offline_delete',
        code: 'CUS_NODEL',
        name: 'Cannot Delete Offline',
        nameTH: 'ห้ามลบออฟไลน์',
        createdAt: '2026-09-19T10:00:00.000Z',
      ),
    );

    final mockClient = MockClient((request) async {
      return http.Response('{"status":"error"}', 500);
    });
    final apiClient = ApiClient(httpClient: mockClient);
    final syncService = SyncService(
      db: db,
      apiClient: apiClient,
      tokenStorage: InMemoryTokenStorage(),
      autoStartHealthProbe: false,
    );
    syncService.recordNonVerdictWrite();

    final repo = ApiCustomersRepository(
      db,
      apiClient,
      syncService: syncService,
    );

    await expectLater(
      repo.deleteCustomer('c_offline_delete'),
      throwsA(isA<PosException>()),
    );

    // Verify Drift row is NOT deleted or soft-deleted
    final row = await (db.select(db.customers)..where((t) => t.id.equals('c_offline_delete'))).getSingleOrNull();
    expect(row, isNotNull);
    expect(row!.deletedAt, isNull);

    // Verify NO delete op in outboxOps
    final ops = await db.select(db.outboxOps).get();
    expect(ops, isEmpty);
  });

  test('SyncService._patchAppliedEntity patches customer row on server confirmation (Ticket #229)', () async {
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'c_patch_target',
        code: 'TEMP',
        name: 'Offline Created',
        nameTH: 'สร้างตอนออฟไลน์',
        createdAt: '2026-09-19T10:00:00.000Z',
      ),
    );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/sync/push' && request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'status': 'success',
            'data': {
              'results': [
                {
                  'opId': 'op_cust_1',
                  'status': 'applied',
                  'response': {
                    'id': 'c_patch_target',
                    'code': 'CUS099',
                    'name': 'Server Confirmed',
                    'nameTH': 'ยืนยันแล้ว',
                    'phone': '0812345678',
                    'points': 120,
                    'totalSpend': 3450.50,
                  },
                }
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final syncService = SyncService(
      db: db,
      apiClient: apiClient,
      tokenStorage: InMemoryTokenStorage(),
      httpClient: mockClient,
      autoStartHealthProbe: false,
    );

    await syncService.enqueueOp(
      opId: 'op_cust_1',
      idempotencyKey: 'key_cust_1',
      type: 'customer.create',
      payload: {'id': 'c_patch_target', 'name': 'Offline Created'},
      aggregates: ['customer:c_patch_target'],
    );

    await syncService.push();

    // Verify customer row in Drift was patched with server data
    final patched = await (db.select(db.customers)..where((t) => t.id.equals('c_patch_target'))).getSingle();
    expect(patched.code, 'CUS099');
    expect(patched.name, 'Server Confirmed');
    expect(patched.nameTH, 'ยืนยันแล้ว');
    expect(patched.points, 120);
    expect(patched.totalSpend, 3450.50);

    // Verify op was deleted from outbox after applied
    final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_cust_1'))).getSingleOrNull();
    expect(op, isNull);
  });

  test('SyncService._patchAppliedEntity patches customer row on customer.update response (Ticket #229)', () async {
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'c_update_target',
        code: 'CUS_ORIG',
        name: 'Original Name',
        nameTH: 'ชื่อเดิม',
        phone: const Value('0810000000'),
        createdAt: '2026-09-19T10:00:00.000Z',
      ),
    );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/sync/push' && request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'status': 'success',
            'data': {
              'results': [
                {
                  'opId': 'op_cust_update_1',
                  'status': 'applied',
                  'response': {
                    'id': 'c_update_target',
                    'phone': '0899999999',
                  },
                }
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final syncService = SyncService(
      db: db,
      apiClient: apiClient,
      tokenStorage: InMemoryTokenStorage(),
      httpClient: mockClient,
      autoStartHealthProbe: false,
    );

    await syncService.enqueueOp(
      opId: 'op_cust_update_1',
      idempotencyKey: 'key_cust_update_1',
      type: 'customer.update',
      payload: {'id': 'c_update_target', 'phone': '0899999999'},
      aggregates: ['customer:c_update_target'],
    );

    await syncService.push();

    // Verify phone was updated while code and name were preserved
    final patched = await (db.select(db.customers)..where((t) => t.id.equals('c_update_target'))).getSingle();
    expect(patched.code, 'CUS_ORIG');
    expect(patched.name, 'Original Name');
    expect(patched.nameTH, 'ชื่อเดิม');
    expect(patched.phone, '0899999999');

    // Verify op was removed from outbox
    final op = await (db.select(db.outboxOps)..where((t) => t.opId.equals('op_cust_update_1'))).getSingleOrNull();
    expect(op, isNull);
  });
}
