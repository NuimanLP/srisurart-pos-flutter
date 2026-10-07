// Pre-release review (2026-10-07): four retry paths that could still write a
// money/stock/customer change twice. Each test reproduces one scenario against
// a MockClient that plays the server, and asserts what the client must send:
// a retry of an attempt whose fate is unknown goes out under the SAME
// `Idempotency-Key` (and body), and a key is never reused for a write the
// server would only replay instead of applying.
//
// 1. Credit payment: the local overpayment check must not run against a
//    parked attempt, and the clerk's overpay consent must not mint a new key.
// 2. Credit payment / addCustomer / addMechanic: the attempt is closed only
//    after the local apply succeeded — a local failure keeps it parked.
// 3. updateCustomer: A (parked) → B (sent, any outcome) → A again must not
//    reuse A's key — a newer edit of a record supersedes its parked edits.
// 4. adjustStock: a delta write is parked like every other money/stock write.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/errors/pos_exception.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_customers_repository.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';

import 'api_customers_repository_test.dart' show InMemoryTokenStorage;

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response _ok(Map<String, dynamic> data) =>
    _json(201, {'status': 'success', 'data': data});

http.Response _error(int status, String code) => _json(status, {
      'status': 'error',
      'error': {'code': code, 'message': 'x'},
    });

class _Sent {
  final keys = <String?>[];
  final bodies = <String>[];
}

void main() {
  late AppDatabase db;
  late _Sent sent;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = _Sent();
    await db.into(db.customers).insert(CustomersCompanion.insert(
          id: 'tc-x',
          code: 'C-1',
          name: 'Before',
          nameTH: 'ก่อน',
          createdAt: '2026-10-06T00:00:00.000Z',
        ));
    await db.into(db.mechanics).insert(MechanicsCompanion.insert(
          id: 'tm-x',
          code: 'M-1',
          name: 'Chang',
          createdAt: '2026-10-06T00:00:00.000Z',
          creditBalance: const Value(500),
        ));
    await db.into(db.shifts).insert(ShiftsCompanion.insert(
          id: 'tsh-open',
          dateStr: '2026-10-06',
          startingCash: 500,
          openedAt: DateTime(2026, 10, 6, 8),
          isActive: const Value(true),
        ));
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: 'p-1',
          partNo: 'ADJ-001',
          name: 'Spark',
          nameTH: 'หัวเทียน',
          category: 'ไฟฟ้า',
          brand: 'NGK',
          price: 100,
          cost: 50,
          stock: 10,
          minStock: 2,
        ));
  });

  tearDown(() async => db.close());

  /// [replies] answers the repository's requests in order; each sees the
  /// request it answers.
  ApiClient clientWith(List<http.Response Function(http.Request)> replies) =>
      ApiClient(
        tokenStorage: InMemoryTokenStorage(),
        httpClient: MockClient((req) async {
          sent.keys.add(req.headers['Idempotency-Key']);
          sent.bodies.add(req.body);
          return replies.removeAt(0)(req);
        }),
      );

  http.Response payment(http.Request req, {Object? id}) {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    return _ok({
      'id': id ?? body['id'],
      'receiptNo': 'CP01-2569-10-0001',
      'mechanicId': 'tm-x',
      'amount': body['amount'],
      'paymentMethod': body['paymentMethod'],
      'date': '2026-10-06T06:00:00.000Z',
      'mechanicCreditBalanceAfter': '0.00',
    });
  }

  http.Response customer(String nameTH, {Object id = 'tc-x'}) => _ok({
        'id': id,
        'code': 'C-1',
        'name': 'Before',
        'nameTH': nameTH,
        'points': 0,
        'totalSpend': '0.00',
        'createdAt': '2026-10-06T00:00:00.000Z',
      });

  Future<void> setBalance(double v) =>
      (db.update(db.mechanics)..where((t) => t.id.equals('tm-x')))
          .write(MechanicsCompanion(creditBalance: Value(v)));

  group('defect 1 — overpayment check vs a parked credit payment', () {
    for (final consent in [false, true]) {
      test('pay ฿500 → 504; a pull drops the balance to 0; the retry '
          '(allowOverpayment: $consent) re-sends the parked attempt — same '
          'key, same body — instead of refusing or minting a second payment',
          () async {
        final api = clientWith([
          (_) => _error(504, 'GATEWAY_TIMEOUT'),
          (req) => payment(req),
        ]);
        final repo = ApiMechanicsRepository(db, api);

        await expectLater(
          repo.addCreditPayment(
              mechanicId: 'tm-x', amount: 500, paymentMethod: 'เงินสด'),
          throwsA(isA<PosException>()),
        );
        // The server committed; the mechanics pull says so.
        await setBalance(0);

        await repo.addCreditPayment(
          mechanicId: 'tm-x',
          amount: 500,
          paymentMethod: 'เงินสด',
          allowOverpayment: consent,
        );
        expect(sent.keys, hasLength(2));
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1),
            reason: 'a key reused with a different body is a 409, not a replay');
      });
    }

    test('a fresh payment over the balance is still refused locally, and the '
        "clerk's consent then sends it", () async {
      final api = clientWith([(req) => payment(req)]);
      final repo = ApiMechanicsRepository(db, api);

      await expectLater(
        repo.addCreditPayment(
            mechanicId: 'tm-x', amount: 600, paymentMethod: 'เงินสด'),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'OVERPAYMENT_NOT_ALLOWED')),
      );
      expect(sent.keys, isEmpty);

      await repo.addCreditPayment(
        mechanicId: 'tm-x',
        amount: 600,
        paymentMethod: 'เงินสด',
        allowOverpayment: true,
      );
      expect((jsonDecode(sent.bodies.single) as Map)['allowOverpayment'], true);
    });
  });

  group('defect 2 — a local apply failure keeps the attempt parked', () {
    test('addCreditPayment', () async {
      final api = clientWith([
        (req) => payment(req, id: 123), // not a String: the local apply throws
        (req) => payment(req),
      ]);
      final repo = ApiMechanicsRepository(db, api);

      await expectLater(
        repo.addCreditPayment(
            mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด'),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
      );
      await repo.addCreditPayment(
          mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด');
      expect(sent.keys.toSet(), hasLength(1));
      expect(sent.bodies.toSet(), hasLength(1));
    });

    test('addCustomer', () async {
      final api = clientWith([
        (_) => customer('น', id: 123),
        (_) => customer('น', id: 'server-id'),
      ]);
      final repo = ApiCustomersRepository(db, api);
      const c = CustomersCompanion(name: Value('N'), nameTH: Value('น'));

      await expectLater(repo.addCustomer(c), throwsA(isA<PosException>()));
      await repo.addCustomer(c);
      expect(sent.keys.toSet(), hasLength(1));
      expect(sent.bodies.toSet(), hasLength(1));
    });

    test('addMechanic', () async {
      final api = clientWith([
        (_) => _ok({'id': 123, 'code': 'M-2', 'name': 'Somchai'}),
        (_) => _ok({'id': 'tm-new', 'code': 'M-2', 'name': 'Somchai'}),
      ]);
      final repo = ApiMechanicsRepository(db, api);
      const m = MechanicsCompanion(name: Value('Somchai'));

      await expectLater(repo.addMechanic(m), throwsA(anything));
      await repo.addMechanic(m);
      expect(sent.keys.toSet(), hasLength(1));
    });
  });

  test('defect 3 — updateCustomer: edit A 5xx (parked), edit B succeeds, edit '
      "back to A is a NEW key, not a replay of A's stale reply", () async {
    final api = clientWith([
      (_) => _error(502, 'BAD_GATEWAY'),
      (_) => customer('B'),
      (_) => customer('A'),
    ]);
    final repo = ApiCustomersRepository(db, api);
    const a = CustomersCompanion(nameTH: Value('A'));
    const b = CustomersCompanion(nameTH: Value('B'));

    await expectLater(repo.updateCustomer('tc-x', a), throwsA(isA<PosException>()));
    await repo.updateCustomer('tc-x', b);
    await repo.updateCustomer('tc-x', a);

    expect(sent.keys, hasLength(3));
    expect(sent.keys.toSet(), hasLength(3));
  });

  test('defect 3 — updateCustomer: edit A 5xx, edit B 5xx (both parked), '
      "edit back to A is a NEW key — B superseded A when it was sent", () async {
    final api = clientWith([
      (_) => _error(502, 'BAD_GATEWAY'),
      (_) => _error(502, 'BAD_GATEWAY'),
      (_) => customer('A'),
    ]);
    final repo = ApiCustomersRepository(db, api);
    const a = CustomersCompanion(nameTH: Value('A'));
    const b = CustomersCompanion(nameTH: Value('B'));

    await expectLater(repo.updateCustomer('tc-x', a), throwsA(isA<PosException>()));
    await expectLater(repo.updateCustomer('tc-x', b), throwsA(isA<PosException>()));
    await repo.updateCustomer('tc-x', a);

    expect(sent.keys, hasLength(3));
    expect(sent.keys.toSet(), hasLength(3));
  });

  test('defect 3 — updateCustomer: an edit of ANOTHER customer does not '
      'supersede a parked edit', () async {
    await db.into(db.customers).insert(CustomersCompanion.insert(
          id: 'tc-y',
          code: 'C-2',
          name: 'Other',
          nameTH: 'อื่น',
          createdAt: '2026-10-06T00:00:00.000Z',
        ));
    final api = clientWith([
      (_) => _error(502, 'BAD_GATEWAY'),
      (_) => customer('B', id: 'tc-y'),
      (_) => customer('A'),
    ]);
    final repo = ApiCustomersRepository(db, api);
    const a = CustomersCompanion(nameTH: Value('A'));
    const b = CustomersCompanion(nameTH: Value('B'));

    await expectLater(repo.updateCustomer('tc-x', a), throwsA(isA<PosException>()));
    await repo.updateCustomer('tc-y', b);
    await repo.updateCustomer('tc-x', a);

    expect(sent.keys[2], sent.keys[0]);
  });

  group('defect 4 — adjustStock is parked like every other stock write', () {
    http.Response adjusted(int stockAfter) =>
        _ok({'id': 'p-1', 'stockAfter': stockAfter});

    for (final (label, reply) in [
      ('504', () => _error(504, 'GATEWAY_TIMEOUT')),
      ('429', () => _error(429, 'RATE_LIMITED')),
      ('503 IN_FLIGHT', () => _error(503, 'IDEMPOTENCY_KEY_IN_FLIGHT')),
    ]) {
      test('$label → the retry goes out under the same key + body', () async {
        final api = clientWith([(_) => reply(), (_) => adjusted(15)]);
        final repo = ApiProductsRepository(db, api);

        await expectLater(
          repo.adjustStock('p-1', 5, 'manual', 'นับสต็อก'),
          throwsA(isA<PosException>()),
        );
        await repo.adjustStock('p-1', 5, 'manual', 'นับสต็อก');
        expect(sent.keys, hasLength(2));
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1));
      });
    }

    test('a transport failure keeps the attempt parked (fate unknown)',
        () async {
      final api = clientWith([
        (_) => throw http.ClientException('reset'),
        (_) => adjusted(15),
      ]);
      final repo = ApiProductsRepository(db, api);

      await expectLater(
        repo.adjustStock('p-1', 5, 'manual', null),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'NETWORK_ERROR')),
      );
      await repo.adjustStock('p-1', 5, 'manual', null);
      expect(sent.keys.toSet(), hasLength(1));
    });

    test('a 2xx that is not an adjustment is UNREADABLE_RESPONSE and stays '
        'parked', () async {
      final api = clientWith([
        (_) => _json(200, {'status': 'success', 'data': ['not-an-adjustment']}),
        (_) => adjusted(15),
      ]);
      final repo = ApiProductsRepository(db, api);

      await expectLater(
        repo.adjustStock('p-1', 5, 'manual', null),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')),
      );
      final row = await (db.select(db.products)
            ..where((t) => t.id.equals('p-1')))
          .getSingle();
      expect(row.stock, 10);
      await repo.adjustStock('p-1', 5, 'manual', null);
      expect(sent.keys.toSet(), hasLength(1));
    });

    test('a 2xx closes the attempt: the same adjustment again is a new key',
        () async {
      final api =
          clientWith([(_) => adjusted(15), (_) => adjusted(20)]);
      final repo = ApiProductsRepository(db, api);

      await repo.adjustStock('p-1', 5, 'manual', null);
      await repo.adjustStock('p-1', 5, 'manual', null);
      expect(sent.keys.toSet(), hasLength(2));
    });

    test('a 4xx verdict closes the attempt: the next press is a new key',
        () async {
      final api = clientWith([
        (_) => _error(409, 'STOCK_CONFLICT'),
        (_) => adjusted(15),
      ]);
      final repo = ApiProductsRepository(db, api);

      await expectLater(repo.adjustStock('p-1', 5, 'manual', null),
          throwsA(isA<PosException>()));
      await repo.adjustStock('p-1', 5, 'manual', null);
      expect(sent.keys.toSet(), hasLength(2));
    });
  });
}
