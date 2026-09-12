// Unit tests for BootstrapService (Ticket #55 / ADR-0010).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/services/bootstrap_service.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('bootstrap succeeds and batches products, categories, customers, mechanics, settings into Drift', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/bootstrap') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "categories": ["เครื่องยนต์", "เบรก", "ช่วงล่าง"],
              "products": [
                {
                  "id": "p_boot_1",
                  "partNo": "BT-001",
                  "name": "Boot Part",
                  "nameTH": "ชิ้นส่วนทดสอบ",
                  "category": "เบรก",
                  "brand": "TRW",
                  "price": "350.00",
                  "cost": "200.00",
                  "stock": 15,
                  "minStock": 3,
                  "offlineOk": true
                }
              ],
              "customers": [
                {
                  "id": "c_boot_1",
                  "code": "CUS099",
                  "name": "Boot Customer",
                  "nameTH": "ลูกค้าบูต",
                  "phone": "0812223344",
                  "points": 100,
                  "totalSpend": "5000.00",
                  "createdAt": "2026-09-12T10:00:00.000Z"
                }
              ],
              "mechanics": [
                {
                  "id": "m_boot_1",
                  "code": "MEC099",
                  "name": "Boot Mechanic",
                  "nameTH": "ช่างบูต",
                  "creditLimit": "10000.00",
                  "creditBalance": "500.00",
                  "createdAt": "2026-09-12T10:00:00.000Z"
                }
              ],
              "settings": {
                "shopName": "ร้านศรีสุราษฎร์การช่าง (ทดสอบ)",
                "shopNameEN": "Srisurart Test",
                "taxRate": 7.0,
                "phone": "077-123456"
              }
            }
          }''',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final service = BootstrapService(db: db, apiClient: apiClient);

    final ok = await service.bootstrap();
    expect(ok, isTrue);

    // Verify Drift entries
    final product = await (db.select(db.products)..where((t) => t.id.equals('p_boot_1'))).getSingleOrNull();
    expect(product, isNotNull);
    expect(product!.partNo, 'BT-001');
    expect(product.offlineOk, isTrue);

    final customer = await (db.select(db.customers)..where((t) => t.id.equals('c_boot_1'))).getSingleOrNull();
    expect(customer, isNotNull);
    expect(customer!.code, 'CUS099');

    final mechanic = await (db.select(db.mechanics)..where((t) => t.id.equals('m_boot_1'))).getSingleOrNull();
    expect(mechanic, isNotNull);
    expect(mechanic!.creditBalance, 500.0);

    final categories = await (db.select(db.categories)).get();
    expect(categories.any((c) => c.name == 'เบรก'), isTrue);

    final settings = await (db.select(db.settingsRow)..where((t) => t.id.equals(0))).getSingleOrNull();
    expect(settings, isNotNull);
    expect(settings!.shopName, 'ร้านศรีสุราษฎร์การช่าง (ทดสอบ)');
  });

  test('bootstrap falls back gracefully to individual endpoints if /bootstrap 404s', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/bootstrap') {
        return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
      }
      if (request.url.path == '/api/v1/products') {
        return http.Response(
          '''{
            "status": "success",
            "data": [
              {
                "id": "p_indiv_1",
                "partNo": "IND-01",
                "name": "Indiv Part",
                "nameTH": "ชิ้นส่วนเดี่ยว",
                "category": "เครื่องยนต์",
                "brand": "Bosch",
                "price": "500.00",
                "cost": "300.00",
                "stock": 5,
                "minStock": 1
              }
            ]
          }''',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/api/v1/categories') {
        return http.Response('{"status":"success","data":["เครื่องยนต์"]}', 200);
      }
      if (request.url.path == '/api/v1/customers') {
        return http.Response('{"status":"success","data":[]}', 200);
      }
      if (request.url.path == '/api/v1/mechanics') {
        return http.Response('{"status":"success","data":[]}', 200);
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final service = BootstrapService(db: db, apiClient: apiClient);

    final ok = await service.bootstrap();
    expect(ok, isTrue);

    final product = await (db.select(db.products)..where((t) => t.id.equals('p_indiv_1'))).getSingleOrNull();
    expect(product, isNotNull);
    expect(product!.partNo, 'IND-01');
  });

  test('bootstrap returns false when completely offline', () async {
    final errorClient = MockClient((request) async {
      throw http.ClientException('Network down');
    });

    final apiClient = ApiClient(httpClient: errorClient);
    final service = BootstrapService(db: db, apiClient: apiClient);

    final ok = await service.bootstrap();
    expect(ok, isFalse);
  });
}
