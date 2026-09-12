// Unit tests for ApiProductsRepository (Ticket #55 / ADR-0010).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
                "offlineOk": true,
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
                "offlineOk": false,
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
    expect(active.offlineOk, isTrue);

    // Verify it was written through to Drift DB
    final inDrift = await (db.select(db.products)..where((t) => t.id.equals('p_remote_1'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.nameTH, 'จานเบรก');
  });

  test('getAll uses ?updatedSince= cursor when latest updatedAt exists in Drift', () async {
    String? requestedUpdatedSince;

    // Seed one product with known updatedAt
    final knownDate = DateTime.utc(2026, 9, 10, 8, 30);
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'p_existing',
            partNo: 'EXT-001',
            name: 'Existing',
            nameTH: 'สินค้าเดิม',
            category: 'เครื่องยนต์',
            brand: 'Honda',
            price: 100,
            cost: 50,
            stock: 5,
            minStock: 1,
            updatedAt: Value(knownDate),
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

    expect(requestedUpdatedSince, equals(knownDate.toIso8601String()));
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
