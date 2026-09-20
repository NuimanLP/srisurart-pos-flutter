// Tests for Slice 13b (Issue #212) `fe.pull-cursor`.
// Specifications:
//   - 08_PHASE2_SPEC.md §15 (Pull #191, B4)
//   - 09_PHASE2_LANES.md §3 (13b / #212 ส่วน B)
//   - ADR-0010 §D3 (client write-through cache & stock protection)

import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_customers_repository.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late InMemoryTokenStorage tokenStorage;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tokenStorage = InMemoryTokenStorage();
    await db.delete(db.products).go();
    await db.delete(db.customers).go();
    await db.delete(db.mechanics).go();
    await db.delete(db.syncCursors).go();
    await db.delete(db.outboxOps).go();
  });

  tearDown(() async {
    await db.close();
  });

  group('Drift Schema v11 - sync_cursors table', () {
    test('sync_cursors table exists and supports upsert', () async {
      expect(db.schemaVersion, 11);

      // Insert new cursor
      await db.into(db.syncCursors).insert(
            SyncCursorsCompanion.insert(
              entity: 'products',
              cursor: const drift.Value('2026-09-20T10:00:00.000Z'),
              updatedAt: drift.Value(DateTime.now().toUtc()),
            ),
          );

      var row = await (db.select(db.syncCursors)
            ..where((t) => t.entity.equals('products')))
          .getSingle();
      expect(row.cursor, '2026-09-20T10:00:00.000Z');

      // Update on conflict
      await db.into(db.syncCursors).insertOnConflictUpdate(
            SyncCursorsCompanion(
              entity: const drift.Value('products'),
              cursor: const drift.Value('2026-09-20T11:00:00.000Z'),
              updatedAt: drift.Value(DateTime.now().toUtc()),
            ),
          );

      row = await (db.select(db.syncCursors)
            ..where((t) => t.entity.equals('products')))
          .getSingle();
      expect(row.cursor, '2026-09-20T11:00:00.000Z');
    });
  });

  group('ApiProductsRepository - Keyset Pull Sync (#212)', () {
    test('page 1 rewinds 30s from sync_cursors and omits afterId, page 2 walks nextCursor', () async {
      // Seed sync_cursors with a known server timestamp
      await db.into(db.syncCursors).insert(
            SyncCursorsCompanion.insert(
              entity: 'products',
              cursor: const drift.Value('2026-09-20T10:01:00.000Z'),
              updatedAt: drift.Value(DateTime.now().toUtc()),
            ),
          );

      final requestedUrls = <Uri>[];
      final client = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          requestedUrls.add(req.url);

          if (req.url.queryParameters['afterId'] == null) {
            // Page 1
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'p-new-1',
                    'partNo': 'PART-01',
                    'name': 'Part One',
                    'nameTH': 'อะไหล่ 1',
                    'category': 'เครื่องยนต์',
                    'price': 100,
                    'cost': 60,
                    'stock': 20,
                    'updatedAt': '2026-09-20T10:01:10.000Z',
                  }
                ],
                'meta': {
                  'total': 2,
                  'page': 1,
                  'limit': 100,
                  'totalPages': 2,
                  'nextCursor': {
                    'updatedSince': '2026-09-20T10:01:10.000Z',
                    'afterId': 'p-new-1',
                  },
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          } else {
            // Page 2
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'p-new-2',
                    'partNo': 'PART-02',
                    'name': 'Part Two',
                    'nameTH': 'อะไหล่ 2',
                    'category': 'เครื่องยนต์',
                    'price': 150,
                    'cost': 90,
                    'stock': 15,
                    'updatedAt': '2026-09-20T10:02:00.000Z',
                  }
                ],
                'meta': {
                  'total': 2,
                  'page': 2,
                  'limit': 100,
                  'totalPages': 2,
                  'nextCursor': null,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
        }),
      );

      final repo = ApiProductsRepository(db, client);
      await repo.syncFromServer();

      expect(requestedUrls.length, 2);

      // Page 1: 10:01:00 - 30s = 10:00:30.000Z and NO afterId!
      final page1 = requestedUrls[0];
      expect(page1.queryParameters['updatedSince'], '2026-09-20T10:00:30.000Z');
      expect(page1.queryParameters.containsKey('afterId'), isFalse);

      // Page 2: takes nextCursor from page 1
      final page2 = requestedUrls[1];
      expect(page2.queryParameters['updatedSince'], '2026-09-20T10:01:10.000Z');
      expect(page2.queryParameters['afterId'], 'p-new-1');

      // Check that sync_cursors has the latest cursor from server
      final savedCursor = await (db.select(db.syncCursors)
            ..where((t) => t.entity.equals('products')))
          .getSingle();
      expect(savedCursor.cursor, '2026-09-20T10:01:10.000Z');

      // Check rows inserted in Drift
      final rows = await repo.getAll();
      expect(rows.any((r) => r.id == 'p-new-1'), isTrue);
      expect(rows.any((r) => r.id == 'p-new-2'), isTrue);
    });

    test('stock protection: product with pending op in outbox_ops retains local stock on pull', () async {
      // Seed product p1 in local database with stock = 10
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'p1',
              partNo: 'HN-01',
              name: 'Oil Filter',
              nameTH: 'กรองน้ำมัน',
              category: 'เครื่องยนต์',
              brand: 'Honda',
              price: 85,
              cost: 45,
              stock: 10, // Local modified stock
              minStock: 5,
            ),
          );

      // Seed product p2 with stock = 5 (NO pending op)
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'p2',
              partNo: 'HN-02',
              name: 'Air Filter',
              nameTH: 'กรองอากาศ',
              category: 'เครื่องยนต์',
              brand: 'Honda',
              price: 120,
              cost: 70,
              stock: 5,
              minStock: 5,
            ),
          );

      // Add a pending outbox op referencing p1 in aggregates
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: 'op-sale-1',
              idempotencyKey: 'idem-1',
              type: 'sale.create',
              payload: jsonEncode({
                'items': [
                  {'productId': 'p1', 'qty': 2}
                ]
              }),
              aggregates: jsonEncode(['sale:s1', 'product:p1']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      final client = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'p1',
                  'partNo': 'HN-01',
                  'name': 'Oil Filter Updated Name',
                  'nameTH': 'กรองน้ำมันชื่อใหม่',
                  'category': 'เครื่องยนต์',
                  'price': 95,
                  'cost': 45,
                  'stock': 50, // Server has 50!
                  'updatedAt': '2026-09-20T10:00:00.000Z',
                },
                {
                  'id': 'p2',
                  'partNo': 'HN-02',
                  'name': 'Air Filter',
                  'nameTH': 'กรองอากาศ',
                  'category': 'เครื่องยนต์',
                  'price': 120,
                  'cost': 70,
                  'stock': 25, // Server has 25!
                  'updatedAt': '2026-09-20T10:00:00.000Z',
                }
              ],
              'meta': {
                'total': 2,
                'page': 1,
                'limit': 100,
                'totalPages': 1,
                'nextCursor': null,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final repo = ApiProductsRepository(db, client);
      await repo.syncFromServer();

      // Product p1 has pending op -> local stock remains 10, but price and name are updated
      final p1 = await repo.getById('p1');
      expect(p1, isNotNull);
      expect(p1!.stock, 10); // NOT overwritten!
      expect(p1.price, 95); // Other fields updated!
      expect(p1.name, 'Oil Filter Updated Name');

      // Product p2 has no pending op -> stock is updated to 25
      final p2 = await repo.getById('p2');
      expect(p2, isNotNull);
      expect(p2!.stock, 25); // Overwritten by server stock
    });

    test('tombstone exclusion: deleted rows and import-tombstone products are hidden from getAll()', () async {
      await db.batch((b) {
        b.insertAll(db.products, [
          ProductsCompanion.insert(
            id: 'p-normal',
            partNo: 'P-01',
            name: 'Normal Product',
            nameTH: 'สินค้าปกติ',
            category: 'เครื่องยนต์',
            brand: 'OEM',
            price: 100,
            cost: 50,
            stock: 10,
            minStock: 5,
          ),
          ProductsCompanion.insert(
            id: 'p-deleted',
            partNo: 'P-02',
            name: 'Deleted Product',
            nameTH: 'สินค้าลบแล้ว',
            category: 'เครื่องยนต์',
            brand: 'OEM',
            price: 100,
            cost: 50,
            stock: 0,
            minStock: 0,
            deletedAt: drift.Value(DateTime.now()),
          ),
          ProductsCompanion.insert(
            id: 'p-import-tombstone',
            partNo: 'P-03',
            name: 'Import Tombstone',
            nameTH: 'ซากสินค้านำเข้า',
            category: 'เครื่องยนต์',
            brand: 'import-tombstone',
            price: 0,
            cost: 0,
            stock: 0,
            minStock: 0,
          ),
        ]);
      });

      final client = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'data': [],
                'meta': {'total': 0, 'page': 1, 'limit': 100, 'totalPages': 1},
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final repo = ApiProductsRepository(db, client);
      final products = await repo.getAll();

      expect(products.length, 1);
      expect(products.first.id, 'p-normal');
      expect(await repo.getById('p-deleted'), isNull);
      expect(await repo.getById('p-import-tombstone'), isNull);
    });
  });

  group('ApiCustomersRepository - Keyset Pull Sync (#212)', () {
    test('syncFromServer records server nextCursor and filters import-tombstone customers', () async {
      final client = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          if (req.url.queryParameters['afterId'] != null) {
            return http.Response(
              jsonEncode({
                'data': [],
                'meta': {
                  'total': 2,
                  'page': 2,
                  'limit': 100,
                  'totalPages': 2,
                  'nextCursor': null,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'c-live',
                  'code': 'CUS001',
                  'name': 'Active Customer',
                  'nameTH': 'ลูกค้าใช้งาน',
                  'phone': '0812345678',
                  'points': 50,
                  'totalSpend': 500,
                  'updatedAt': '2026-09-20T10:05:00.000Z',
                },
                {
                  'id': 'c-tombstone',
                  'code': 'import-tombstone:c-tombstone',
                  'name': 'Legacy Customer',
                  'nameTH': 'ลูกค้าในอดีต',
                  'points': 0,
                  'totalSpend': 0,
                  'updatedAt': '2026-09-20T10:05:00.000Z',
                }
              ],
              'meta': {
                'total': 2,
                'page': 1,
                'limit': 100,
                'totalPages': 2,
                'nextCursor': {
                  'updatedSince': '2026-09-20T10:05:00.000Z',
                  'afterId': 'c-tombstone',
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final repo = ApiCustomersRepository(db, client);
      await repo.syncFromServer();

      // Verify server cursor is saved in sync_cursors
      final savedCursor = await (db.select(db.syncCursors)
            ..where((t) => t.entity.equals('customers')))
          .getSingle();
      expect(savedCursor.cursor, '2026-09-20T10:05:00.000Z');

      // Verify getCustomers excludes import-tombstone
      final customers = await repo.getCustomers();
      expect(customers.length, 1);
      expect(customers.first.id, 'c-live');
    });
  });

  group('ApiMechanicsRepository - Keyset Pull Sync (#212)', () {
    test('syncFromServer records server nextCursor and filters import-tombstone mechanics', () async {
      final client = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          if (req.url.queryParameters['afterId'] != null) {
            return http.Response(
              jsonEncode({
                'data': [],
                'meta': {
                  'total': 2,
                  'page': 2,
                  'limit': 100,
                  'totalPages': 2,
                  'nextCursor': null,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'm-live',
                  'code': 'MEC001',
                  'name': 'Active Mechanic',
                  'nameTH': 'ช่างใช้งาน',
                  'creditLimit': 5000,
                  'creditBalance': 1000,
                  'totalSales': 20000,
                  'totalDiscount': 500,
                  'updatedAt': '2026-09-20T10:08:00.000Z',
                },
                {
                  'id': 'm-tombstone',
                  'code': 'import-tombstone:m-tombstone',
                  'name': 'Legacy Mechanic',
                  'nameTH': 'ช่างในอดีต',
                  'creditLimit': 0,
                  'creditBalance': 0,
                  'totalSales': 0,
                  'totalDiscount': 0,
                  'updatedAt': '2026-09-20T10:08:00.000Z',
                }
              ],
              'meta': {
                'total': 2,
                'page': 1,
                'limit': 100,
                'totalPages': 2,
                'nextCursor': {
                  'updatedSince': '2026-09-20T10:08:00.000Z',
                  'afterId': 'm-tombstone',
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final repo = ApiMechanicsRepository(db, client);
      await repo.syncFromServer();

      // Verify server cursor is saved in sync_cursors
      final savedCursor = await (db.select(db.syncCursors)
            ..where((t) => t.entity.equals('mechanics')))
          .getSingle();
      expect(savedCursor.cursor, '2026-09-20T10:08:00.000Z');

      // Verify getMechanics excludes import-tombstone
      final mechanics = await repo.getMechanics();
      expect(mechanics.length, 1);
      expect(mechanics.first.id, 'm-live');
    });
  });

  group('SyncService - Push then Pull Order (08 §15)', () {
    test('pull() is called after push() completes in online status', () async {
      bool pullInvoked = false;

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/api/v1/sync/push')) {
          return http.Response(
            jsonEncode({
              'data': {
                'results': [
                  {
                    'opId': 'op-1',
                    'status': 'applied',
                  }
                ]
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final apiClient = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: mockHttp,
      );

      // Seed an outbox op to push
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion.insert(
              opId: 'op-1',
              idempotencyKey: 'idem-1',
              type: 'sale.create',
              payload: jsonEncode({'id': 's1'}),
              aggregates: jsonEncode(['sale:s1']),
              createdAt: DateTime.now().toUtc(),
              status: 'pending',
            ),
          );

      final sync = SyncService(
        db: db,
        apiClient: apiClient,
        tokenStorage: tokenStorage,
        httpClient: mockHttp,
        autoStartHealthProbe: false,
        onPull: () async {
          pullInvoked = true;
        },
      );

      await sync.push();
      // Wait for any microtasks
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(pullInvoked, isTrue);
    });
  });
}
