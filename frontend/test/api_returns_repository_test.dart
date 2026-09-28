// ApiReturnsRepository (#56) — the credit note is the server's document.
//
// As in the sales test, the mock answers with numbers the client's own
// arithmetic could not produce (stock 77 after putting 1 back on a shelf of 3),
// so any fallback to the Drift `createReturn` maths fails the test rather than
// passing it quietly.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_returns_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/services/doc_number_service.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

/// Enough of a token store for `SyncService` to be constructed.
class _MemTokenStorage implements TokenStorage {
  @override
  Future<String?> getAccessToken() async => null;
  @override
  Future<void> setAccessToken(String? token) async {}
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<String?> getDeviceToken() async => 'pos-device-token-01';
  @override
  Future<void> setDeviceToken(String? token) async {}
  @override
  Future<AuthUser?> getUser() async => null;
  @override
  Future<void> setUser(AuthUser? user) async {}
  @override
  Future<void> clearAuthTokens() async {}
  @override
  Future<void> clearAll() async {}
}

String _ok(Map<String, dynamic> data) =>
    jsonEncode({'status': 'success', 'data': data});

String _err(String code, String message) => jsonEncode({
  'status': 'error',
  'error': {'code': code, 'message': message},
});

void main() {
  late AppDatabase db;
  late List<http.Request> sent;

  ApiReturnsRepository repoWith(
    Future<http.Response> Function(http.Request req) handler,
  ) {
    final client = MockClient((req) async {
      sent.add(req);
      return handler(req);
    });
    return ApiReturnsRepository(
      api: ApiClient(baseUrl: 'http://server.test', httpClient: client),
      db: db,
      drift: ReturnsRepository(db),
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: 'tp1',
            partNo: 'TP-1',
            name: 'Brake Pad',
            nameTH: 'ผ้าเบรก',
            category: 'เบรก',
            brand: 'X',
            price: 100,
            cost: 60,
            stock: 3,
            minStock: 1,
          ),
        );
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: 'tc1',
            code: 'C-1',
            name: 'Somchai',
            nameTH: 'สมชาย',
            createdAt: '2026-01-01',
            points: const Value(50),
            totalSpend: const Value(500),
          ),
        );
    await db
        .into(db.mechanics)
        .insert(
          MechanicsCompanion.insert(
            id: 'tm1',
            code: 'M-1',
            name: 'Chang',
            createdAt: '2026-01-01',
            creditLimit: const Value(5000),
            creditBalance: const Value(500),
          ),
        );
    // The parent bill: FIVE pads sold. Returning one of them is a PARTIAL
    // return — no local count could ever conclude "void the bill".
    await db
        .into(db.sales)
        .insert(
          SaleRow(
            id: 'sale-1',
            receiptNo: 'RC-00042',
            subtotal: 500,
            discount: 0,
            total: 500,
            paymentMethod: 'เงินสด',
            customerId: 'tc1',
            customerName: 'สมชาย',
            mechanicId: 'tm1',
            mechanicName: 'ช่างเอ',
            mechanicDelta: null,
            pointsGranted: 50,
            date: DateTime(2026, 9, 1),
            voided: false,
            voidedAt: null,
            shiftId: null,
            soldOffline: false,
            voidReason: null,
          ),
        );
    await db
        .into(db.saleItems)
        .insert(
          SaleItemsCompanion.insert(
            saleId: 'sale-1',
            productId: 'tp1',
            name: 'Brake Pad',
            qty: 5,
            price: 100,
          ),
        );
  });

  tearDown(() async => db.close());

  const oneBack = ReturnInput(
    saleId: 'sale-1',
    refundMethod: 'เงินสด',
    reason: 'ของชำรุด',
    items: [
      ReturnLineInput(
        productId: 'tp1',
        name: 'Brake Pad',
        qty: 1,
        price: 100,
        originalQty: 5,
      ),
    ],
  );

  Map<String, dynamic> creditNote({bool saleVoided = false}) => {
    'id': 'r-server',
    'cnNo': 'CN-00007',
    'saleId': 'sale-1',
    'receiptNo': 'RC-00042',
    // The server's own amounts — a client summing 1 × 100 would say 100.
    'refundSubtotal': '100.00',
    'refundDiscount': '12.50',
    'refundTotal': '87.50',
    'refundMethod': 'เงินสด',
    'reason': 'ของชำรุด',
    'customerId': 'tc1',
    'mechanicId': 'tm1',
    'mechanicName': 'ช่างเอ',
    'date': '2026-09-12T04:00:00.000Z',
    // No column for this on the client — must be dropped, not crash.
    'shiftId': 'shift-xyz',
    'items': [
      {
        'lineNo': 1,
        'productId': 'tp1',
        'name': 'Brake Pad',
        'qty': 1,
        'price': '100.00',
        'originalQty': 5,
        'costAtSale': '60.00',
      },
    ],
    // 77, not 3 + 1 = 4.
    'products': [
      {'id': 'tp1', 'stock': 77},
    ],
    'customerAfter': {'id': 'tc1', 'points': 11, 'totalSpend': '222.25'},
    'mechanicCreditBalanceAfter': '333.75',
    'saleVoided': saleVoided,
    // ── #82's two new fields ──
    // The restore row the server actually wrote: stockAfter 77 again, and
    // `type: 'return'` — never collapsed into a void's 'return'-looking row
    // (migration 1788652800003 separated them so reports stop double-counting).
    'movements': [
      {
        'id': 'mv-server-r1',
        'productId': 'tp1',
        'partNo': 'TP-1',
        'name': 'Brake Pad',
        'delta': 1,
        'type': 'return',
        'note': 'CN-00007',
        'stockAfter': 77,
        'date': '2026-09-12T04:00:00.000Z',
      },
    ],
    // Four totals reversed by the server. A client reversing ฿87.50 off the
    // seeded 500 could produce none of them.
    'mechanicAfter': {
      'id': 'tm1',
      'totalSales': '999.00',
      'totalDiscount': '8.50',
      'totalMarkup': '1.25',
      'creditBalance': '333.75',
    },
  };

  /// The same credit note from a server that has not shipped #82: no
  /// `movements`, no `mechanicAfter`.
  Map<String, dynamic> creditNotePre82() => creditNote()
    ..remove('movements')
    ..remove('mechanicAfter');

  test(
    'patches the credit note and every effect from the response only',
    () async {
      late Map<String, dynamic> body;
      final repo = repoWith((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          _ok(creditNote()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final cn = await repo.createReturn(oneBack);

      // What `returns_screen.dart` prints on the note.
      expect(cn.id, 'r-server');
      expect(cn.cnNo, 'CN-00007');
      expect(cn.receiptNo, 'RC-00042');
      expect(cn.refundSubtotal, 100);
      expect(cn.refundDiscount, 12.5);
      expect(cn.refundTotal, 87.5);
      expect(cn.date, DateTime.parse('2026-09-12T04:00:00.000Z').toLocal());

      final rows = await db.select(db.returns).get();
      expect(rows, hasLength(1));
      expect(rows.single.refundTotal, 87.5);

      final items = await db.select(db.returnItems).get();
      expect(items, hasLength(1));
      expect(items.single.returnId, 'r-server');
      expect(items.single.qty, 1);
      expect(items.single.price, 100);
      expect(items.single.originalQty, 5);

      final p = await (db.select(
        db.products,
      )..where((t) => t.id.equals('tp1'))).getSingle();
      expect(p.stock, 77, reason: 'server value; local maths would give 4');
      expect(p.updatedAt, isNull, reason: 'updatedAt is #55\'s sync cursor');

      final c = await (db.select(
        db.customers,
      )..where((t) => t.id.equals('tc1'))).getSingle();
      expect(c.points, 11); // not 50 - something
      expect(c.totalSpend, 222.25); // not 500 - 87.50

      final m = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('tm1'))).getSingle();
      expect(m.creditBalance, 333.75); // not 500, not 500 - 87.50
      // #82: the other three running totals the server reverses too.
      expect(m.totalSales, 999);
      expect(m.totalDiscount, 8.5);
      expect(m.totalMarkup, 1.25);
      // 🔴 The legacy alias of totalDiscount (#11) — the server never writes it.
      expect(m.totalCredit, 0);

      // #82: the stock log row the server wrote, copied verbatim.
      final mv = await db.select(db.movements).get();
      expect(mv, hasLength(1));
      expect(mv.single.id, 'mv-server-r1'); // the server's id, not newId('mv')
      expect(mv.single.type, 'return');
      expect(mv.single.delta, 1);
      expect(mv.single.stockAfter, 77, reason: 'server value; local maths says 4');
      expect(mv.single.note, 'CN-00007');
      expect(
        mv.single.date,
        DateTime.parse('2026-09-12T04:00:00.000Z').toLocal(),
      );

      // ── The wire ──
      expect(body['saleId'], 'sale-1');
      expect(body['refundMethod'], 'เงินสด');
      expect(body['reason'], 'ของชำรุด');
      final line = (body['items'] as List).single as Map<String, dynamic>;
      // 🔴 Sent verbatim: the bill decides the price, and a mismatch must be
      // refused by the server rather than silently "corrected" here.
      expect(line['price'], '100.00');
      expect(line['qty'], 1);
      expect(line['originalQty'], 5);
      // The client's id (#452, 08 §6.1) — the server records the note under it.
      expect(body['id'], startsWith('r'));
      // Online, the number is still the server's (parity with `POST /sales`).
      expect(body.containsKey('cnNo'), isFalse);
      expect(body.containsKey('shiftId'), isFalse);

      final post = sent.single;
      expect(post.url.path, '/api/v1/returns');
      expect(post.headers['Idempotency-Key'], isNotNull);
    },
  );

  test(
    '#82 — a response WITHOUT movements or mechanicAfter leaves them stale, no throw',
    () async {
      // A server that predates #82. Absent is "stale", never "work it out here"
      // (ADR-0010 §3), and above all never an exception at the counter.
      await (db.update(db.mechanics)..where((t) => t.id.equals('tm1'))).write(
        const MechanicsCompanion(
          totalSales: Value(11.11),
          totalDiscount: Value(22.22),
          totalMarkup: Value(33.33),
        ),
      );

      final repo = repoWith(
        (req) async => http.Response(
          _ok(creditNotePre82()),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );

      final cn = await repo.createReturn(oneBack);
      expect(cn.cnNo, 'CN-00007');
      expect(cn.refundTotal, 87.5);

      expect(
        await db.select(db.movements).get(),
        isEmpty,
        reason: 'movements are not in the response and must not be synthesised',
      );

      final m = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('tm1'))).getSingle();
      expect(m.totalSales, 11.11, reason: 'stale, not moved by local arithmetic');
      expect(m.totalDiscount, 22.22);
      expect(m.totalMarkup, 33.33);
      // The legacy `mechanicCreditBalanceAfter` is still there and still used.
      expect(m.creditBalance, 333.75);
    },
  );

  test(
    'AC5 — sales.voided follows the saleVoided FLAG, not a local quantity count',
    () async {
      // One pad back out of five: no count on this device could conclude "void".
      final repo = repoWith(
        (req) async => http.Response(
          _ok(creditNote(saleVoided: true)),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );

      final cn = await repo.createReturn(oneBack);

      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isTrue);
      // The void happened in the credit note's own transaction, so its server
      // timestamp is the honest one — not a local clock reading.
      expect(sale.voidedAt, cn.date);

      // Sanity: the local numbers really do say "partial".
      final sold = await db.select(db.saleItems).get();
      final back = await db.select(db.returnItems).get();
      expect(sold.single.qty, 5);
      expect(back.single.qty, 1);
    },
  );

  test(
    'a partial return leaves the bill standing when the flag says so',
    () async {
      final repo = repoWith(
        (req) async => http.Response(
          _ok(creditNote(saleVoided: false)),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );
      await repo.createReturn(oneBack);
      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isFalse);
      expect(sale.voidedAt, isNull);
    },
  );

  test(
    'a 409 RETURN_PRICE_MISMATCH throws Thai and writes nothing',
    () async {
      final repo = repoWith(
        (req) async => http.Response(
          // The server's own message is English; the resolver supplies the Thai.
          _err(
            'RETURN_PRICE_MISMATCH',
            'Line 1 did not sell at that price on this bill.',
          ),
          409,
          headers: {'content-type': 'application/json'},
        ),
      );

      Object? thrown;
      try {
        await repo.createReturn(oneBack);
      } catch (e) {
        thrown = e;
      }

      // Again on this repository: a plain Exception carrying a clean Thai
      // sentence — `returns_screen.dart:238` renders exactly this.
      expect(thrown, isA<Exception>());
      expect(thrown, isNot(isA<ApiException>()));
      expect(
        thrown.toString().replaceFirst('Exception: ', ''),
        'ราคาใบลดหนี้ไม่ตรงกับบิลขาย',
      );

      expect(await db.select(db.returns).get(), isEmpty);
      expect(await db.select(db.returnItems).get(), isEmpty);
      final p = await (db.select(
        db.products,
      )..where((t) => t.id.equals('tp1'))).getSingle();
      expect(p.stock, 3);
      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isFalse);
    },
  );

  test('a rejected refund method surfaces its Thai sentence', () async {
    final repo = repoWith(
      (req) async => http.Response(
        _err(
          'REFUND_METHOD_NOT_ALLOWED',
          "Refund method 'หักจากเครดิต' needs a bill with a mechanic.",
        ),
        409,
        headers: {'content-type': 'application/json'},
      ),
    );

    Object? thrown;
    try {
      await repo.createReturn(oneBack);
    } catch (e) {
      thrown = e;
    }
    final msg = thrown.toString().replaceFirst('Exception: ', '');
    expect(msg, isNot(contains('ApiException')));
    // Fixed in #83: `ServerErrorResolver.resolve` now checks `_startsWithThai`
    // so English sentences quoting Thai literals (like `returns.service.ts`'s
    // `Refund method 'หักจากเครดิต' needs a bill with a mechanic.`) correctly
    // resolve to the canonical Thai string `วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้`.
    expect(msg, 'วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้');
  });

  group('a lost reply must not become a second credit note', () {
    test('a dropped connection then a second press replays the SAME key', () async {
      // 🔴 `assertRefundable` will not catch a resend: it allows anything up to
      // `sold - refunded`, so returning 1 of 5 twice is two legal credit notes
      // and twice the money out of the drawer. Same key AND same client id.
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) throw const SocketException('connection closed');
        return http.Response(
          _ok(creditNote()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        () => repo.createReturn(oneBack),
        throwsA(isA<SocketException>()),
      );
      final cn = await repo.createReturn(oneBack);

      final posts = sent.where((r) => r.url.path == '/api/v1/returns').toList();
      expect(posts, hasLength(2));
      expect(
        posts.map((r) => r.headers['Idempotency-Key']).toSet(),
        hasLength(1),
        reason: 'a fresh key here refunds the same goods twice',
      );
      expect(
        posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
        hasLength(1),
      );
      expect(cn.id, 'r-server');
      expect(await db.select(db.returns).get(), hasLength(1));
    });

    test('a 502 is not a verdict either', () async {
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) {
          return http.Response('<html>502 Bad Gateway</html>', 502);
        }
        return http.Response(
          _ok(creditNote()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        () => repo.createReturn(oneBack),
        throwsA(isA<Exception>()),
      );
      await repo.createReturn(oneBack);

      final posts = sent.where((r) => r.url.path == '/api/v1/returns').toList();
      expect(posts.map((r) => r.headers['Idempotency-Key']).toSet(), hasLength(1));
    });

    test('but a 409 IS a verdict — the next refund is a new one', () async {
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) {
          return http.Response(
            _err('OVER_REFUND', 'คืนเกินจำนวนที่ขาย'),
            409,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          _ok(creditNote()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        () => repo.createReturn(oneBack),
        throwsA(isA<Exception>()),
      );
      await repo.createReturn(oneBack);

      final posts = sent.where((r) => r.url.path == '/api/v1/returns').toList();
      expect(posts.map((r) => r.headers['Idempotency-Key']).toSet(), hasLength(2));
    });
  });

  group('offline: return.create is queued (#452, 08 §6.1)', () {
    late SyncService sync;
    late DocNumberService numbers;
    final period = DocNumberService.formatPeriod(DateTime.now());

    ApiReturnsRepository offlineRepo(
      Future<http.Response> Function(http.Request req) handler,
    ) {
      final client = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient((req) async {
          sent.add(req);
          return handler(req);
        }),
      );
      sync = SyncService(
        db: db,
        apiClient: client,
        tokenStorage: _MemTokenStorage(),
        httpClient: MockClient(
          (_) async => throw http.ClientException('Offline'),
        ),
        autoStartHealthProbe: false,
      );
      addTearDown(sync.dispose);
      numbers = DocNumberService(db: db);
      return ApiReturnsRepository(
        api: client,
        db: db,
        drift: ReturnsRepository(db),
        syncService: sync,
        docNumberService: numbers,
      );
    }

    /// This device (no. 3) is seeded for this period and last issued CN 0004.
    Future<void> seedDevice() async {
      await numbers.recordSeedMarker(deviceId: 'dev-1', period: period);
      await numbers.commitDocNo(
        deviceId: 'dev-1',
        deviceNo: 3,
        docType: 'cn',
        period: period,
        seq: 4,
      );
    }

    Future<void> openShift() => db
        .into(db.shifts)
        .insert(
          ShiftsCompanion.insert(
            id: 'sh-open',
            dateStr: '2026-09-27',
            startingCash: 500,
            openedAt: DateTime(2026, 9, 27, 8),
            isActive: const Value(true),
          ),
        );

    Future<List<OutboxOpRow>> ops() => db.select(db.outboxOps).get();

    Future<int> stock() async => (await (db.select(
      db.products,
    )..where((t) => t.id.equals('tp1'))).getSingle()).stock;

    test(
      'Degraded: the credit note, its reversals, the CN number and one '
      'return.create op are written together, nothing sent online',
      () async {
        final repo = offlineRepo((_) async => fail('no online call'));
        await seedDevice();
        await openShift();
        sync.recordNonVerdictWrite();

        final cn = await repo.createReturn(oneBack);

        expect(sent, isEmpty);
        expect(cn.id, startsWith('r'));
        expect(cn.cnNo, 'CN03-$period-0005');
        expect(cn.receiptNo, 'RC-00042');
        expect(cn.refundTotal, 100);
        expect(await numbers.getLastNo(deviceId: 'dev-1', docType: 'cn'), 5);

        expect(await db.select(db.returns).get(), hasLength(1));
        final line = (await db.select(db.returnItems).get()).single;
        expect(line.returnId, cn.id);
        expect(line.qty, 1);
        expect(await stock(), 4);

        // 100 of a 500 bill: a fifth of its 50 points and ฿100 of spend.
        final c = await (db.select(
          db.customers,
        )..where((t) => t.id.equals('tc1'))).getSingle();
        expect(c.points, 40);
        expect(c.totalSpend, 400);
        // A cash refund never touches the mechanic's tab.
        final m = await (db.select(
          db.mechanics,
        )..where((t) => t.id.equals('tm1'))).getSingle();
        expect(m.creditBalance, 500);

        final sale = await (db.select(
          db.sales,
        )..where((t) => t.id.equals('sale-1'))).getSingle();
        expect(sale.voided, isFalse, reason: '1 of 5 is a partial return');

        final op = (await ops()).single;
        expect(op.type, 'return.create');
        expect(op.status, 'pending');
        expect(jsonDecode(op.aggregates), [
          'return:${cn.id}',
          'sale:sale-1',
          'shift:sh-open',
        ]);
        final payload = jsonDecode(op.payload) as Map<String, dynamic>;
        expect(payload['id'], cn.id);
        expect(payload['saleId'], 'sale-1');
        expect(payload['cnNo'], cn.cnNo);
        expect(payload['date'], isA<String>());
        expect(payload['refundMethod'], 'เงินสด');
        expect(payload['reason'], 'ของชำรุด');
        final item = (payload['items'] as List).single as Map;
        expect(item['productId'], 'tp1');
        expect(item['qty'], 1);
        expect(item['price'], '100.00');
        expect(payload.containsKey('shiftId'), isFalse);
      },
    );

    test('a lost connection queues it under the SAME id + key', () async {
      final repo = offlineRepo(
        (_) async => throw http.ClientException('socket dropped'),
      );
      await seedDevice();
      await openShift();

      final cn = await repo.createReturn(oneBack);

      final online = sent.singleWhere((r) => r.url.path == '/api/v1/returns');
      final op = (await ops()).single;
      expect(op.idempotencyKey, online.headers['Idempotency-Key']);
      expect((jsonDecode(online.body) as Map)['id'], cn.id);
      expect((jsonDecode(op.payload) as Map)['id'], cn.id);
      expect(sync.currentStatus, SyncStatus.degraded);
    });

    test('#489: an online credit note then an offline one → server\'s last + 1', () async {
      final repo = offlineRepo(
        (_) async => http.Response(
          _ok(creditNote()..['cnNo'] = 'CN03-$period-0009'),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );
      await seedDevice();
      await openShift();

      final online = await repo.createReturn(oneBack);
      expect(online.cnNo, 'CN03-$period-0009');
      expect(await numbers.getLastNo(deviceId: 'dev-1', docType: 'cn'), 9);

      sync.recordNonVerdictWrite();
      final offline = await repo.createReturn(oneBack);
      expect(offline.cnNo, 'CN03-$period-0010');
    });

    test('#489: no CN number is committed when the patch transaction fails', () async {
      final repo = offlineRepo(
        (_) async => http.Response(
          _ok(creditNote()..['cnNo'] = 'CN03-$period-0009'),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );
      await seedDevice();
      await db.customStatement(
        'CREATE TRIGGER boom BEFORE INSERT ON movements '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );

      await expectLater(() => repo.createReturn(oneBack), throwsA(anything));
      expect(await db.select(db.returns).get(), isEmpty);
      expect(await numbers.getLastNo(deviceId: 'dev-1', docType: 'cn'), 4);
    });

    test('a full return offline voids the parent bill', () async {
      final repo = offlineRepo((_) async => fail('no online call'));
      await seedDevice();
      await openShift();
      sync.recordNonVerdictWrite();

      await repo.createReturn(
        const ReturnInput(
          saleId: 'sale-1',
          refundMethod: 'โอน',
          items: [
            ReturnLineInput(
              productId: 'tp1',
              name: 'Brake Pad',
              qty: 5,
              price: 100,
            ),
          ],
        ),
      );

      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isTrue);
      expect(await stock(), 8);
    });

    test(
      'over-refund offline: refused, nothing written, no number burnt',
      () async {
        final repo = offlineRepo((_) async => fail('no online call'));
        await seedDevice();
        await openShift();
        sync.recordNonVerdictWrite();

        await expectLater(
          () => repo.createReturn(
            const ReturnInput(
              saleId: 'sale-1',
              refundMethod: 'เงินสด',
              items: [
                ReturnLineInput(
                  productId: 'tp1',
                  name: 'Brake Pad',
                  qty: 6,
                  price: 100,
                ),
              ],
            ),
          ),
          throwsA(
            predicate(
              (e) => e.toString().contains(
                'คืนเกินจำนวนที่ขาย:\nBrake Pad: คืนได้อีก 5 แต่ขอคืน 6',
              ),
            ),
          ),
        );
        expect(await db.select(db.returns).get(), isEmpty);
        expect(await ops(), isEmpty);
        expect(await stock(), 3);
        expect(await numbers.getLastNo(deviceId: 'dev-1', docType: 'cn'), 4);
      },
    );

    test('a cash refund with no open drawer is refused offline', () async {
      final repo = offlineRepo((_) async => fail('no online call'));
      await seedDevice();
      sync.recordNonVerdictWrite();

      await expectLater(
        () => repo.createReturn(oneBack),
        throwsA(
          isA<PosException>().having((e) => e.code, 'code', 'NO_OPEN_SHIFT'),
        ),
      );
      expect(await db.select(db.returns).get(), isEmpty);
      expect(await ops(), isEmpty);
    });

    test('an unseeded device cannot number a credit note offline', () async {
      final repo = offlineRepo((_) async => fail('no online call'));
      await openShift();
      sync.recordNonVerdictWrite();

      await expectLater(
        () => repo.createReturn(oneBack),
        throwsA(isA<OfflineSeedRequiredException>()),
      );
      expect(await db.select(db.returns).get(), isEmpty);
      expect(await ops(), isEmpty);
      expect(await stock(), 3);
    });

    test(
      'seeded but the device number is unknown: refused, never guessed as 01',
      () async {
        final repo = offlineRepo((_) async => fail('no online call'));
        // A new device: seeded, but `GET /doc-counters` had no counter row yet.
        await numbers.recordSeedMarker(deviceId: 'dev-new', period: period);
        await openShift();
        sync.recordNonVerdictWrite();

        await expectLater(
          () => repo.createReturn(oneBack),
          throwsA(isA<OfflineSeedRequiredException>()),
        );
        expect(await db.select(db.returns).get(), isEmpty);
        expect(await ops(), isEmpty);
      },
    );

    test(
      'a re-enrolled browser numbers under its NEW device, not the old one',
      () async {
        final repo = offlineRepo((_) async => fail('no online call'));
        // The old device's counter and seed, then a newer seed for the new one.
        await numbers.commitDocNo(
          deviceId: 'dev-old',
          deviceNo: 1,
          docType: 'cn',
          period: period,
          seq: 40,
        );
        await numbers.recordSeedMarker(
          deviceId: 'dev-old',
          period: period,
          seededAt: DateTime(2026, 1, 1),
        );
        await numbers.commitDocNo(
          deviceId: 'dev-new',
          deviceNo: 7,
          docType: 'receipt',
          period: period,
          seq: 2,
        );
        await numbers.recordSeedMarker(
          deviceId: 'dev-new',
          period: period,
          seededAt: DateTime(2026, 9, 1),
        );
        await openShift();
        sync.recordNonVerdictWrite();

        final cn = await repo.createReturn(oneBack);

        expect(cn.cnNo, 'CN07-$period-0001');
        expect(await numbers.getLastNo(deviceId: 'dev-old', docType: 'cn'), 40);
      },
    );

    test(
      'a 2xx that is not a credit note: UNREADABLE_RESPONSE, nothing queued, '
      'the next press replays the same key (#409)',
      () async {
        final repo = offlineRepo(
          (_) async => http.Response(
            jsonEncode({'status': 'success', 'data': 'not a credit note'}),
            201,
            headers: {'content-type': 'application/json'},
          ),
        );
        await seedDevice();
        await openShift();

        await expectLater(
          () => repo.createReturn(oneBack),
          throwsA(
            isA<PosException>().having(
              (e) => e.code,
              'code',
              'UNREADABLE_RESPONSE',
            ),
          ),
        );
        await expectLater(
          () => repo.createReturn(oneBack),
          throwsA(isA<PosException>()),
        );
        expect(await ops(), isEmpty);
        expect(await db.select(db.returns).get(), isEmpty);
        final keys = sent.map((r) => r.headers['Idempotency-Key']).toSet();
        expect(sent, hasLength(2));
        expect(keys, hasLength(1));
      },
    );

    test('a 5xx does NOT queue (owner 2026-09-27, parity with sales)', () async {
      final repo = offlineRepo(
        (_) async => http.Response('<html>502 Bad Gateway</html>', 502),
      );
      await seedDevice();
      await openShift();

      await expectLater(
        () => repo.createReturn(oneBack),
        throwsA(isA<Exception>()),
      );
      expect(await ops(), isEmpty);
      expect(await db.select(db.returns).get(), isEmpty);
    });

    test(
      'an applied return.create deletes the op and takes the server CN number',
      () async {
        final repo = offlineRepo((_) async => fail('no online call'));
        await seedDevice();
        await openShift();
        sync.recordNonVerdictWrite();
        final cn = await repo.createReturn(oneBack);
        final op = (await ops()).single;

        final pusher = SyncService(
          db: db,
          apiClient: ApiClient(baseUrl: 'http://server.test'),
          tokenStorage: _MemTokenStorage(),
          httpClient: MockClient(
            (req) async => http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'status': 'success',
                  'data': {
                    'results': [
                      {
                        'opId': op.opId,
                        'status': 'applied',
                        'response': {
                          'id': cn.id,
                          'cnNo': 'CN03-$period-0042',
                          'saleId': 'sale-1',
                          'total': '100.00',
                          'refundMethod': 'เงินสด',
                          'stockRestored': [
                            {'id': 'tp1', 'stock': 41},
                          ],
                        },
                      },
                    ],
                  },
                }),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
          autoStartHealthProbe: false,
        );
        addTearDown(pusher.dispose);

        await pusher.push();

        expect(await ops(), isEmpty);
        final local = await (db.select(
          db.returns,
        )..where((t) => t.id.equals(cn.id))).getSingle();
        expect(local.cnNo, 'CN03-$period-0042');
        expect(await stock(), 41);
      },
    );
  });

  test('reads still come from Drift', () async {
    final repo = repoWith((req) async => http.Response('unexpected', 500));
    expect(await repo.getReturns(), isEmpty);
  });

  test('getReturns passes the #417 date bounds through to Drift', () async {
    final repo = repoWith((req) async => http.Response('unexpected', 500));
    await db.into(db.returns).insert(
      ReturnsCompanion.insert(
        id: 'old',
        cnNo: 'CN-old',
        saleId: 's',
        receiptNo: 'RC',
        refundSubtotal: 1,
        refundDiscount: 0,
        refundTotal: 1,
        refundMethod: 'เงินสด',
        date: DateTime(2020, 1, 1),
      ),
    );
    expect(await repo.getReturns(), hasLength(1));
    expect(await repo.getReturns(from: DateTime(2021)), isEmpty);
    expect(await repo.getReturns(to: DateTime(2020)), isEmpty);
  });
}
