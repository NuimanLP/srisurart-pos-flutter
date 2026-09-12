// Unit tests for ApiQuotesRepository (Ticket #55 / ADR-0010).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
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

  test('saveQuote posts to server and writes through to Drift', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/quotes' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "q_server_1",
              "quoteNo": "QT202609-0001",
              "customerName": "Prasert",
              "total": "2500.00"
            }
          }''',
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiQuotesRepository(db, apiClient);

    final quote = await repo.saveQuote(
      const QuoteInput(
        customerName: 'Prasert',
        customerPhone: '0812345678',
        subtotal: 2500.0,
        discount: 0.0,
        total: 2500.0,
        items: [
          QuoteLineInput(productId: 'p_1', name: 'Shock Absorber', qty: 2, price: 1250.0),
        ],
      ),
    );

    expect(quote.id, 'q_server_1');
    expect(quote.quoteNo, 'QT202609-0001');

    // Verify written to Drift
    final inDrift = await (db.select(db.quotes)..where((t) => t.id.equals('q_server_1'))).getSingleOrNull();
    expect(inDrift, isNotNull);
    expect(inDrift!.customerName, 'Prasert');

    final items = await (db.select(db.quoteItems)..where((t) => t.quoteId.equals('q_server_1'))).get();
    expect(items.length, 1);
    expect(items.first.name, 'Shock Absorber');
  });

  test('duplicateQuote posts to server and creates cloned quote in Drift', () async {
    // Seed initial quote
    await db.into(db.quotes).insert(
          QuoteRow(
            id: 'q_orig',
            quoteNo: 'QT202609-0010',
            date: DateTime.now(),
            validUntil: DateTime.now().add(const Duration(days: 30)),
            status: 'open',
            customerName: 'Original Customer',
            subtotal: 1000.0,
            discount: 0.0,
            total: 1000.0,
          ),
        );
    await db.into(db.quoteItems).insert(
          QuoteItemsCompanion.insert(
            quoteId: 'q_orig',
            name: 'Wiper Blade',
            qty: 2,
            price: 500.0,
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/quotes/q_orig/duplicate' && request.method == 'POST') {
        return http.Response(
          '''{
            "status": "success",
            "data": {
              "id": "q_dup_server",
              "quoteNo": "QT202609-0011"
            }
          }''',
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiQuotesRepository(db, apiClient);

    final cloned = await repo.duplicateQuote('q_orig');
    expect(cloned, isNotNull);
    expect(cloned!.id, 'q_dup_server');
    expect(cloned.quoteNo, 'QT202609-0011');

    // Verify duplicated in Drift
    final clonedItems = await (db.select(db.quoteItems)..where((t) => t.quoteId.equals('q_dup_server'))).get();
    expect(clonedItems.length, 1);
    expect(clonedItems.first.name, 'Wiper Blade');
  });

  test('purgeOldQuotes posts to server and removes old quotes from Drift', () async {
    final oldDate = DateTime.now().subtract(const Duration(days: 120));
    await db.into(db.quotes).insert(
          QuoteRow(
            id: 'q_old',
            quoteNo: 'QT202601-0001',
            date: oldDate,
            validUntil: oldDate.add(const Duration(days: 30)),
            status: 'expired',
            subtotal: 500.0,
            discount: 0.0,
            total: 500.0,
          ),
        );

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/quotes/purge' && request.method == 'POST') {
        return http.Response(
          '{"status":"success","data":{"count":1}}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"status":"error","error":{"code":"NOT_FOUND"}}', 404);
    });

    final apiClient = ApiClient(httpClient: mockClient);
    final repo = ApiQuotesRepository(db, apiClient);

    final purgedCount = await repo.purgeOldQuotes(olderThanDays: 90);
    expect(purgedCount, 1);

    final inDrift = await (db.select(db.quotes)..where((t) => t.id.equals('q_old'))).getSingleOrNull();
    expect(inDrift, isNull);
  });
}
