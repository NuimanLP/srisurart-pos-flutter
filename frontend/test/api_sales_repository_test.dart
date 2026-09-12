// ApiSalesRepository (#56) — the server owns the numbers, Drift only remembers them.
//
// Every assertion here is written so that it FAILS if the client computed
// anything itself. The mock deliberately answers with figures the client's own
// arithmetic could never produce (stock 3 after selling 2 from 10, 7 points on a
// ฿200 bill where `floor(total/10)` is 20), so a repository that quietly fell
// back to `saveSale`'s local maths would be caught rather than congratulated.

import 'dart:convert';

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
  SaleInput input({String paymentMethod = 'เงินสด'}) => SaleInput(
    subtotal: 200,
    discount: 0,
    total: 200,
    paymentMethod: paymentMethod,
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
  };

  test(
    'AC1 — every patched number is the SERVER\'s, never the client\'s arithmetic',
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
      // Not in CreateSaleResult — left null rather than invented.
      expect(sales.single.shiftId, isNull);

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

      // ── Lines, and the two tables the response cannot fill ──
      final lines = await db.select(db.saleItems).get();
      expect(lines, hasLength(1));
      expect(lines.single.saleId, 's-server');
      expect(lines.single.qty, 2);
      expect(
        lines.single.costAtSale,
        isNull,
        reason: 'no cost in the response; local products.cost would be a guess',
      );
      expect(
        await db.select(db.movements).get(),
        isEmpty,
        reason: 'movements are not in the response and must not be synthesised',
      );

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
    'AC3 — a 409 INSUFFICIENT_STOCK shows all three lines and writes nothing',
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
    'AC4 — a 403 DEVICE_ROLE_FORBIDDEN surfaces เครื่องนี้ขายของไม่ได้',
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
    'AC7 — what reaches the screen is a plain Exception, never an ApiException',
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

  group('the credit-limit override (#56 tension — see the report)', () {
    test(
      'resends once with overrideCreditLimit and the SAME key when the counter '
      'must already have confirmed',
      () async {
        // Local cache: balance 4900 + a 200 bill > limit 5000, so
        // `checkout_screen.dart:561` showed its dialog and staff pressed ยืนยัน.
        await (db.update(db.mechanics)..where((t) => t.id.equals('tm1'))).write(
          const MechanicsCompanion(creditBalance: Value(4900)),
        );

        final bodies = <Map<String, dynamic>>[];
        final repo = repoWith((req) async {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (bodies.length == 1) {
            return http.Response(
              _err('CREDIT_LIMIT_EXCEEDED', 'Credit limit exceeded'),
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

        final sale = await repo.saveSale(input(paymentMethod: 'เครดิตช่าง'));

        expect(bodies, hasLength(2));
        expect(bodies[0].containsKey('overrideCreditLimit'), isFalse);
        expect(bodies[1]['overrideCreditLimit'], isTrue);
        expect(bodies[0]['id'], bodies[1]['id']);
        final posts = sent.where((r) => r.url.path == '/api/v1/sales');
        expect(
          posts.map((r) => r.headers['Idempotency-Key']).toSet(),
          hasLength(1),
          reason: 'the refused transaction rolls its idempotency claim back',
        );
        expect(sale.receiptNo, 'RC-00042');
        expect(await db.select(db.sales).get(), hasLength(1));
      },
    );

    test(
      'refuses when only the SERVER thinks the bill is over the limit — no human '
      'was ever asked',
      () async {
        // Local cache says 0 + 200 <= 5000, so no dialog was shown.
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

        expect(calls, 1, reason: 'no silent override');
        expect(
          thrown.toString().replaceFirst('Exception: ', ''),
          'เกินวงเงินเครดิต',
        );
        expect(await db.select(db.sales).get(), isEmpty);
      },
    );
  });

  test('reads still come from Drift', () async {
    final repo = repoWith((req) async => http.Response('unexpected', 500));
    expect(await repo.getSales(), isEmpty);
    expect(await repo.getRefundedQty('nope'), isEmpty);
  });
}
