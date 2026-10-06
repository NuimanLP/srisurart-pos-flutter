// 08 §5 (owner, 2026-09-27, #452) for the customer and credit-payment writes:
// only a TRANSPORT failure (timeout, dropped socket) queues to the outbox under
// the same id + key. A 5xx / 429 / 503 IDEMPOTENCY_KEY_IN_FLIGHT is not a
// verdict — the write may be committed — so it is never queued. Exactly as on
// ApiSalesRepository: the link is NOT marked Degraded (that would send the next
// press to the outbox), the attempt stays parked (same id + key + body), and the
// counter reads the converted sentence. The next press re-sends online under the
// same id + key + body, and the server replays.

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
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';

import 'api_customers_repository_test.dart' show InMemoryTokenStorage;

const _connection = 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์';

http.Response _error(int status, String code) => http.Response(
      jsonEncode({
        'status': 'error',
        'error': {'code': code, 'message': 'x'},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Non-verdict replies, with the sentence the counter reads for each
/// (`resolveCounterError`).
final _nonVerdicts = <String, (http.Response Function(), String)>{
  '502': (() => _error(502, 'BAD_GATEWAY'), _connection),
  '429': (
    () => _error(429, 'RATE_LIMITED'),
    'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
  ),
  // Owner 2026-10-06: the in-flight "wait" sentence, not the connection one.
  '503 IN_FLIGHT': (
    () => _error(503, 'IDEMPOTENCY_KEY_IN_FLIGHT'),
    'คำขอก่อนหน้ากำลังดำเนินการ กรุณารอสักครู่',
  ),
};

class _Sent {
  final keys = <String?>[];
  final bodies = <String>[];
  void add(http.Request r) {
    keys.add(r.headers['Idempotency-Key']);
    bodies.add(r.body);
  }
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
          creditBalance: const Value(2000),
        ));
    await db.into(db.shifts).insert(ShiftsCompanion.insert(
          id: 'tsh-open',
          dateStr: '2026-10-06',
          startingCash: 500,
          openedAt: DateTime(2026, 10, 6, 8),
          isActive: const Value(true),
        ));
  });

  tearDown(() async => db.close());

  /// [replies] answers the repository's requests in order.
  ApiClient clientWith(List<Future<http.Response> Function()> replies) =>
      ApiClient(
        tokenStorage: InMemoryTokenStorage(),
        httpClient: MockClient((req) async {
          sent.add(req);
          return replies.removeAt(0)();
        }),
      );

  SyncService syncWith(ApiClient api) {
    final sync = SyncService(
      db: db,
      apiClient: api,
      tokenStorage: InMemoryTokenStorage(),
      // /sync/push never gets through in these tests.
      httpClient: MockClient((_) async => throw http.ClientException('down')),
      autoStartHealthProbe: false,
    );
    addTearDown(sync.dispose);
    return sync;
  }

  Future<List<OutboxOpRow>> outbox() => db.select(db.outboxOps).get();

  http.Response customer(String id) => http.Response(
        jsonEncode({
          'status': 'success',
          'data': {
            'id': id,
            'code': 'CUS1',
            'name': 'N',
            'nameTH': 'น',
            'points': 0,
            'totalSpend': '0.00',
            'createdAt': '2026-10-06T00:00:00.000Z',
          },
        }),
        201,
        headers: {'content-type': 'application/json'},
      );

  http.Response payment(Map<String, dynamic> body) => http.Response(
        jsonEncode({
          'status': 'success',
          'data': {
            'id': body['id'],
            'receiptNo': 'CP01-2569-10-0001',
            'mechanicId': 'tm-x',
            'amount': '100.00',
            'paymentMethod': body['paymentMethod'],
            'date': '2026-10-06T06:00:00.000Z',
            'mechanicCreditBalanceAfter': '1900.00',
          },
        }),
        201,
        headers: {'content-type': 'application/json'},
      );

  const newCustomer = CustomersCompanion(name: Value('N'), nameTH: Value('น'));
  const edit = CustomersCompanion(nameTH: Value('หลัง'));

  for (final nv in _nonVerdicts.entries) {
    final (reply, sentence) = nv.value;

    group('${nv.key} is parked, never queued', () {
      test('addCustomer with the sync engine: Thai error, not Degraded, no row, '
          'no op; the next press re-sends online under the same id + key + body',
          () async {
        final api = clientWith([
          () async => reply(),
          () async => customer('server-id'),
        ]);
        final sync = syncWith(api);
        final repo = ApiCustomersRepository(db, api, syncService: sync);
        final customersBefore = (await db.select(db.customers).get()).length;

        await expectLater(
          repo.addCustomer(newCustomer),
          throwsA(isA<PosException>().having((e) => e.message, 'message', sentence)),
        );
        expect(await outbox(), isEmpty);
        expect(await db.select(db.customers).get(), hasLength(customersBefore));
        expect(sync.currentStatus, isNot(SyncStatus.degraded));

        await repo.addCustomer(newCustomer);
        expect(sent.keys, hasLength(2));
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1));
        expect(await outbox(), isEmpty);
      });

      test('addCustomer: pressed again online, the same id + key + body', () async {
        final api = clientWith([
          () async => reply(),
          () async => customer('server-id'),
        ]);
        final repo = ApiCustomersRepository(db, api);

        await expectLater(repo.addCustomer(newCustomer), throwsA(isA<PosException>()));
        await repo.addCustomer(newCustomer);
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1));
        expect(await outbox(), isEmpty);
      });

      test('updateCustomer: Thai error, row and outbox untouched; '
          'pressed again online, the same key', () async {
        final api = clientWith([
          () async => reply(),
          () async => customer('tc-x'),
        ]);
        final repo = ApiCustomersRepository(db, api);

        await expectLater(
          repo.updateCustomer('tc-x', edit),
          throwsA(isA<PosException>().having((e) => e.message, 'message', sentence)),
        );
        final row = await (db.select(db.customers)..where((t) => t.id.equals('tc-x'))).getSingle();
        expect(row.nameTH, 'ก่อน');
        expect(await outbox(), isEmpty);

        await repo.updateCustomer('tc-x', edit);
        expect(sent.keys.toSet(), hasLength(1));
      });

      test('updateCustomer with the sync engine: not Degraded, no op; the next '
          'press re-sends online under the same key + body', () async {
        final api = clientWith([
          () async => reply(),
          () async => customer('tc-x'),
        ]);
        final sync = syncWith(api);
        final repo = ApiCustomersRepository(db, api, syncService: sync);

        await expectLater(repo.updateCustomer('tc-x', edit), throwsA(isA<PosException>()));
        expect(await outbox(), isEmpty);
        expect(sync.currentStatus, isNot(SyncStatus.degraded));

        await repo.updateCustomer('tc-x', edit);
        expect(sent.keys, hasLength(2));
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1));
        expect(await outbox(), isEmpty);
      });

      test('addCreditPayment: Thai error (not "queued"), no op, no local payment; '
          'pressed again online, the same id + key + body', () async {
        final api = clientWith([
          () async => reply(),
          () async => payment(jsonDecode(sent.bodies.first) as Map<String, dynamic>),
        ]);
        final repo = ApiMechanicsRepository(db, api);
        final paymentsBefore = (await db.select(db.creditPayments).get()).length;

        await expectLater(
          repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด'),
          throwsA(isA<PosException>().having((e) => e.message, 'message', sentence)),
        );
        expect(await outbox(), isEmpty);
        expect(await db.select(db.creditPayments).get(), hasLength(paymentsBefore));

        await Future<void>.delayed(const Duration(milliseconds: 5));
        await repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด');
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1),
            reason: 'a reused key with a different body (its date) is a 409');
        expect(await db.select(db.creditPayments).get(), hasLength(paymentsBefore + 1));
      });

      test('addCreditPayment with the sync engine: not Degraded, never "saved '
          'locally"; the next press re-sends online under the same id + key + body',
          () async {
        final api = clientWith([
          () async => reply(),
          () async => payment(jsonDecode(sent.bodies.first) as Map<String, dynamic>),
        ]);
        final sync = syncWith(api);
        final repo = ApiMechanicsRepository(db, api, syncService: sync);

        await expectLater(
          repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด'),
          throwsA(isA<PosException>()),
        );
        expect(await outbox(), isEmpty);
        expect(sync.currentStatus, isNot(SyncStatus.degraded));

        await Future<void>.delayed(const Duration(milliseconds: 5));
        final paid = await repo.addCreditPayment(
            mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด');
        expect(paid.id, (jsonDecode(sent.bodies.first) as Map)['id']);
        expect(sent.keys, hasLength(2));
        expect(sent.keys.toSet(), hasLength(1));
        expect(sent.bodies.toSet(), hasLength(1));
        expect(await outbox(), isEmpty);
      });
    });
  }

  test('addCreditPayment: a 2xx that is not a payment is UNREADABLE_RESPONSE — '
      'never "saved locally", nothing queued, the next press replays the same '
      'id + key + body', () async {
    final api = clientWith([
      () async => http.Response(
            '{"status":"success","data":["not-a-payment"]}',
            201,
            headers: {'content-type': 'application/json'},
          ),
      () async => payment(jsonDecode(sent.bodies.first) as Map<String, dynamic>),
    ]);
    final repo = ApiMechanicsRepository(db, api, syncService: syncWith(api));
    final paymentsBefore = (await db.select(db.creditPayments).get()).length;

    await expectLater(
      repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด'),
      throwsA(isA<PosException>()
          .having((e) => e.code, 'code', 'UNREADABLE_RESPONSE')
          .having((e) => e.message, 'message', _connection)),
    );
    expect(await outbox(), isEmpty);
    expect(await db.select(db.creditPayments).get(), hasLength(paymentsBefore));

    await repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด');
    expect(sent.keys.toSet(), hasLength(1));
    expect(sent.bodies.toSet(), hasLength(1));
  });

  test('addCreditPayment: a closed attempt does not keep its body — a new '
      'payment of the same amount is a new id, key and date', () async {
    final api = clientWith([
      () async => payment(jsonDecode(sent.bodies[0]) as Map<String, dynamic>),
      () async => payment(jsonDecode(sent.bodies[1]) as Map<String, dynamic>),
    ]);
    final repo = ApiMechanicsRepository(db, api);

    await repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด');

    expect(sent.keys.toSet(), hasLength(2));
    expect(sent.bodies.toSet(), hasLength(2));
  });

  group('a transport failure still queues, under the key it was sent with', () {
    test('addCustomer', () async {
      final api = clientWith([() async => throw http.ClientException('reset')]);
      final repo = ApiCustomersRepository(db, api, syncService: syncWith(api));

      await repo.addCustomer(newCustomer);
      final op = (await outbox()).single;
      expect(op.idempotencyKey, sent.keys.single);
      expect((jsonDecode(op.payload) as Map)['id'],
          (jsonDecode(sent.bodies.single) as Map)['id']);
    });

    test('updateCustomer', () async {
      final api = clientWith([() async => throw http.ClientException('reset')]);
      final repo = ApiCustomersRepository(db, api, syncService: syncWith(api));

      await repo.updateCustomer('tc-x', edit);
      expect((await outbox()).single.idempotencyKey, sent.keys.single);
    });

    test('addCreditPayment', () async {
      final api = clientWith([() async => throw http.ClientException('reset')]);
      final repo = ApiMechanicsRepository(db, api, syncService: syncWith(api));

      await expectLater(
        repo.addCreditPayment(mechanicId: 'tm-x', amount: 100, paymentMethod: 'เงินสด'),
        throwsA(isA<CreditPaymentQueued>()),
      );
      final op = (await outbox()).single;
      expect(op.idempotencyKey, sent.keys.single);
      expect(jsonDecode(op.payload), jsonDecode(sent.bodies.single));
    });
  });
}
