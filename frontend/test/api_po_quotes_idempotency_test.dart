// Review 2026-10-21: purchase orders and quotes are parked like every other
// API write (CLAUDE.md "Idempotency & the client write path", 08 §5).
//
//  • A lost reply (5xx / 429 / transport) leaves the attempt parked: the next
//    press goes out under the SAME `Idempotency-Key`, so the server replays the
//    first PO / quote instead of creating a second one.
//  • A reply without the server-owned id / document number is a contract error:
//    nothing is written, nothing is invented, and the attempt stays parked.
//  • A receive whose fate was unknown and is then answered
//    `409 PO_ALREADY_RECEIVED` is our own receive — success, after a re-read.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_purchase_orders_repository.dart';
import 'package:srisurart_pos/data/repositories/api_quotes_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

http.Response _ok(Object data, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode({'status': 'success', 'data': data})),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _error(int status, String code) => http.Response.bytes(
      utf8.encode(jsonEncode({
        'status': 'error',
        'error': {'code': code, 'message': code},
      })),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const _poInput = PoInput(
  supplier: 'Brembo Asia',
  items: [PoLineInput(partNo: 'BRK-01', name: 'Brake pad', qty: 4, cost: 350)],
);

final _quoteInput = QuoteInput(
  subtotal: 200,
  discount: 0,
  total: 200,
  customerName: 'ลูกค้า',
  validDays: 30,
  items: const [QuoteLineInput(productId: null, name: 'Brake pad', qty: 2, price: 100)],
);

Map<String, Object?> _poReply() => {
      'id': 'po-srv-1',
      'poNo': 'PO01-2569-10-0001',
      'supplier': 'Brembo Asia',
      'status': 'open',
      'createdAt': '2026-10-21T03:00:00.000Z',
    };

Map<String, Object?> _quoteReply([String id = 'qt-srv-1']) => {
      'id': id,
      'quoteNo': 'QT01-2569-10-0001',
      'status': 'open',
      'date': '2026-10-21T03:00:00.000Z',
      'validUntil': '2026-11-20T03:00:00.000Z',
      'total': '200.00',
      'items': [
        {'name': 'Brake pad', 'qty': 2, 'price': '100.00'},
      ],
    };

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory(), seedDemoData: false));
  tearDown(() => db.close());

  ApiClient client(MockClientHandler handler) =>
      ApiClient(baseUrl: 'http://example.com', httpClient: MockClient(handler));

  /// Runs [replies] in order and records the `Idempotency-Key` of each request.
  (ApiClient, List<String?>) scripted(List<Object> replies) {
    final keys = <String?>[];
    var i = 0;
    return (
      client((req) async {
        keys.add(req.headers['Idempotency-Key']);
        final r = replies[i++];
        if (r is Exception) throw r;
        return r as http.Response;
      }),
      keys,
    );
  }

  Future<List<PurchaseOrderRow>> pos() => db.select(db.purchaseOrders).get();
  Future<List<QuoteRow>> quotes() => db.select(db.quotes).get();

  group('ApiPurchaseOrdersRepository.savePO', () {
    test('a lost reply (500) then a second press reuses the SAME key; one PO', () async {
      final (api, keys) = scripted([_error(500, 'INTERNAL'), _ok(_poReply(), 201)]);
      final repo = ApiPurchaseOrdersRepository(db, api);

      await expectLater(repo.savePO(_poInput), throwsA(isA<PosException>()));
      expect(await pos(), isEmpty, reason: 'never a local write on a 5xx');
      final row = await repo.savePO(_poInput);

      expect(keys, hasLength(2));
      expect(keys[0], isNotEmpty);
      expect(keys[1], keys[0]);
      expect(row.id, 'po-srv-1');
      expect(await pos(), hasLength(1));
    });

    test('a transport failure also keeps the attempt parked', () async {
      final (api, keys) =
          scripted([http.ClientException('connection reset'), _ok(_poReply(), 201)]);
      final repo = ApiPurchaseOrdersRepository(db, api);

      await expectLater(repo.savePO(_poInput), throwsA(anything));
      await repo.savePO(_poInput);
      expect(keys[1], keys[0]);
    });

    test('a 4xx is a verdict: the next press is a new action (new key)', () async {
      final (api, keys) = scripted([_error(400, 'VALIDATION_FAILED'), _ok(_poReply(), 201)]);
      final repo = ApiPurchaseOrdersRepository(db, api);

      await expectLater(repo.savePO(_poInput), throwsA(isA<PosException>()));
      await repo.savePO(_poInput);
      expect(keys[1], isNot(keys[0]));
    });

    test('after a success the same PO pressed again is a new action', () async {
      final (api, keys) = scripted([_ok(_poReply(), 201), _ok(_poReply(), 201)]);
      final repo = ApiPurchaseOrdersRepository(db, api);
      await repo.savePO(_poInput);
      await repo.savePO(_poInput);
      expect(keys[1], isNot(keys[0]));
    });

    for (final missing in ['id', 'poNo']) {
      test('a reply without $missing: Thai error, nothing written, attempt parked', () async {
        final bad = _poReply()..remove(missing);
        final (api, keys) = scripted([_ok(bad, 201), _ok(_poReply(), 201)]);
        final repo = ApiPurchaseOrdersRepository(db, api);

        await expectLater(
          repo.savePO(_poInput),
          throwsA(isA<PosException>().having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
        );
        expect(await pos(), isEmpty, reason: 'no invented id / PO number');
        expect(await db.select(db.poItems).get(), isEmpty);

        await repo.savePO(_poInput);
        expect(keys[1], keys[0], reason: 'the server may have committed it');
      });
    }
  });

  group('ApiPurchaseOrdersRepository.receivePO', () {
    setUp(() async {
      await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
            id: 'po-1',
            poNo: 'PO01-2569-10-0001',
            supplier: 'Brembo Asia',
            createdAt: DateTime.utc(2026, 10, 21),
          ));
    });

    Map<String, Object?> received() => {
          'poId': 'po-1',
          'status': 'received',
          'receivedAt': '2026-10-21T04:00:00.000Z',
          'updated': <Object>[],
          'unmatched': <Object>[],
          'movements': <Object>[],
        };

    Future<PurchaseOrderRow> po() =>
        (db.select(db.purchaseOrders)..where((t) => t.id.equals('po-1'))).getSingle();

    test('a 502 then a second press reuses the SAME key', () async {
      final (api, keys) = scripted([_error(502, 'BAD_GATEWAY'), _ok(received())]);
      final repo = ApiPurchaseOrdersRepository(db, api);

      await expectLater(repo.receivePO('po-1'), throwsA(isA<PosException>()));
      expect((await po()).status, 'open');
      await repo.receivePO('po-1');

      expect(keys[1], keys[0]);
      expect((await po()).status, 'received');
      expect((await po()).receivedAt, DateTime.parse('2026-10-21T04:00:00.000Z').toLocal());
    });

    test('unknown fate then 409 PO_ALREADY_RECEIVED = our receive landed: re-read, success',
        () async {
      final paths = <String>[];
      final replies = <http.Response>[
        _error(504, 'GATEWAY_TIMEOUT'),
        _error(409, 'PO_ALREADY_RECEIVED'),
        _ok({
          'id': 'po-1',
          'poNo': 'PO01-2569-10-0001',
          'supplier': 'Brembo Asia',
          'status': 'received',
          'createdAt': '2026-10-21T00:00:00.000Z',
          'receivedAt': '2026-10-21T04:00:00.000Z',
          'items': <Object>[],
        }),
      ];
      var i = 0;
      final repo = ApiPurchaseOrdersRepository(
        db,
        client((req) async {
          paths.add('${req.method} ${req.url.path}');
          return replies[i++];
        }),
      );

      await expectLater(repo.receivePO('po-1'), throwsA(isA<PosException>()));
      final unmatched = await repo.receivePO('po-1');

      expect(unmatched, isEmpty);
      expect(paths.last, 'GET /api/v1/purchase-orders/po-1');
      expect((await po()).status, 'received');
      expect((await po()).receivedAt, DateTime.parse('2026-10-21T04:00:00.000Z').toLocal());
    });

    test('409 PO_ALREADY_RECEIVED with no earlier unknown attempt stays an error', () async {
      final (api, _) = scripted([_error(409, 'PO_ALREADY_RECEIVED')]);
      final repo = ApiPurchaseOrdersRepository(db, api);

      await expectLater(
        repo.receivePO('po-1'),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'PO_ALREADY_RECEIVED')),
      );
      expect((await po()).status, 'open');
    });
  });

  group('ApiPurchaseOrdersRepository cancel / delete', () {
    test('cancelPO: a 500 then a second press reuses the SAME key', () async {
      final (api, keys) = scripted([_error(500, 'INTERNAL'), _ok({'id': 'po-1'})]);
      final repo = ApiPurchaseOrdersRepository(db, api);
      await expectLater(repo.cancelPO('po-1'), throwsA(isA<PosException>()));
      await repo.cancelPO('po-1');
      expect(keys[1], keys[0]);
    });

    test('deletePO: a 503 then a second press reuses the SAME key', () async {
      final (api, keys) =
          scripted([_error(503, 'UNAVAILABLE'), _ok({'id': 'po-1', 'deleted': true})]);
      final repo = ApiPurchaseOrdersRepository(db, api);
      await expectLater(repo.deletePO('po-1'), throwsA(isA<PosException>()));
      await repo.deletePO('po-1');
      expect(keys[1], keys[0]);
    });
  });

  group('ApiQuotesRepository.saveQuote', () {
    test('a lost reply (500) then a second press reuses the SAME key; one quote', () async {
      final (api, keys) = scripted([_error(500, 'INTERNAL'), _ok(_quoteReply(), 201)]);
      final repo = ApiQuotesRepository(db, api);

      await expectLater(repo.saveQuote(_quoteInput), throwsA(isA<PosException>()));
      expect(await quotes(), isEmpty);
      final row = await repo.saveQuote(_quoteInput);

      expect(keys[1], keys[0]);
      expect(row.quoteNo, 'QT01-2569-10-0001');
      expect(await quotes(), hasLength(1));
    });

    for (final missing in ['id', 'quoteNo']) {
      test('a reply without $missing: Thai error, nothing written, attempt parked', () async {
        final bad = _quoteReply()..remove(missing);
        final (api, keys) = scripted([_ok(bad, 201), _ok(_quoteReply(), 201)]);
        final repo = ApiQuotesRepository(db, api);

        await expectLater(
          repo.saveQuote(_quoteInput),
          throwsA(isA<PosException>().having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
        );
        expect(await quotes(), isEmpty, reason: 'no invented id / QT number');
        expect(await db.select(db.quoteItems).get(), isEmpty);

        await repo.saveQuote(_quoteInput);
        expect(keys[1], keys[0]);
      });
    }
  });

  group('ApiQuotesRepository.duplicateQuote', () {
    test('a 429 then a second press reuses the SAME key', () async {
      final (api, keys) =
          scripted([_error(429, 'RATE_LIMITED'), _ok(_quoteReply('qt-dup'), 201)]);
      final repo = ApiQuotesRepository(db, api);

      await expectLater(repo.duplicateQuote('qt-src'), throwsA(isA<PosException>()));
      final dup = await repo.duplicateQuote('qt-src');

      expect(keys[1], keys[0]);
      expect(dup!.id, 'qt-dup');
    });

    test('a reply without quoteNo: Thai error, nothing written', () async {
      final bad = _quoteReply('qt-dup')..remove('quoteNo');
      final (api, _) = scripted([_ok(bad, 201)]);
      final repo = ApiQuotesRepository(db, api);

      await expectLater(repo.duplicateQuote('qt-src'), throwsA(isA<PosException>()));
      expect(await quotes(), isEmpty);
    });
  });
}
