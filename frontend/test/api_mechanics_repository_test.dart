// Unit tests for ApiMechanicsRepository (Ticket #55 / ADR-0010).

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';

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

  group('addCreditPayment (#24)', () {
    /// The mechanic owing 2,000 — and, unless [shift] is false, an open drawer,
    /// without which the API build takes no payment at all (owner, 2026-09-13).
    Future<void> seedTarget({bool shift = true}) async {
      await db
          .into(db.mechanics)
          .insert(
            MechanicsCompanion.insert(
              id: 'm_target',
              code: 'MEC010',
              name: 'Target Mechanic',
              createdAt: '2026-09-12T10:00:00.000Z',
              creditBalance: const Value(2000.0),
            ),
          );
      if (!shift) return;
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh-open',
              dateStr: '2026-09-12',
              startingCash: 500,
              openedAt: DateTime(2026, 9, 12, 8),
              isActive: const Value(true),
            ),
          );
    }

    /// Exactly what `credit-payments.service.ts` answers: money as strings.
    http.Response created(Map<String, dynamic> sent) => http.Response(
      jsonEncode({
        'status': 'success',
        'data': {
          'id': sent['id'],
          'receiptNo': 'CP07-2569-09-0001',
          'mechanicId': 'm_target',
          'amount': '500.00',
          'paymentMethod': sent['paymentMethod'],
          'note': sent['note'],
          'date': '2026-09-12T13:00:00.000Z',
          'shiftId': null,
          'mechanicCreditBalanceAfter': '1500.00',
        },
      }),
      201,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    Future<int> localPayments() async =>
        (await db.select(db.creditPayments).get()).length;

    Future<double> balance() async => (await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals('m_target'))).getSingle()).creditBalance;

    http.Response exceedsBalance() => http.Response(
      jsonEncode({
        'status': 'error',
        'error': {
          'code': 'CREDIT_PAYMENT_EXCEEDS_BALANCE',
          'message': 'Payment is more than the outstanding balance.',
          'details': {
            'creditBalance': '300.00',
            'amount': '500.00',
            'overpayBy': '200.00',
          },
        },
      }),
      409,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    test(
      'sends the method, a client id and an Idempotency-Key, and patches from the string reply',
      () async {
        await seedTarget();
        late http.Request seen;
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              seen = request;
              return created(jsonDecode(request.body) as Map<String, dynamic>);
            }),
          ),
        );

        final payment = await repo.addCreditPayment(
          mechanicId: 'm_target',
          amount: 500.0,
          note: 'โอน/QR · งวดแรก',
          paymentMethod: 'โอน/QR',
        );

        final sent = jsonDecode(seen.body) as Map<String, dynamic>;
        expect(seen.url.path, '/api/v1/mechanics/m_target/credit-payments');
        expect(sent['amount'], '500.00');
        expect(sent['paymentMethod'], 'โอน/QR');
        expect(sent['id'], startsWith('cp'));
        expect(sent.containsKey('allowOverpayment'), isFalse);
        expect(seen.headers['Idempotency-Key'], isNotEmpty);

        expect(payment.id, sent['id']);
        expect(payment.receiptNo, 'CP07-2569-09-0001');
        final mech = await (db.select(
          db.mechanics,
        )..where((t) => t.id.equals('m_target'))).getSingle();
        // The server's figure — never a local 2000 - 500.
        expect(mech.creditBalance, 1500.0);
        // One row: the string balance used to throw a cast error into the offline
        // fallback, which wrote the payment a second time.
        expect(await localPayments(), 1);
      },
    );

    test(
      'a 5xx queues the payment: the flush resends the same id and key',
      () async {
        await seedTarget();
        final sentIds = <String>[];
        final sentKeys = <String?>[];
        var calls = 0;
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              sentIds.add(body['id'] as String);
              sentKeys.add(request.headers['Idempotency-Key']);
              if (++calls == 1) {
                return http.Response(
                  '{"status":"error","error":{"code":"BAD_GATEWAY","message":"x"}}',
                  502,
                );
              }
              return created(body);
            }),
          ),
        );

        await expectLater(
          repo.addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );
        // The server may have committed; no local write may happen on its answer.
        expect(await localPayments(), 0);
        await repo.flushPendingCreditPayments();

        expect(sentIds[1], sentIds[0]);
        expect(sentKeys[1], sentKeys[0]);
        expect(await localPayments(), 1);
        expect(await repo.getPendingCreditPayments(), isEmpty);
      },
    );

    test(
      'an overpayment refusal reaches the screen with its code and details, and writes nothing',
      () async {
        await seedTarget();
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async => exceedsBalance()),
          ),
        );

        final error = await repo
            .addCreditPayment(
              mechanicId: 'm_target',
              amount: 500.0,
              paymentMethod: 'เงินสด',
            )
            .then<PosException?>(
              (_) => null,
              onError: (Object e) => e as PosException,
            );

        expect(error!.code, 'CREDIT_PAYMENT_EXCEEDS_BALANCE');
        expect((error.details as Map)['creditBalance'], '300.00');
        expect(await localPayments(), 0);
        // Refused while the counter watched: dropped, not left for a person.
        expect(await repo.getPendingCreditPayments(), isEmpty);
      },
    );

    test('the confirmed resend carries allowOverpayment', () async {
      await seedTarget();
      late Map<String, dynamic> sent;
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((request) async {
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return created(sent);
          }),
        ),
      );

      await repo.addCreditPayment(
        mechanicId: 'm_target',
        amount: 500.0,
        paymentMethod: 'เงินสด',
        allowOverpayment: true,
      );

      expect(sent['allowOverpayment'], isTrue);
    });

    test(
      'offline: the payment is queued with nothing written locally, and after a restart the flush sends the same id and key',
      () async {
        await seedTarget();
        final offline = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient(
              // The server may well have committed this one; only the reply is lost.
              (_) async => throw http.ClientException('Connection reset'),
            ),
          ),
        );

        await expectLater(
          offline.addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );
        final queued = (await offline.getPendingCreditPayments()).single;
        // No local row under a device-minted id/CP number, no local balance change.
        expect(await localPayments(), 0);
        expect(await balance(), 2000.0);

        // A new repository on the same database is an app restart: nothing held
        // in memory survives it, so the id and key must come from Drift.
        final sent = <Map<String, dynamic>>[];
        final sentKeys = <String?>[];
        final restarted = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              sent.add(body);
              sentKeys.add(request.headers['Idempotency-Key']);
              return created(body);
            }),
          ),
        );
        await restarted.flushPendingCreditPayments();

        expect(sent.single['id'], queued.id);
        expect(sentKeys.single, queued.idempotencyKey);
        expect(sent.single['amount'], '500.00');
        expect(await restarted.getPendingCreditPayments(), isEmpty);
        expect(await localPayments(), 1);
        expect(await balance(), 1500.0);
      },
    );

    test(
      'a queued confirmed overpayment is replayed WITH allowOverpayment (M2)',
      () async {
        await seedTarget();
        final sent = <Map<String, dynamic>>[];
        final sentKeys = <String?>[];
        var calls = 0;
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              sent.add(body);
              sentKeys.add(request.headers['Idempotency-Key']);
              if (++calls == 1) throw http.ClientException('Connection reset');
              return created(body);
            }),
          ),
        );

        await expectLater(
          repo.addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
            allowOverpayment: true,
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );
        await repo.flushPendingCreditPayments();

        // The resend is the stored body, not a re-derivation: the human's consent
        // travels with it, so the same key never meets a different body.
        expect(sent[1], sent[0]);
        expect(sent[1]['allowOverpayment'], isTrue);
        expect(sentKeys[1], sentKeys[0]);
      },
    );

    test(
      'a refusal during a flush is kept for a person, never retried; confirming resends the same id under a new key',
      () async {
        await seedTarget();
        final sent = <Map<String, dynamic>>[];
        final sentKeys = <String?>[];
        var calls = 0;
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              sent.add(body);
              sentKeys.add(request.headers['Idempotency-Key']);
              switch (++calls) {
                case 1:
                  throw http.ClientException('Connection reset');
                case 2:
                  return exceedsBalance();
                default:
                  return created(body);
              }
            }),
          ),
        );

        await expectLater(
          repo.addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );
        await repo.flushPendingCreditPayments();

        final rejected = (await repo.getPendingCreditPayments()).single;
        expect(rejected.rejectedCode, 'CREDIT_PAYMENT_EXCEEDS_BALANCE');
        expect(rejected.rejectedMessage, isNotEmpty);

        await repo.flushPendingCreditPayments();
        expect(calls, 2, reason: 'a refused row must not be sent again on its own');

        await repo.resendRejectedAllowingOverpayment(rejected.id);

        expect(sent[2]['id'], sent[0]['id']);
        expect(sent[2]['allowOverpayment'], isTrue);
        expect(sentKeys[2], isNot(sentKeys[0]));
        expect(await repo.getPendingCreditPayments(), isEmpty);
        expect(await localPayments(), 1);
      },
    );

    test(
      'a 401 during a flush is not a verdict, and a queued row cannot be discarded',
      () async {
        await seedTarget();
        var online = false;
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              if (!online) throw http.ClientException('Offline');
              return http.Response(
                '{"status":"error","error":{"code":"UNAUTHORIZED","message":"x"}}',
                401,
              );
            }),
          ),
        );

        await expectLater(
          repo.addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );
        online = true;
        await repo.flushPendingCreditPayments();

        final row = (await repo.getPendingCreditPayments()).single;
        expect(row.rejectedCode, isNull);

        await repo.discardRejectedCreditPayment(row.id);
        expect(await repo.getPendingCreditPayments(), hasLength(1));
      },
    );

    group('no open shift, no payment taken (owner, 2026-09-13)', () {
      Future<void> openShift({DateTime? closedAt}) => db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh-local',
              dateStr: '2026-09-12',
              startingCash: 500,
              openedAt: DateTime(2026, 9, 12, 8),
              isActive: const Value(true),
              closedAt: Value(closedAt),
            ),
          );

      Future<Object?> pay(ApiMechanicsRepository repo) => repo
          .addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
          )
          .then<Object?>((_) => null, onError: (Object e) => e);

      test(
        'offline with no open drawer: refused on the spot, never queued',
        () async {
          await seedTarget(shift: false);
          var calls = 0;
          final repo = ApiMechanicsRepository(
            db,
            ApiClient(
              httpClient: MockClient((_) async {
                calls++;
                throw http.ClientException('Offline');
              }),
            ),
          );

          final error = await pay(repo);

          // Not CreditPaymentQueued: a queued row would be refused only during a
          // later flush, with the cash already in the drawer.
          expect(error, isA<PosException>());
          expect((error as PosException).code, 'NO_OPEN_SHIFT');
          expect(error.toString(), 'กรุณาเปิดกะก่อนรับชำระ');
          expect(await repo.getPendingCreditPayments(), isEmpty);
          expect(calls, 0);
        },
      );

      test('a closed (not yet archived) drawer refuses too', () async {
        await seedTarget(shift: false);
        await openShift(closedAt: DateTime(2026, 9, 12, 20));
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((_) async => fail('nothing may be sent')),
          ),
        );

        expect((await pay(repo)).toString(), 'กรุณาเปิดกะก่อนรับชำระ');
        expect(await repo.getPendingCreditPayments(), isEmpty);
      });

      test('with an open drawer an offline payment is still queued', () async {
        await seedTarget(shift: false);
        await openShift();
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient(
              (_) async => throw http.ClientException('Offline'),
            ),
          ),
        );

        expect(await pay(repo), isA<CreditPaymentQueued>());
        expect(await repo.getPendingCreditPayments(), hasLength(1));
      });

      test(
        'the Drift build (writesToServer off) takes the payment locally: no outbox, no shift check, nothing sent',
        () async {
          await seedTarget(shift: false);
          var calls = 0;
          final repo = ApiMechanicsRepository(
            db,
            ApiClient(
              httpClient: MockClient((_) async {
                calls++;
                throw http.ClientException('Offline');
              }),
            ),
            writesToServer: false,
          );

          // No drawer is open, and there is no server: the shop's build must
          // still record the payment exactly as the Drift repository does.
          expect(await pay(repo), isNull, reason: 'taken, not refused or queued');
          expect(await localPayments(), 1);
          expect(await balance(), 1500.0);
          expect(await repo.getPendingCreditPayments(), isEmpty);

          await repo.flushPendingCreditPayments();
          expect(calls, 0);
        },
      );

      test(
        'a server 409 NO_OPEN_SHIFT (stale cache) is shown in Thai and dropped',
        () async {
          await seedTarget(shift: false);
          await openShift();
          final repo = ApiMechanicsRepository(
            db,
            ApiClient(
              httpClient: MockClient(
                (_) async => http.Response(
                  jsonEncode({
                    'status': 'error',
                    'error': {'code': 'NO_OPEN_SHIFT', 'message': 'No open shift'},
                  }),
                  409,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                ),
              ),
            ),
          );

          final error = await pay(repo);

          expect(error, isNot(isA<ApiException>()));
          expect(error.toString(), 'กรุณาเปิดกะก่อนรับชำระ');
          expect(await repo.getPendingCreditPayments(), isEmpty);
        },
      );
    });

    group('Phase 2, Ticket #275: outbox_ops credit payment migration', () {
      test(
        'offline credit payment queues into outbox_ops with credit_payment.create',
        () async {
          await seedTarget();
          final repo = ApiMechanicsRepository(
            db,
            ApiClient(
              httpClient: MockClient((_) async => throw http.ClientException('Offline')),
            ),
          );

          await expectLater(
            repo.addCreditPayment(
              mechanicId: 'm_target',
              amount: 400.0,
              paymentMethod: 'เงินสด',
              note: 'งวดพิเศษ',
            ),
            throwsA(isA<CreditPaymentQueued>()),
          );

          // Verify outbox_ops contains the op
          final ops = await (db.select(db.outboxOps)
                ..where((t) => t.type.equals('credit_payment.create')))
              .get();
          expect(ops, hasLength(1));
          final op = ops.first;
          expect(op.status, 'pending');
          expect(op.idempotencyKey, isNotEmpty);

          final payload = jsonDecode(op.payload) as Map<String, dynamic>;
          expect(payload['id'], startsWith('cp'));
          expect(payload['mechanicId'], 'm_target');
          expect(payload['amount'], '400.00');
          expect(payload['paymentMethod'], 'เงินสด');
          expect(payload['note'], 'งวดพิเศษ');
          expect(payload['date'], isNotEmpty);

          final aggregates = jsonDecode(op.aggregates) as List;
          expect(aggregates, contains('cp:${payload['id']}'));
          expect(aggregates, contains('shift:sh-open'));
          expect(aggregates, contains('mechanic:m_target'));

          // Verify pending_credit_payments has 0 rows
          expect(await db.select(db.pendingCreditPayments).get(), isEmpty);
        },
      );

      test(
        'legacy pending_credit_payments rows are migrated to outbox_ops with zero data loss',
        () async {
          await seedTarget();
          // Insert legacy rows directly into pendingCreditPayments
          await db.into(db.pendingCreditPayments).insert(
                PendingCreditPaymentsCompanion.insert(
                  id: 'cp_legacy_1',
                  idempotencyKey: 'idem_legacy_1',
                  mechanicId: 'm_target',
                  amount: '350.00',
                  paymentMethod: 'เงินสด',
                  createdAt: DateTime(2026, 9, 15, 8, 30),
                ),
              );
          await db.into(db.pendingCreditPayments).insert(
                PendingCreditPaymentsCompanion.insert(
                  id: 'cp_legacy_2',
                  idempotencyKey: 'idem_legacy_2',
                  mechanicId: 'm_target',
                  amount: '150.00',
                  paymentMethod: 'โอน/QR',
                  createdAt: DateTime(2026, 9, 15, 9, 0),
                  rejectedCode: const Value('CREDIT_PAYMENT_EXCEEDS_BALANCE'),
                  rejectedMessage: const Value('ยอดชำระเกิน'),
                ),
              );

          final repo = ApiMechanicsRepository(
            db,
            ApiClient(
              httpClient: MockClient((_) async => throw http.ClientException('Offline')),
            ),
          );

          final pending = await repo.getPendingCreditPayments();
          expect(pending, hasLength(2));

          // pending_credit_payments must now be empty
          expect(await db.select(db.pendingCreditPayments).get(), isEmpty);

          // outbox_ops must contain both ops
          final ops = await (db.select(db.outboxOps)
                ..where((t) => t.type.equals('credit_payment.create')))
              .get();
          expect(ops, hasLength(2));
          final op1 = ops.firstWhere((o) => o.idempotencyKey == 'idem_legacy_1');
          expect(op1.status, 'pending');
          final op2 = ops.firstWhere((o) => o.idempotencyKey == 'idem_legacy_2');
          expect(op2.status, 'rejected');
          expect(op2.lastCode, 'CREDIT_PAYMENT_EXCEEDS_BALANCE');
          expect(op2.lastMessage, 'ยอดชำระเกิน');
        },
      );

      test('overpayment guard checks queued balance in outbox_ops', () async {
        await seedTarget(); // balance 2000
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((_) async => throw http.ClientException('Offline')),
          ),
        );

        // Take 1500 payment offline (queued into outbox_ops)
        await expectLater(
          repo.addCreditPayment(
            mechanicId: 'm_target',
            amount: 1500.0,
            paymentMethod: 'เงินสด',
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );

        // Remaining projected balance is 2000 - 1500 = 500
        // Trying to pay 600 without allowOverpayment must throw OVERPAYMENT_NOT_ALLOWED
        final err = await repo
            .addCreditPayment(
              mechanicId: 'm_target',
              amount: 600.0,
              paymentMethod: 'เงินสด',
            )
            .then<PosException?>((_) => null, onError: (Object e) => e as PosException);

        expect(err, isNotNull);
        expect(err!.code, 'OVERPAYMENT_NOT_ALLOWED');
        expect((err.details as Map)['creditBalance'], 500.0);
      });

      test('discard and resend update outbox_ops correctly', () async {
        await seedTarget();
        var calls = 0;
        final sent = <Map<String, dynamic>>[];
        final repo = ApiMechanicsRepository(
          db,
          ApiClient(
            httpClient: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              sent.add(body);
              calls++;
              if (calls == 1) throw http.ClientException('Offline');
              if (calls == 2) return exceedsBalance();
              return created(body);
            }),
          ),
        );

        // 1. Queue offline
        await expectLater(
          repo.addCreditPayment(
            mechanicId: 'm_target',
            amount: 500.0,
            paymentMethod: 'เงินสด',
          ),
          throwsA(isA<CreditPaymentQueued>()),
        );

        // 2. Flush gets rejected by server
        await repo.flushPendingCreditPayments();
        var ops = await (db.select(db.outboxOps)
              ..where((t) => t.type.equals('credit_payment.create')))
            .get();
        expect(ops.single.status, 'rejected');

        // 3. Resend allowing overpayment updates outbox_ops and succeeds
        await repo.resendRejectedAllowingOverpayment(ops.single.opId);
        ops = await (db.select(db.outboxOps)
              ..where((t) => t.type.equals('credit_payment.create')))
            .get();
        expect(ops, isEmpty);
        expect(await localPayments(), 1);
      });
    });
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
