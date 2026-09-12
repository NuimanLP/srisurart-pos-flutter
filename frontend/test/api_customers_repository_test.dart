// Unit tests for ApiCustomersRepository (Ticket #55 / ADR-0010).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_customers_repository.dart';

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
}
