// ApiSalesRepository (#56) — the server owns the numbers, Drift only remembers them.
//
// Every assertion here is written so that it FAILS if the client computed
// anything itself. The mock deliberately answers with figures the client's own
// arithmetic could never produce (stock 3 after selling 2 from 10, 7 points on a
// ฿200 bill where `floor(total/10)` is 20), so a repository that quietly fell
// back to `saveSale`'s local maths would be caught rather than congratulated.

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
import 'package:srisurart_pos/data/repositories/api/api_sales_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class _MemoryTokenStorage implements TokenStorage {
  String? accessToken = 'access-1';
  String? refreshToken = 'refresh-1';
  String? deviceToken;
  AuthUser? user;

  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<void> setAccessToken(String? t) async => accessToken = t;
  @override
  Future<String?> getRefreshToken() async => refreshToken;
  @override
  Future<void> setRefreshToken(String? t) async => refreshToken = t;
  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<void> setDeviceToken(String? t) async => deviceToken = t;
  @override
  Future<AuthUser?> getUser() async => user;
  @override
  Future<void> setUser(AuthUser? u) async => user = u;
  @override
  Future<void> clearAuthTokens() async {
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<void> clearAll() async => clearAuthTokens();
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

  /// Rebuilds the repository around a mock that answers `/sales` with [handler].
  /// The refresh endpoint always succeeds, so `ApiClient`'s 401 path is available
  /// to any test that wants it.
  ApiSalesRepository repoWith(
    Future<http.Response> Function(http.Request req) handler,
  ) {
    final client = MockClient((req) async {
      sent.add(req);
      if (req.url.path.endsWith('/auth/refresh')) {
        return http.Response(
          jsonEncode({'accessToken': 'access-2', 'refreshToken': 'refresh-2'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return handler(req);
    });
    return ApiSalesRepository(
      api: ApiClient(
        baseUrl: 'http://server.test',
        httpClient: client,
        tokenStorage: _MemoryTokenStorage(),
      ),
      db: db,
      drift: SalesRepository(db),
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    // A clean, known world — the seed rows are left alone and never touched.
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
            stock: 10,
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
            points: const Value(0),
            totalSpend: const Value(0),
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
            creditBalance: const Value(0),
          ),
        );
  });

  tearDown(() async => db.close());

  /// Two pads at ฿100 — the client's own arithmetic would be stock 8,
  /// points 20, spend 200, credit 200. The mock answers none of those.
  SaleInput input({
    String paymentMethod = 'เงินสด',
    bool overrideCreditLimit = false,
    double total = 200,
  }) => SaleInput(
    subtotal: 200,
    discount: 0,
    total: total,
    paymentMethod: paymentMethod,
    overrideCreditLimit: overrideCreditLimit,
    customerId: 'tc1',
    customerName: 'สมชาย',
    mechanicId: 'tm1',
    mechanicName: 'ช่างเอ',
    mechanicDelta: -15,
    items: const [
      SaleLineInput(
        productId: 'tp1',
        name: 'Brake Pad',
        qty: 2,
        price: 100,
        partNo: 'TP-1',
        nameTH: 'ผ้าเบรก',
      ),
    ],
  );

  Map<String, dynamic> created({String id = 's-server'}) => {
    'id': id,
    'receiptNo': 'RC-00042',
    'total': '200.00',
    // 7, not floor(200/10) = 20.
    'pointsGranted': 7,
    'date': '2026-09-12T03:00:00.000Z',
    // 3, not 10 - 2 = 8.
    'products': [
      {'id': 'tp1', 'stock': 3},
    ],
    'mechanicCreditBalanceAfter': '1234.50',
    'customerAfter': {'id': 'tc1', 'points': 41, 'totalSpend': '999.50'},
    // ── #82's four new fields ──
    // The drawer the server filed the bill under; this device has no shift open
    // at all, so nothing local could have produced it.
    'shiftId': 'shift-server-9',
    // 58.25, not the local `products.cost` of 60.
    'items': [
      {'lineNo': 1, 'productId': 'tp1', 'costAtSale': '58.25'},
    ],
    // stockAfter 3 again — the same number no local `10 - 2` can reach.
    'movements': [
      {
        'id': 'mv-server-1',
        'productId': 'tp1',
        'partNo': 'TP-1',
        'name': 'Brake Pad',
        'delta': -2,
        'type': 'sale',
        'note': 'RC-00042',
        'stockAfter': 3,
        'date': '2026-09-12T03:00:00.000Z',
      },
    ],
    // All four totals, none of them reachable from a ฿200 bill with a -15
    // mechanic delta: the client would say 200 / 15 / 0.
    'mechanicAfter': {
      'id': 'tm1',
      'totalSales': '4321.00',
      'totalDiscount': '77.25',
      'totalMarkup': '13.75',
      'creditBalance': '1234.50',
    },
  };

  /// The same bill as answered by a server that has not shipped #82 yet: no
  /// `shiftId`, no `items`, no `movements`, no `mechanicAfter`.
  Map<String, dynamic> createdPre82() => created()
    ..remove('shiftId')
    ..remove('items')
    ..remove('movements')
    ..remove('mechanicAfter');

  test(
    'AC3 — every patched number is the SERVER\'s, never the client\'s arithmetic',
    () async {
      late Map<String, dynamic> body;
      final repo = repoWith((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final sale = await repo.saveSale(input());

      // ── The bill the screen prints ──
      final sales = await db.select(db.sales).get();
      expect(sales, hasLength(1));
      expect(sale.id, 's-server');
      expect(sale.receiptNo, 'RC-00042');
      expect(sale.total, 200);
      expect(sale.pointsGranted, 7); // server's, not 20
      expect(sale.date, DateTime.parse('2026-09-12T03:00:00.000Z').toLocal());
      expect(sales.single.receiptNo, 'RC-00042');
      expect(sales.single.pointsGranted, 7);
      // #82: the drawer the SERVER filed it under. No shift is open on this
      // device, so a locally-chosen value could only have been null.
      expect(sale.shiftId, 'shift-server-9');
      expect(sales.single.shiftId, 'shift-server-9');

      // ── The cache ──
      final p = await (db.select(
        db.products,
      )..where((t) => t.id.equals('tp1'))).getSingle();
      expect(p.stock, 3, reason: 'server value; local maths would give 8');
      // Not stamped locally: `updatedAt` is #55's sync cursor and the response
      // carries none.
      expect(p.updatedAt, isNull);

      final c = await (db.select(
        db.customers,
      )..where((t) => t.id.equals('tc1'))).getSingle();
      expect(c.points, 41); // not 0 + 20
      expect(c.totalSpend, 999.5); // not 0 + 200

      final m = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('tm1'))).getSingle();
      expect(m.creditBalance, 1234.5); // not 0 (cash bill) and not 0 + 200
      // #82: all four running totals, not just the balance. None of these is
      // reachable from this cart — the client's own sums would be 200 / 15 / 0.
      expect(m.totalSales, 4321);
      expect(m.totalDiscount, 77.25);
      expect(m.totalMarkup, 13.75);
      // 🔴 The legacy alias of totalDiscount (#11): the server never writes it,
      // so neither may the client.
      expect(m.totalCredit, 0);

      // ── Lines and the stock log ──
      final lines = await db.select(db.saleItems).get();
      expect(lines, hasLength(1));
      expect(lines.single.saleId, 's-server');
      expect(lines.single.qty, 2);
      expect(
        lines.single.costAtSale,
        58.25,
        reason: "the server's locked cost; local products.cost is 60",
      );

      final mv = await db.select(db.movements).get();
      expect(mv, hasLength(1));
      expect(mv.single.id, 'mv-server-1'); // the server's row id, not newId('mv')
      expect(mv.single.type, 'sale');
      expect(mv.single.delta, -2);
      expect(mv.single.stockAfter, 3, reason: 'server value; local maths says 8');
      expect(mv.single.note, 'RC-00042');
      expect(mv.single.date, DateTime.parse('2026-09-12T03:00:00.000Z').toLocal());

      // ── The wire ──
      expect(body['id'], startsWith('s'));
      expect(body['subtotal'], '200.00');
      expect(body['total'], '200.00');
      expect(body['mechanicDelta'], '-15.00');
      expect(body['items'], hasLength(1));
      expect((body['items'] as List).single['lineNo'], 1);
      expect((body['items'] as List).single['price'], '100.00');
      // Server-owned fields the client must never claim.
      expect(body.containsKey('receiptNo'), isFalse);
      expect(body.containsKey('shiftId'), isFalse);
    },
  );

  test(
    '#82 — costAtSale is joined on lineNo, so the same product twice keeps two costs',
    () async {
      // The case a `productId` join silently corrupts: one bill, the same part
      // on two lines, sold at two prices and (because the shop received stock
      // between them) recorded at two costs. Joining on productId would hand
      // both lines whichever entry it read last — 71.50 here — and the bill's
      // profit would be wrong in a way no screen could show.
      const twoLines = SaleInput(
        subtotal: 180,
        discount: 0,
        total: 180,
        paymentMethod: 'เงินสด',
        items: [
          SaleLineInput(
            productId: 'tp1',
            name: 'Brake Pad',
            qty: 1,
            price: 100,
            partNo: 'TP-1',
            nameTH: 'ผ้าเบรก',
          ),
          SaleLineInput(
            productId: 'tp1',
            name: 'Brake Pad',
            qty: 1,
            price: 80,
            partNo: 'TP-1',
            nameTH: 'ผ้าเบรก',
          ),
        ],
      );

      late Map<String, dynamic> body;
      final repo = repoWith((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          _ok(
            created()
              ..['total'] = '180.00'
              // Out of order on purpose: the join must use lineNo, not the
              // order the list happens to arrive in either.
              ..['items'] = [
                {'lineNo': 2, 'productId': 'tp1', 'costAtSale': '71.50'},
                {'lineNo': 1, 'productId': 'tp1', 'costAtSale': '58.25'},
              ],
          ),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await repo.saveSale(twoLines);

      // The lineNo the client sent is the join key, so pin it on the wire too.
      final wireLines = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(wireLines.map((l) => l['lineNo']), [1, 2]);
      expect(wireLines.map((l) => l['price']), ['100.00', '80.00']);

      final lines =
          await (db.select(db.saleItems)
                ..orderBy([(t) => OrderingTerm.asc(t.rowId)]))
              .get();
      expect(lines, hasLength(2));
      expect(lines[0].price, 100);
      expect(lines[0].costAtSale, 58.25);
      expect(lines[1].price, 80);
      expect(
        lines[1].costAtSale,
        71.5,
        reason: 'a productId join would have given this line 58.25 or 71.50 twice',
      );
    },
  );

  test(
    '#82 — a response WITHOUT the new fields leaves those rows stale and does not throw',
    () async {
      // A server that has not shipped #82 yet. Absent must mean "stale", never
      // "compute it here" (ADR-0010 §3) — and it must certainly not put an
      // exception in front of the counter.
      await (db.update(db.mechanics)..where((t) => t.id.equals('tm1'))).write(
        const MechanicsCompanion(
          totalSales: Value(11.11),
          totalDiscount: Value(22.22),
          totalMarkup: Value(33.33),
        ),
      );

      final repo = repoWith(
        (req) async => http.Response(
          _ok(createdPre82()),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );

      final sale = await repo.saveSale(input());

      // The bill itself still lands, with everything the old response does carry.
      expect(sale.receiptNo, 'RC-00042');
      expect(sale.pointsGranted, 7);
      expect(sale.shiftId, isNull, reason: 'unknown here, not guessed locally');

      expect(
        (await db.select(db.saleItems).get()).single.costAtSale,
        isNull,
        reason: 'no cost in the response; local products.cost would be a guess',
      );
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
      // The legacy field still comes back and is still honoured.
      expect(m.creditBalance, 1234.5);
    },
  );

  test(
    'AC2 — one Idempotency-Key survives ApiClient\'s 401 refresh retry',
    () async {
      var attempts = 0;
      final repo = repoWith((req) async {
        attempts++;
        if (attempts == 1) {
          return http.Response(
            _err('UNAUTHENTICATED', 'token expired'),
            401,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await repo.saveSale(input());

      final salePosts = sent
          .where((r) => r.url.path == '/api/v1/sales')
          .toList();
      expect(salePosts, hasLength(2), reason: '401 → refresh → retry');
      final keys = salePosts.map((r) => r.headers['Idempotency-Key']).toSet();
      expect(keys, hasLength(1));
      expect(keys.single, isNotNull);
      // The bill's own id is the server's second idempotency key — same too.
      final ids = salePosts
          .map((r) => (jsonDecode(r.body) as Map)['id'])
          .toSet();
      expect(ids, hasLength(1));

      expect(await db.select(db.sales).get(), hasLength(1));
    },
  );

  test(
    'AC4 — a 409 INSUFFICIENT_STOCK shows all three lines and writes nothing',
    () async {
      const thai =
          'สต็อกไม่พอ:\n'
          'ผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1\n'
          'กรองน้ำมัน: สต็อก 2 แต่ต้องการ 5\n'
          'หัวเทียน: ไม่พบในสต็อก';
      final repo = repoWith(
        (req) async => http.Response(
          _err('INSUFFICIENT_STOCK', thai),
          409,
          headers: {'content-type': 'application/json'},
        ),
      );

      Object? thrown;
      try {
        await repo.saveSale(input());
      } catch (e) {
        thrown = e;
      }

      final msg = thrown.toString().replaceFirst('Exception: ', '');
      expect(msg, thai);
      expect(msg.split('\n'), hasLength(4));
      expect(msg, contains('ผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1'));
      expect(msg, contains('กรองน้ำมัน: สต็อก 2 แต่ต้องการ 5'));
      expect(msg, contains('หัวเทียน: ไม่พบในสต็อก'));

      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.saleItems).get(), isEmpty);
      final p = await (db.select(
        db.products,
      )..where((t) => t.id.equals('tp1'))).getSingle();
      expect(p.stock, 10, reason: 'nothing may be patched on a refusal');
    },
  );

  test(
    'AC7 — a 403 DEVICE_ROLE_FORBIDDEN surfaces เครื่องนี้ขายของไม่ได้',
    () async {
      final repo = repoWith(
        (req) async => http.Response(
          // Exactly what `DeviceRoleForbiddenException` renders.
          _err('DEVICE_ROLE_FORBIDDEN', 'เครื่องนี้ขายของไม่ได้'),
          403,
          headers: {'content-type': 'application/json'},
        ),
      );

      Object? thrown;
      try {
        await repo.saveSale(input());
      } catch (e) {
        thrown = e;
      }
      expect(
        thrown.toString().replaceFirst('Exception: ', ''),
        'เครื่องนี้ขายของไม่ได้',
      );
    },
  );

  test(
    'what reaches the screen is a plain Exception, never an ApiException',
    () async {
      final repo = repoWith(
        (req) async => http.Response(
          _err('TOTAL_MISMATCH', 'totals do not add up'),
          409,
          headers: {'content-type': 'application/json'},
        ),
      );

      Object? thrown;
      try {
        await repo.saveSale(input());
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<Exception>());
      expect(thrown, isNot(isA<ApiException>()));
      final msg = thrown.toString().replaceFirst('Exception: ', '');
      // The screens render exactly this string; an ApiException would have put
      // `ApiException(status: 409, code: …)` on the counter's screen.
      expect(msg, 'ยอดเงินไม่ตรงกัน กรุณาทำรายการใหม่');
      expect(msg, isNot(contains('ApiException')));
    },
  );

  group('a lost reply must not become a second bill (AC2)', () {
    test(
      'a dropped connection then a second press replays the SAME bill id and key',
      () async {
        // The shape the shop actually hits: the server commits the bill, the
        // reply is lost on the way back, the counter sees the failure and
        // presses ยืนยัน again on the same cart. The second press must be the
        // same bill, or `existingSale` and `idempotency_keys` both see a new
        // request and the customer is charged twice.
        var attempt = 0;
        final repo = repoWith((req) async {
          attempt++;
          if (attempt == 1) throw const SocketException('connection closed');
          return http.Response(
            _ok(created()),
            201,
            headers: {'content-type': 'application/json'},
          );
        });

        final cart = input();
        await expectLater(() => repo.saveSale(cart), throwsA(isA<SocketException>()));

        // A brand-new SaleInput, as `checkout_screen.dart` builds on every press.
        final sale = await repo.saveSale(input());

        final posts = sent.where((r) => r.url.path == '/api/v1/sales').toList();
        expect(posts, hasLength(2));
        expect(
          posts.map((r) => r.headers['Idempotency-Key']).toSet(),
          hasLength(1),
          reason: 'a fresh key would defeat the server idempotency module',
        );
        expect(
          posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
          hasLength(1),
          reason: "a fresh bill id would defeat the server's existingSale check",
        );
        expect(sale.receiptNo, 'RC-00042');
        expect(await db.select(db.sales).get(), hasLength(1));
      },
    );

    test('but a server VERDICT closes the attempt — the next bill is a new one', () async {
      // A 409 is an answer: nothing was committed, and the next press is a
      // different sale that must not inherit the refused bill's id.
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) {
          return http.Response(
            _err('INSUFFICIENT_STOCK', 'สต็อกไม่พอ:\nBrake Pad: สต็อก 1 แต่ต้องการ 2'),
            409,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(() => repo.saveSale(input()), throwsA(isA<Exception>()));
      await repo.saveSale(input());

      final posts = sent.where((r) => r.url.path == '/api/v1/sales').toList();
      expect(posts, hasLength(2));
      expect(
        posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
        hasLength(2),
        reason: 'the refused bill was never written; this is a different sale',
      );
    });

    test('a 504 from the proxy is NOT a verdict — the retry replays the bill', () async {
      // The likeliest real shape of a lost reply. `ApiClient` sets no timeout,
      // so what actually fires first is nginx's own `proxy_read_timeout`, and
      // that arrives as an ordinary `ApiException` — not the `SocketException`
      // the test above uses. Treating every `ApiException` as a verdict is how
      // a committed bill gets rung up a second time.
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) {
          return http.Response('<html>504 Gateway Time-out</html>', 504);
        }
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(() => repo.saveSale(input()), throwsA(isA<Exception>()));
      await repo.saveSale(input());

      final posts = sent.where((r) => r.url.path == '/api/v1/sales').toList();
      expect(posts, hasLength(2));
      expect(posts.map((r) => r.headers['Idempotency-Key']).toSet(), hasLength(1));
      expect(
        posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
        hasLength(1),
        reason: 'a 5xx leaves the fate of the bill unknown; reuse the id',
      );
      expect(await db.select(db.sales).get(), hasLength(1));
    });

    test('503 IDEMPOTENCY_KEY_IN_FLIGHT keeps the attempt parked', () async {
      // The one reply that says in so many words "the original is still
      // running; retrying later is right, executing now is not"
      // (`idempotency.service.ts`). Closing the attempt on it is the worst
      // possible reading of the clearest possible message.
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) {
          return http.Response(
            _err('IDEMPOTENCY_KEY_IN_FLIGHT', 'the original request is running'),
            503,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(() => repo.saveSale(input()), throwsA(isA<Exception>()));
      await repo.saveSale(input());

      final posts = sent.where((r) => r.url.path == '/api/v1/sales').toList();
      expect(posts.map((r) => r.headers['Idempotency-Key']).toSet(), hasLength(1));
      expect(
        posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
        hasLength(1),
      );
    });

    test('a patch that throws leaves the attempt parked', () async {
      // The server committed and answered; only the local write-through failed
      // — here because the reply is missing `receiptNo`, the shape a version
      // skew produces. The counter still reads ขายไม่สำเร็จ and still presses
      // again, so the attempt is exactly as unresolved as a lost socket.
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        return http.Response(
          _ok(attempt == 1 ? (created()..remove('receiptNo')) : created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(() => repo.saveSale(input()), throwsA(anything));
      final sale = await repo.saveSale(input());

      final posts = sent.where((r) => r.url.path == '/api/v1/sales').toList();
      expect(posts, hasLength(2));
      expect(
        posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
        hasLength(1),
        reason: 'a second id here is a second bill for goods that left once',
      );
      expect(posts.map((r) => r.headers['Idempotency-Key']).toSet(), hasLength(1));
      expect(sale.receiptNo, 'RC-00042');
      expect(await db.select(db.sales).get(), hasLength(1));
    });

    test('a different cart never replays a parked attempt', () async {
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        if (attempt == 1) throw const SocketException('connection closed');
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(() => repo.saveSale(input()), throwsA(isA<SocketException>()));
      await repo.saveSale(input(total: 350));

      final posts = sent.where((r) => r.url.path == '/api/v1/sales').toList();
      expect(
        posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet(),
        hasLength(2),
      );
      expect(
        posts.map((r) => r.headers['Idempotency-Key']).toSet(),
        hasLength(2),
      );
    });
  });

  group('the credit limit', () {
    test(
      'the counter\'s confirmation is CARRIED, not re-derived from the cache',
      () async {
        // The mechanic is deep over his limit in the local cache. That must not
        // be what decides the override: the screen tests the MechanicRow it
        // captured when its list loaded, this row is the live one, and the two
        // drift apart (a prior bill on the same screen already patches it). If
        // the repository re-derived consent from this row, the 409 below would
        // be retried with the flag and the server would log an override the
        // counter was never shown a dialog for.
        await (db.update(db.mechanics)..where((t) => t.id.equals('tm1'))).write(
          const MechanicsCompanion(creditBalance: Value(4900)),
        );

        var calls = 0;
        final repo = repoWith((req) async {
          calls++;
          return http.Response(
            _err('CREDIT_LIMIT_EXCEEDED', 'Credit limit exceeded'),
            409,
            headers: {'content-type': 'application/json'},
          );
        });

        Object? thrown;
        try {
          await repo.saveSale(input(paymentMethod: 'เครดิตช่าง'));
        } catch (e) {
          thrown = e;
        }

        expect(calls, 1, reason: 'no second POST — consent was never given');
        expect(
          thrown.toString().replaceFirst('Exception: ', ''),
          'เกินวงเงินเครดิต',
        );
        expect(await db.select(db.sales).get(), isEmpty);
      },
    );

    test('overrideCreditLimit travels in the body when the input carries it', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = repoWith((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await repo.saveSale(
        input(paymentMethod: 'เครดิตช่าง', overrideCreditLimit: true),
      );

      expect(bodies, hasLength(1));
      expect(bodies.single['overrideCreditLimit'], isTrue);
    });

    test('and defaults to false, so an unconfirmed bill cannot carry it', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = repoWith((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          _ok(created()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      await repo.saveSale(input(paymentMethod: 'เครดิตช่าง'));

      expect(bodies.single['overrideCreditLimit'], isFalse);
    });
  });

  test('reads still come from Drift', () async {
    final repo = repoWith((req) async => http.Response('unexpected', 500));
    expect(await repo.getSales(), isEmpty);
    expect(await repo.getRefundedQty('nope'), isEmpty);
  });
}
