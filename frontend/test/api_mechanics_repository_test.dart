// Unit tests for ApiMechanicsRepository (Ticket #55 / ADR-0010).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('getMechanics fetches from server, writes through to Drift, and excludes deleted', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/mechanics') {
        return http.Response(
          '''{
            "status": "success",
            "data": [
              {
                "id": "m_1",
                "code": "MEC001",
                "name": "Chang Dam",
                "nameTH": "ช่างดำ",
                "nickname": "ดำ",
                "shopName": "ดำการช่าง",
                "phone": "0811111111",
                "creditLimit": "5000.00",
                "creditBalance": "1200.00",
                "totalSales": "10000.00",
                "totalDiscount": "500.00",
                "createdAt": "2026-09-12T10:00:00.000Z",
                "deletedAt": null
              },
              {
                "id": "m_del",
                "code": "MEC002",
                "name": "Deleted",
                "nameTH": "ช่างลบ",
                "creditLimit": "0.00",
                "creditBalance": "0.00",
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
    final repo = ApiMechanicsRepository(db, apiClient);

    final mechanics = await repo.getMechanics();

    expect(mechanics.any((m) => m.id == 'm_del'), isFalse);
    final active = mechanics.firstWhere((m) => m.id == 'm_1');
    expect(active.nameTH, 'ช่างดำ');
    expect(active.creditLimit, 5000.0);
    expect(active.creditBalance, 1200.0);

    // Verify written through to Drift
    final inDrift = await (db.select(db.mechanics)..where((t) => t.id.equals('m_1'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.nickname, 'ดำ');
  });

  test('addCreditPayment patches mechanic creditBalance directly from server response', () async {
    // Seed mechanic locally with balance 2000
    await db.into(db.mechanics).insert(
          MechanicsCompanion.insert(
            id: 'm_target',
            code: 'MEC010',
            name: 'Target Mechanic',
            createdAt: '2026-09-12T10:00:00.000Z',
            creditBalance: const Value(2000.0),
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/mechanics/m_target/credit-payments' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "payment": {
                "id": "cp_remote_1",
                "receiptNo": "CP202609-0001",
                "mechanicId": "m_target",
                "amount": 500.0,
                "date": "2026-09-12T13:00:00.000Z",
                "note": "ชำระเงินสด"
              },
              "mechanicCreditBalanceAfter": 1500.0
            }
          }''',
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiMechanicsRepository(db, apiClient);

    final payment = await repo.addCreditPayment(
      mechanicId: 'm_target',
      amount: 500.0,
      note: 'ชำระเงินสด',
    );

    expect(payment.id, 'cp_remote_1');
    expect(payment.receiptNo, 'CP202609-0001');
    expect(payment.amount, 500.0);

    // Verify mechanic balance in Drift was patched to exactly 1500.0
    final mechanicInDrift = await (db.select(db.mechanics)..where((t) => t.id.equals('m_target'))).getSingle();
    expect(mechanicInDrift.creditBalance, 1500.0);

    // Verify payment record in Drift
    final paymentInDrift = await (db.select(db.creditPayments)..where((t) => t.id.equals('cp_remote_1'))).getSingleOrNull();
    expect(paymentInDrift, isNotNull);
    expect(paymentInDrift!.note, 'ชำระเงินสด');
  });

  test('getMechanics falls back transparently to Drift when network fails', () async {
    // Seed Drift locally
    await db.into(db.mechanics).insert(
          MechanicsCompanion.insert(
            id: 'm_offline',
            code: 'MEC099',
            name: 'Offline Mechanic',
            createdAt: '2026-09-12T10:00:00.000Z',
          ),
        );

    final errorClient = MockClient((request) async {
      throw http.ClientException('Offline');
    });

    final apiClient = ApiClient(httpClient: errorClient);
    final repo = ApiMechanicsRepository(db, apiClient);

    final list = await repo.getMechanics();
    expect(list.any((m) => m.name == 'Offline Mechanic'), isTrue);
  });

  test('deleteMechanic marks deletedAt in Drift as soft delete', () async {
    await db.into(db.mechanics).insert(
          MechanicsCompanion.insert(
            id: 'm_to_delete',
            code: 'MEC088',
            name: 'To Delete',
            createdAt: '2026-09-12T10:00:00.000Z',
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/mechanics/m_to_delete' && request.method == 'DELETE') {
        return http.Response('{"status":"success","data":{"success":true}}', 200);
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiMechanicsRepository(db, apiClient);

    await repo.deleteMechanic('m_to_delete');

    final list = await repo.getMechanics();
    expect(list.any((m) => m.id == 'm_to_delete'), isFalse);

    final row = await (db.select(db.mechanics)..where((t) => t.id.equals('m_to_delete'))).getSingle();
    expect(row.deletedAt, isNotNull);
  });
}
