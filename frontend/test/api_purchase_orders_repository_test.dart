// Unit tests for ApiPurchaseOrdersRepository (Ticket #55 / ADR-0010).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_purchase_orders_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('receivePO applies server stockAfter and costAfter directly without client calculation (ADR-0010)', () async {
    // 1. Seed a product in Drift: stock = 10, cost = 100.0
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'prod_target',
            partNo: 'OIL-001',
            name: 'Engine Oil',
            nameTH: 'น้ำมันเครื่อง',
            category: 'น้ำมันเครื่อง',
            brand: 'Castrol',
            price: 200.0,
            cost: 100.0,
            stock: 10,
            minStock: 2,
          ),
        );

    // 2. Seed a PO in Drift
    await db.into(db.purchaseOrders).insert(
          PurchaseOrdersCompanion.insert(
            id: 'po_test_1',
            poNo: 'PO202609-0001',
            supplier: 'Castrol Thailand',
            createdAt: DateTime.now(),
          ),
        );

    // Server returns arbitrary stockAfter: 22 and costAfter: 115.50
    // (If client ran weighted average: (10*100 + 10*120)/20 = 110.0, but server returned 115.50,
    // client MUST write 115.50 directly).
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/purchase-orders/po_test_1/receive' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "updated": [
                {
                  "partNo": "OIL-001",
                  "stockAfter": 22,
                  "costAfter": "115.50"
                }
              ],
              "unmatched": []
            }
          }''',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiPurchaseOrdersRepository(db, apiClient);

    final unmatched = await repo.receivePO('po_test_1');
    expect(unmatched, isEmpty);

    // Verify PO marked received in Drift
    final poInDrift = await (db.select(db.purchaseOrders)..where((t) => t.id.equals('po_test_1'))).getSingle();
    expect(poInDrift.status, 'received');
    expect(poInDrift.receivedAt, isNotNull);

    // Verify product has server's exact cost and stock
    final prodInDrift = await (db.select(db.products)..where((t) => t.id.equals('prod_target'))).getSingle();
    expect(prodInDrift.stock, 22);
    expect(prodInDrift.cost, 115.50);

    // Verify movement recorded
    final movements = await (db.select(db.movements)..where((t) => t.productId.equals('prod_target'))).get();
    expect(movements.isNotEmpty, isTrue);
    expect(movements.first.type, 'receive');
    expect(movements.first.stockAfter, 22);
  });

  test('savePO posts to server and writes through to Drift', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/purchase-orders' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "po_server_id",
              "poNo": "PO202609-0099",
              "supplier": "Brembo Asia",
              "status": "open",
              "createdAt": "2026-09-12T14:00:00.000Z"
            }
          }''',
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiPurchaseOrdersRepository(db, apiClient);

    final po = await repo.savePO(
      const PoInput(
        supplier: 'Brembo Asia',
        items: [
          PoLineInput(partNo: 'BRK-01', name: 'Brake Disc', qty: 5, cost: 500.0),
        ],
      ),
    );

    expect(po.id, 'po_server_id');
    expect(po.poNo, 'PO202609-0099');

    // Verify saved to Drift
    final poInDrift = await (db.select(db.purchaseOrders)..where((t) => t.id.equals('po_server_id'))).getSingleOrNull();
    expect(poInDrift, isNotNull);
    expect(poInDrift!.supplier, 'Brembo Asia');

    final itemsInDrift = await (db.select(db.poItems)..where((t) => t.poId.equals('po_server_id'))).get();
    expect(itemsInDrift.length, 1);
    expect(itemsInDrift.first.partNo, 'BRK-01');
  });

  test('cancelPO posts to server and marks status as cancelled', () async {
    await db.into(db.purchaseOrders).insert(
          PurchaseOrdersCompanion.insert(
            id: 'po_to_cancel',
            poNo: 'PO202609-0005',
            supplier: 'Supplier X',
            createdAt: DateTime.now(),
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/purchase-orders/po_to_cancel/cancel' && request.method == 'POST') {
        return http.Response('{"status":"success","data":{"status":"cancelled"}}', 200);
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiPurchaseOrdersRepository(db, apiClient);

    await repo.cancelPO('po_to_cancel');

    final po = await (db.select(db.purchaseOrders)..where((t) => t.id.equals('po_to_cancel'))).getSingle();
    expect(po.status, 'cancelled');
    expect(po.cancelledAt, isNotNull);
  });
}
