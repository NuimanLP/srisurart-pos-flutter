// Unit tests for Ticket #55 write operations & Idempotency-Key headers (ADR-0010).

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
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/api_purchase_orders_repository.dart';
import 'package:srisurart_pos/data/repositories/api_quotes_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('ApiProductsRepository passes Idempotency-Key header on add, update, delete, adjustStock', () async {
    final headersSeen = <String, String?>{};

    final mockClient = MockClient((request) async {
      final key = request.headers['idempotency-key'] ?? request.headers['Idempotency-Key'];
      headersSeen[request.url.path] = key;

      if (request.url.path == '/api/v1/products' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "p_100",
              "partNo": "PN100",
              "name": "Spark Plug",
              "price": "150.00",
              "cost": "100.00",
              "stock": 10
            }
          }''',
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/products/p_100' && request.method == 'PATCH') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "p_100",
              "partNo": "PN100",
              "name": "Spark Plug Ir",
              "price": "180.00",
              "cost": "100.00",
              "stock": 10
            }
          }''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/products/p_100/adjust-stock' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "productId": "p_100",
              "stockAfter": 15,
              "movement": {
                "id": "mv_1",
                "productId": "p_100",
                "partNo": "PN100",
                "name": "Spark Plug Ir",
                "delta": 5,
                "type": "adjust",
                "stockAfter": 15,
                "date": "2026-09-15T10:00:00.000Z"
              }
            }
          }''',
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/products/p_100' && request.method == 'DELETE') {
        return http.Response('{"status":"success","data":{"id":"p_100","deleted":true}}', 200);
      }
      return http.Response('{"status":"error"}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiProductsRepository(db, apiClient);

    // 1. Add product
    final added = await repo.add(const ProductsCompanion(
      partNo: Value('PN100'),
      name: Value('Spark Plug'),
      price: Value(150.0),
      cost: Value(100.0),
      stock: Value(10),
    ));
    expect(added, isNotNull);
    expect(headersSeen['/api/v1/products'], isNotNull);

    // 2. Update product
    await repo.update('p_100', const ProductsCompanion(name: Value('Spark Plug Ir'), price: Value(180.0)));
    expect(headersSeen['/api/v1/products/p_100'], isNotNull);

    // 3. Adjust stock
    await repo.adjustStock('p_100', 5, 'adjust', 'Count adjustment');
    expect(headersSeen['/api/v1/products/p_100/adjust-stock'], isNotNull);

    final patchedInDrift = await (db.select(db.products)..where((t) => t.id.equals('p_100'))).getSingleOrNull();
    expect(patchedInDrift?.stock, 15);

    // 4. Delete product
    await repo.delete('p_100');
    expect(headersSeen['/api/v1/products/p_100'], isNotNull);
  });

  test('ApiQuotesRepository updateQuote convert routes to POST /api/v1/quotes/:id/convert with Idempotency-Key', () async {
    var convertCalled = false;
    String? convertIdempotencyKey;

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/quotes/q_50/convert' && request.method == 'POST') {
        convertCalled = true;
        convertIdempotencyKey = request.headers['idempotency-key'] ?? request.headers['Idempotency-Key'];
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "q_50",
              "status": "converted",
              "convertedAt": "2026-09-15T12:00:00.000Z"
            }
          }''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiQuotesRepository(db, apiClient);

    // Seed quote in Drift
    await db.into(db.quotes).insert(
          QuoteRow(
            id: 'q_50',
            quoteNo: 'QT202609-0050',
            date: DateTime.now(),
            validUntil: DateTime.now().add(const Duration(days: 30)),
            status: 'open',
            subtotal: 1000.0,
            discount: 0.0,
            total: 1000.0,
          ),
        );

    await repo.updateQuote('q_50', const QuotesCompanion(status: Value('converted')));

    expect(convertCalled, isTrue);
    expect(convertIdempotencyKey, isNotNull);

    final updatedDrift = await (db.select(db.quotes)..where((t) => t.id.equals('q_50'))).getSingleOrNull();
    expect(updatedDrift?.status, 'converted');
    expect(updatedDrift?.convertedAt, isNotNull);
  });

  test('ApiPurchaseOrdersRepository passes Idempotency-Key on savePO and receivePO', () async {
    final headersSeen = <String, String?>{};

    final mockClient = MockClient((request) async {
      final key = request.headers['idempotency-key'] ?? request.headers['Idempotency-Key'];
      headersSeen[request.url.path] = key;

      if (request.url.path == '/api/v1/purchase-orders' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "po_99",
              "poNo": "PO202609-0099",
              "supplier": "Denso",
              "status": "open"
            }
          }''',
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/purchase-orders/po_99/receive' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "po_99",
              "status": "received",
              "updated": []
            }
          }''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiPurchaseOrdersRepository(db, apiClient);

    final po = await repo.savePO(const PoInput(
      supplier: 'Denso',
      items: [PoLineInput(partNo: 'PN99', name: 'Filter', qty: 10, cost: 50.0)],
    ));
    expect(po.id, 'po_99');
    expect(headersSeen['/api/v1/purchase-orders'], isNotNull);

    await repo.receivePO('po_99');
    expect(headersSeen['/api/v1/purchase-orders/po_99/receive'], isNotNull);
  });

  test('ApiCustomersRepository and ApiMechanicsRepository pass Idempotency-Key headers', () async {
    final headersSeen = <String, String?>{};

    final mockClient = MockClient((request) async {
      final key = request.headers['idempotency-key'] ?? request.headers['Idempotency-Key'];
      headersSeen[request.url.path] = key;

      if (request.url.path == '/api/v1/customers' && request.method == 'POST') {
        return http.Response(
          '{"status":"success","data":{"id":"cus_1","code":"CUS001","name":"Somchai"}}',
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/v1/mechanics' && request.method == 'POST') {
        return http.Response(
          '{"status":"success","data":{"id":"mech_1","code":"MEC001","name":"Chang Noi","creditLimit":"5000.00"}}',
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final customersRepo = ApiCustomersRepository(db, apiClient);
    final mechanicsRepo = ApiMechanicsRepository(db, apiClient);

    await customersRepo.addCustomer(const CustomersCompanion(name: Value('Somchai')));
    expect(headersSeen['/api/v1/customers'], isNotNull);

    await mechanicsRepo.addMechanic(const MechanicsCompanion(name: Value('Chang Noi')));
    expect(headersSeen['/api/v1/mechanics'], isNotNull);
  });

  group('ApiMechanicsRepository.addMechanic failures (mob04 2026-10-03)', () {
    const dialogInput = MechanicsCompanion(
      nameTH: Value('ช่างเอก'),
      nickname: Value('เอก'),
      shopName: Value('เอก บางบอย'),
      phone: Value(''),
      note: Value(''),
      creditLimit: Value(20000),
    );

    http.Response error(int status, String code, String message) => http.Response(
          '{"status":"error","error":{"code":"$code","message":"$message"}}',
          status,
          headers: {'content-type': 'application/json'},
        );

    test('the add dialog never sets name, so the body carries name "" beside nameTH',
        () async {
      // Pins the body the server must accept (people.dto.ts nameOrThai). The
      // dialog builds exactly this companion for "name only, limit 0".
      Map<String, dynamic>? sent;
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((request) async {
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              '{"status":"success","data":{"id":"m_1","code":"M001","name":"ทดสอบ-ลบได้","nameTH":"ทดสอบ-ลบได้","creditLimit":"0.00"}}',
              201,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      await repo.addMechanic(const MechanicsCompanion(
        nameTH: Value('ทดสอบ-ลบได้'),
        nickname: Value(''),
        shopName: Value(''),
        phone: Value(''),
        note: Value(''),
        creditLimit: Value(0),
      ));
      expect(sent, {
        'name': '',
        'nameTH': 'ทดสอบ-ลบได้',
        'nickname': '',
        'shopName': '',
        'phone': '',
        'note': '',
        'creditLimit': '0.00',
      });
    });

    test('a 4xx leaves as a Thai PosException, never an ApiException', () async {
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((_) async => error(400, 'BAD_REQUEST', 'name is required')),
        ),
      );
      await expectLater(
        repo.addMechanic(dialogInput),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'BAD_REQUEST')
            .having((e) => e.message, 'message', 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่')),
      );
    });

    test('updateMechanic and deleteMechanic refusals leave as Thai PosExceptions too', () async {
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((_) async => error(400, 'BAD_REQUEST', 'creditLimit is invalid')),
        ),
      );
      final thai = throwsA(isA<PosException>().having(
          (e) => e.message, 'message', 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่'));
      await expectLater(repo.updateMechanic('m1', dialogInput), thai);
      await expectLater(repo.deleteMechanic('m1'), thai);
    });

    test('a transport failure leaves as a Thai PosException', () async {
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((_) async => throw http.ClientException('Failed to fetch')),
        ),
      );
      await expectLater(
        repo.addMechanic(dialogInput),
        throwsA(isA<PosException>().having(
            (e) => e.message, 'message', 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์')),
      );
    });

    test('a retry after a 5xx reuses the Idempotency-Key; after a 4xx it does not', () async {
      final keys = <String?>[];
      final replies = <http.Response>[
        error(500, 'INTERNAL_ERROR', 'Internal server error'),
        error(400, 'BAD_REQUEST', 'name is required'),
        error(400, 'BAD_REQUEST', 'name is required'),
      ];
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((request) async {
            keys.add(request.headers['idempotency-key'] ?? request.headers['Idempotency-Key']);
            return replies.removeAt(0);
          }),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(repo.addMechanic(dialogInput), throwsA(isA<PosException>()));
      }
      expect(keys, hasLength(3));
      expect(keys[1], keys[0], reason: 'fate unknown after a 5xx: same attempt');
      expect(keys[2], isNot(keys[1]), reason: 'a 4xx is a verdict: next press is new');
    });
  });
}
