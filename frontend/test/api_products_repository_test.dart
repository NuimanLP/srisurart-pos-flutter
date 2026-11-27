// Unit tests for ApiProductsRepository (Ticket #55 / ADR-0010).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/errors/pos_exception.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('getAll fetches from server, writes through to Drift, and returns un-deleted products', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path.endsWith('/api/v1/products')) {
        return http.Response(
          '''{
            "status": "success",
            "data": [
              {
                "id": "p_remote_1",
                "partNo": "REM-001",
                "name": "Brake Rotor",
                "nameTH": "จานเบรก",
                "category": "เบรก",
                "brand": "Brembo",
                "price": "1200.00",
                "cost": "800.00",
                "stock": 10,
                "minStock": 2,
                "updatedAt": "2026-09-12T10:00:00.000Z",
                "deletedAt": null
              },
              {
                "id": "p_remote_deleted",
                "partNo": "DEL-001",
                "name": "Old Pad",
                "nameTH": "ผ้าเบรกเก่า",
                "category": "เบรก",
                "brand": "TRW",
                "price": "500.00",
                "cost": "300.00",
                "stock": 0,
                "minStock": 0,
                "updatedAt": "2026-09-12T10:00:00.000Z",
                "deletedAt": "2026-09-12T10:05:00.000Z"
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
    final repo = ApiProductsRepository(db, apiClient);

    final products = await repo.getAll();

    // Verify deleted product is excluded
    expect(products.any((p) => p.id == 'p_remote_deleted'), isFalse);

    // Verify active product is returned
    final active = products.firstWhere((p) => p.id == 'p_remote_1');
    expect(active.partNo, 'REM-001');
    expect(active.price, 1200.0);

    // Verify it was written through to Drift DB
    final inDrift = await (db.select(db.products)..where((t) => t.id.equals('p_remote_1'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.nameTH, 'จานเบรก');
  });

  test('getAll uses ?updatedSince= cursor from sync_cursors with 30s rewind (#212, 08 §15)', () async {
    String? requestedUpdatedSince;

    // Seed sync_cursors with known cursor
    final knownDate = DateTime.utc(2026, 9, 10, 8, 30);
    await db.into(db.syncCursors).insert(
          SyncCursorsCompanion.insert(
            entity: 'products',
            cursor: Value(knownDate.toIso8601String()),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );

    final mockClient = MockClient((request) async {
      requestedUpdatedSince = request.url.queryParameters['updatedSince'];
      return http.Response(
        '{"status":"success","data":[]}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiProductsRepository(db, apiClient);

    await repo.getAll();

    final expectedRewound = knownDate.subtract(const Duration(seconds: 30)).toIso8601String();
    expect(requestedUpdatedSince, equals(expectedRewound));
  });

  test('getAll falls back gracefully to Drift cache when network call fails', () async {
    // Seed product in Drift
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'p_cached',
            partNo: 'CACHE-001',
            name: 'Cached Item',
            nameTH: 'สินค้าในแคช',
            category: 'ไฟฟ้า',
            brand: 'Denso',
            price: 250,
            cost: 150,
            stock: 8,
            minStock: 2,
          ),
        );

    // Failing network client
    final mockClient = MockClient((request) async {
      throw http.ClientException('Network unreachable');
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiProductsRepository(db, apiClient);

    final products = await repo.getAll();

    // Still returns cached product from Drift without throwing
    expect(products.any((p) => p.id == 'p_cached'), isTrue);
    final item = products.firstWhere((p) => p.id == 'p_cached');
    expect(item.nameTH, 'สินค้าในแคช');
  });

  // iPad stock entry: a new product whose reply was lost (5xx) is pressed
  // again under the SAME Idempotency-Key, so the server replays the first
  // create instead of answering 409 DUPLICATE_PART_NO ("already exists") for
  // a product the owner never saw saved. A 4xx verdict closes the attempt.
  test('add: a retry after a 5xx reuses the Idempotency-Key; a 4xx closes it', () async {
    final keys = <String?>[];
    final replies = <http.Response>[
      http.Response('{"status":"error","error":{"code":"INTERNAL","message":"x"}}', 500),
      http.Response(
        '{"status":"success","data":{"id":"p_new","partNo":"NEW-1","name":"Pad",'
        '"price":"120.00","cost":"80.00","stock":4}}',
        201,
        headers: {'content-type': 'application/json'},
      ),
      http.Response(
        '{"status":"error","error":{"code":"DUPLICATE_PART_NO","message":"dup"}}',
        409,
        headers: {'content-type': 'application/json'},
      ),
      http.Response(
        '{"status":"error","error":{"code":"DUPLICATE_PART_NO","message":"dup"}}',
        409,
        headers: {'content-type': 'application/json'},
      ),
    ];
    final mockClient = MockClient((request) async {
      keys.add(request.headers['Idempotency-Key'] ?? request.headers['idempotency-key']);
      return replies.removeAt(0);
    });
    final repo = ApiProductsRepository(db, ApiClient(httpClient: mockClient));
    const input = ProductsCompanion(
      partNo: Value('NEW-1'),
      name: Value('Pad'),
      price: Value(120.0),
      cost: Value(80.0),
      stock: Value(4),
    );

    await expectLater(repo.add(input), throwsA(anything));
    final added = await repo.add(input);
    expect(added?.id, 'p_new');
    expect(keys, hasLength(2));
    expect(keys[1], keys[0], reason: 'the retry replays the first attempt');

    // Saved: the same form pressed again is a NEW action (new key).
    await expectLater(repo.add(input), throwsA(anything));
    expect(keys[2], isNot(keys[0]));
    // A 4xx is a verdict: the next press is a new action too.
    await expectLater(repo.add(input), throwsA(anything));
    expect(keys[3], isNot(keys[2]));
  });

  // The first create committed but its reply was lost (502); the owner then
  // EDITS the form and presses again. A changed body is a new key, so the
  // server answers 409 DUPLICATE_PART_NO — that must not read as "someone
  // else's part": the product is pulled into Drift and the screen gets the
  // "may already be saved" sentence. A 409 with no lost attempt before it
  // stays the plain duplicate.
  test('add: an edited retry after a lost reply that gets 409 DUPLICATE_PART_NO pulls the product and says it may be saved', () async {
    final posts = <String>[];
    var pulls = 0;
    final mockClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/products') {
        pulls++;
        return http.Response(
          '{"status":"success","data":[{"id":"p_lost","partNo":"NEW-9",'
          '"name":"Pad","nameTH":"","category":"เบรก","brand":"",'
          '"price":"120.00","cost":"80.00","stock":4,"minStock":1,'
          '"updatedAt":"2026-11-27T10:00:00.000Z","deletedAt":null}]}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/products') {
        posts.add(request.body);
        if (posts.length == 1) {
          return http.Response('{"status":"error","error":{"code":"BAD_GATEWAY","message":"x"}}', 502);
        }
        return http.Response(
          '{"status":"error","error":{"code":"DUPLICATE_PART_NO","message":"dup"}}',
          409,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final repo = ApiProductsRepository(db, ApiClient(httpClient: mockClient));

    await expectLater(
      repo.add(const ProductsCompanion(partNo: Value('NEW-9'), name: Value('Pad'), price: Value(120.0))),
      throwsA(anything),
    );
    // Edited: a different price.
    Object? err;
    try {
      await repo.add(const ProductsCompanion(partNo: Value('new-9'), name: Value('Pad'), price: Value(150.0)));
    } catch (e) {
      err = e;
    }
    expect(posts, hasLength(2));
    expect(err, isA<PosException>());
    expect((err! as PosException).message, ApiProductsRepository.addMayHaveSavedMessage);
    expect(pulls, greaterThanOrEqualTo(1));
    final row = await (db.select(db.products)..where((t) => t.id.equals('p_lost'))).getSingleOrNull();
    expect(row?.price, 120.0, reason: 'the server kept the first attempt');

    // Resolved: the next 409 for that part number is a plain duplicate.
    Object? again;
    try {
      await repo.add(const ProductsCompanion(partNo: Value('NEW-9'), name: Value('Pad'), price: Value(150.0)));
    } catch (e) {
      again = e;
    }
    expect(again, isA<PosException>());
    expect((again! as PosException).message, isNot(ApiProductsRepository.addMayHaveSavedMessage));
  });

  test('adjustStock applies server stockAfter directly without local clamping and logs movement', () async {
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'p_adj',
            partNo: 'ADJ-001',
            name: 'Spark',
            nameTH: 'หัวเทียน',
            category: 'ไฟฟ้า',
            brand: 'NGK',
            price: 100,
            cost: 50,
            stock: 10,
            minStock: 2,
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path.contains('/adjust-stock')) {
        return http.Response(
          '{"status":"success","data":{"id":"p_adj","stockAfter":42}}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiProductsRepository(db, apiClient);

    await repo.adjustStock('p_adj', 5, 'manual', 'ปรับสต็อก');

    // Drift row has server's stockAfter (42)
    final product = await (db.select(db.products)..where((t) => t.id.equals('p_adj'))).getSingle();
    expect(product.stock, 42);

    // Movement was recorded
    final movements = await db.select(db.movements).get();
    expect(movements.length, 1);
    expect(movements.first.stockAfter, 42);
    expect(movements.first.delta, 5);
  });

  test('delete stamps deletedAt in Drift as soft-delete', () async {
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'p_del',
            partNo: 'DEL-002',
            name: 'To Delete',
            nameTH: 'เตรียมลบ',
            category: 'ตัวถัง',
            brand: 'OEM',
            price: 50,
            cost: 20,
            stock: 1,
            minStock: 0,
          ),
        );

    final mockClient = MockClient((request) async {
      return http.Response('{"status":"success"}', 200, headers: {'content-type': 'application/json'});
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiProductsRepository(db, apiClient);

    await repo.delete('p_del');

    final product = await (db.select(db.products)..where((t) => t.id.equals('p_del'))).getSingle();
    expect(product.deletedAt, isNotNull);

    // Excluded from getAll
    final all = await (db.select(db.products)..where((t) => t.deletedAt.isNull())).get();
    expect(all.any((p) => p.id == 'p_del'), isFalse);
  });
}
