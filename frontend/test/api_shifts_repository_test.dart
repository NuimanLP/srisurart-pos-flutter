// Unit tests for ApiShiftsRepository (#56 fe.3).
//
// Every mock response below carries values the LOCAL client would never
// have produced on its own (a dateStr far from today, an id shaped nothing
// like `newUuid()`, a note the caller never typed) — on purpose, so a test
// that only checks "some row got written" cannot pass if the implementation
// quietly falls back to local computation instead of trusting the response
// (ADR-0010 §3, "no client-side arithmetic on any server-owned number").

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_shifts_repository.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'support/test_ids.dart';

/// Builds the success envelope as UTF-8 bytes — `http.Response(String, ...)`
/// encodes as Latin-1 by default, which throws on the Thai text several
/// fixtures below carry (`ทอนเงิน`), so every success response in this file
/// goes through this helper rather than the plain String constructor.
http.Response _successResponse(Object data, [int status = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode({'status': 'success', 'data': data})),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _errorResponse(int status, String code, String message) {
  return http.Response.bytes(
    utf8.encode(
      jsonEncode({
        'status': 'error',
        'error': {'code': code, 'message': message},
      }),
    ),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

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

void main() {
  late AppDatabase db;
  late ShiftsRepository drift;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    drift = ShiftsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  ApiShiftsRepository buildRepo(
    Future<http.Response> Function(http.Request) handler,
  ) {
    final client = ApiClient(
      baseUrl: 'http://example.com',
      httpClient: MockClient(handler),
    );
    return ApiShiftsRepository(api: client, db: db, drift: drift);
  }

  group('openShift', () {
    test(
      'posts to /api/v1/shifts/open with an Idempotency-Key and patches the '
      "server's TEXT id/dateStr/openedAt/startingCash locally",
      () async {
        String? sentKey;
        final repo = buildRepo((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, '/api/v1/shifts/open');
          sentKey = req.headers['Idempotency-Key'];
          expect(sentKey, isNotNull);
          expect(sentKey, isNotEmpty);

          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['startingCash'], '1500.00');
          // 08 §11: the client's shift id rides in the online body; the
          // device time does not (08 §10 — `openedAt` is push-only).
          expect(body['id'], matches(uuidV7));
          expect(body.containsKey('openedAt'), isFalse);

          return _successResponse({
            // A server-issued TEXT id shaped nothing like newUuid() —
            // proves the id on the local row came off the wire, not
            // `newUuid()`.
            'id': 'srv-shift-9f3a',
            // Deliberately not "today" in the test's local timezone — a
            // client that computed `todayKey()` itself instead of reading
            // the response would fail this assertion.
            'dateStr': '2019-03-04',
            'startingCash': '1500.00',
            'openedAt': '2019-03-04T02:00:00.000Z',
            'closedAt': null,
            'physicalCash': null,
            'isActive': true,
            'autoArchived': false,
            'archivedAt': null,
            'deviceId': 'dev-1',
            'entries': <Object>[],
          });
        });

        final row = await repo.openShift(1500);
        expect(row.id, 'srv-shift-9f3a');
        expect(row.dateStr, '2019-03-04');
        expect(row.startingCash, 1500.00);
        expect(row.openedAt, DateTime.parse('2019-03-04T02:00:00.000Z').toLocal());
        expect(row.isActive, isTrue);

        final local = await (db.select(
          db.shifts,
        )..where((t) => t.id.equals('srv-shift-9f3a'))).getSingle();
        expect(local.id, 'srv-shift-9f3a');
        expect(local.dateStr, '2019-03-04');
        expect(local.startingCash, 1500.00);
        expect(local.isActive, isTrue);
      },
    );

    test(
      'clears isActive on any other locally-cached shift once the server '
      'names a new active shift',
      () async {
        await db
            .into(db.shifts)
            .insert(
              ShiftsCompanion.insert(
                id: 'stale-local-shift',
                dateStr: '2018-01-01',
                startingCash: 200,
                openedAt: DateTime(2018, 1, 1),
                isActive: const Value(true),
              ),
            );

        final repo = buildRepo((req) async {
          return _successResponse({
            'id': 'srv-shift-new',
            'dateStr': '2019-03-04',
            'startingCash': 1500,
            'openedAt': '2019-03-04T02:00:00.000Z',
            'closedAt': null,
            'physicalCash': null,
            'isActive': true,
            'autoArchived': false,
            'archivedAt': null,
            'deviceId': 'dev-1',
            'entries': <Object>[],
          });
        });

        await repo.openShift(1500);

        final stale = await (db.select(
          db.shifts,
        )..where((t) => t.id.equals('stale-local-shift'))).getSingle();
        expect(stale.isActive, isFalse);
      },
    );

    test('an ApiException never escapes openShift', () async {
      final repo = buildRepo(
        (req) async => _errorResponse(
          403,
          'DEVICE_ROLE_FORBIDDEN',
          'this device may not open a shift',
        ),
      );

      try {
        await repo.openShift(100);
        fail('expected an Exception');
      } catch (e) {
        expect(e, isNot(isA<ApiException>()));
        expect(e, isA<Exception>());
        expect(
          e.toString().replaceFirst('Exception: ', ''),
          'เครื่องนี้ขายของไม่ได้',
        );
      }
    });
  });

  group('closeShift', () {
    test('patches closedAt + physicalCash from the response', () async {
      // Seed the shift closeShift is about to "close" so the FK on any
      // returned entries (none here) would hold either way.
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'srv-shift-9f3a',
              dateStr: '2019-03-04',
              startingCash: 1500,
              openedAt: DateTime.parse('2019-03-04T02:00:00.000Z'),
              isActive: const Value(true),
            ),
          );

      final repo = buildRepo((req) async {
        expect(req.url.path, '/api/v1/shifts/close');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['physicalCash'], '1888.25');

        return _successResponse({
          'id': 'srv-shift-9f3a',
          'dateStr': '2019-03-04',
          'startingCash': '1500.00',
          'openedAt': '2019-03-04T02:00:00.000Z',
          // A closedAt timestamp the local clock never produced.
          'closedAt': '2019-03-04T11:47:33.000Z',
          'physicalCash': '1888.25',
          'isActive': true,
          'autoArchived': false,
          'archivedAt': null,
          'deviceId': 'dev-1',
          'entries': <Object>[],
        });
      });

      final row = await repo.closeShift(1888.25);
      expect(row, isNotNull);
      expect(row!.closedAt, DateTime.parse('2019-03-04T11:47:33.000Z').toLocal());
      expect(row.physicalCash, 1888.25);

      final local = await (db.select(
        db.shifts,
      )..where((t) => t.id.equals('srv-shift-9f3a'))).getSingle();
      expect(local.closedAt, isNotNull);
      expect(local.physicalCash, 1888.25);
    });

    test(
      'a 409 SHIFT_ALREADY_CLOSED throws a plain Exception with the '
      'resolver message, never an ApiException',
      () async {
        final repo = buildRepo(
          (req) async => _errorResponse(
            409,
            'SHIFT_ALREADY_CLOSED',
            'This shift is already closed.',
          ),
        );

        try {
          await repo.closeShift(100);
          fail('expected an Exception');
        } catch (e) {
          expect(e, isNot(isA<ApiException>()));
          expect(
            e.toString().replaceFirst('Exception: ', ''),
            'กะนี้ปิดไปแล้ว ปิดซ้ำไม่ได้ — ถ้าจะขายต่อ กรุณาเปิดกะใหม่',
          );
        }
      },
    );
  });

  group('closeShift sends the outbox first and needs it empty (08 §11)', () {
    Map<String, dynamic> closedShift() => {
      'id': 'srv-shift-9f3a',
      'dateStr': '2019-03-04',
      'startingCash': '1500.00',
      'openedAt': '2019-03-04T02:00:00.000Z',
      'closedAt': '2019-03-04T11:47:33.000Z',
      'physicalCash': '100.00',
      'isActive': true,
      'autoArchived': false,
      'archivedAt': null,
      'deviceId': 'dev-1',
      'entries': <Object>[],
    };

    Future<void> queue(
      String id, {
      String method = 'เงินสด',
      String? rejectedCode,
    }) => db
        .into(db.pendingCreditPayments)
        .insert(
          PendingCreditPaymentsCompanion.insert(
            id: id,
            idempotencyKey: 'idem-$id',
            mechanicId: 'm_close',
            amount: '300.00',
            paymentMethod: method,
            createdAt: DateTime(2019, 3, 4, 10),
            rejectedCode: Value(rejectedCode),
          ),
        );

    /// The outbox as `repository_providers.dart` wires it, over its own client.
    ApiMechanicsRepository outbox(
      Future<http.Response> Function(http.Request) handler,
    ) => ApiMechanicsRepository(
      db,
      ApiClient(baseUrl: 'http://example.com', httpClient: MockClient(handler)),
    );

    ApiShiftsRepository closeRepo(
      MechanicsRepository mechanics,
      Future<http.Response> Function(http.Request) handler,
    ) => ApiShiftsRepository(
      api: ApiClient(
        baseUrl: 'http://example.com',
        httpClient: MockClient(handler),
      ),
      db: db,
      drift: drift,
      mechanics: mechanics,
    );

    test(
      'still offline: refused with the count, and the close is never sent',
      () async {
        await queue('cp-a');
        await queue('cp-b');
        var flushAttempts = 0;
        var closes = 0;
        final repo = closeRepo(
          outbox((_) async {
            flushAttempts++;
            throw http.ClientException('Offline');
          }),
          (_) async {
            closes++;
            return _successResponse(closedShift());
          },
        );

        Object? thrown;
        try {
          await repo.closeShift(100);
        } catch (e) {
          thrown = e;
        }

        expect(flushAttempts, greaterThan(0), reason: 'the outbox is tried first');
        expect(closes, 0);
        expect(thrown, isA<PosException>());
        expect(
          thrown.toString(),
          'ยังมี 2 รายการติดปัญหา / ค้างส่ง '
          '— ต้องส่งเข้าระบบให้หมดก่อนปิดกะ',
        );
      },
    );

    test('back online: the flush drains the outbox and the close goes out', () async {
      await db
          .into(db.mechanics)
          .insert(
            MechanicsCompanion.insert(
              id: 'm_close',
              code: 'M-CLOSE',
              name: 'Chang',
              createdAt: '2019-03-04',
              creditBalance: const Value(300),
            ),
          );
      await queue('cp-a');
      final order = <String>[];
      final repo = closeRepo(
        outbox((req) async {
          order.add(req.url.path);
          return _successResponse({
            'id': 'cp-a',
            'receiptNo': 'CP-0001',
            'mechanicId': 'm_close',
            'amount': '300.00',
            'date': '2019-03-04T10:00:00.000Z',
            'note': null,
            'mechanicCreditBalanceAfter': '0.00',
          }, 201);
        }),
        (req) async {
          order.add(req.url.path);
          return _successResponse(closedShift());
        },
      );

      final row = await repo.closeShift(100);

      expect(row!.closedAt, isNotNull);
      expect(order, [
        '/api/v1/mechanics/m_close/credit-payments',
        '/api/v1/shifts/close',
      ]);
      expect(await db.select(db.pendingCreditPayments).get(), isEmpty);
    });

    test('a transfer or a REFUSED row blocks the close too — 08 §11 replaces '
        'the cash-only rule of 2026-09-13', () async {
      await queue('cp-qr', method: 'โอน/QR');
      await queue('cp-refused', rejectedCode: 'CREDIT_PAYMENT_EXCEEDS_BALANCE');
      var closes = 0;
      final repo = closeRepo(
        outbox((_) async => throw http.ClientException('Offline')),
        (_) async {
          closes++;
          return _successResponse(closedShift());
        },
      );

      await expectLater(
        () => repo.closeShift(100),
        throwsA(
          isA<PosException>().having((e) => e.code, 'code', 'OUTBOX_NOT_EMPTY'),
        ),
      );
      expect(closes, 0);
    });

    test('any queued op type blocks the close, not only credit payments', () async {
      await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              opId: 'op-sale',
              idempotencyKey: 'k-sale',
              type: 'sale.create',
              payload: '{"id":"s_1"}',
              aggregates: '["sale:s_1"]',
              createdAt: DateTime.utc(2019, 3, 4, 3),
              status: 'stuck',
            ),
          );
      var closes = 0;
      final repo = closeRepo(
        outbox((_) async => throw http.ClientException('Offline')),
        (_) async {
          closes++;
          return _successResponse(closedShift());
        },
      );

      await expectLater(() => repo.closeShift(100), throwsA(isA<PosException>()));
      expect(closes, 0);
    });
  });

  group('addDrawerEntry', () {
    test('posts to current/entries, inserts, and returns the entry', () async {
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'srv-shift-9f3a',
              dateStr: '2019-03-04',
              startingCash: 1500,
              openedAt: DateTime.parse('2019-03-04T02:00:00.000Z'),
              isActive: const Value(true),
            ),
          );

      final repo = buildRepo((req) async {
        expect(req.url.path, '/api/v1/shifts/current/entries');
        expect(req.headers['Idempotency-Key'], isNotEmpty);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['type'], 'in');
        expect(body['amount'], '300.00');
        expect(body['note'], 'ทอนเงิน');
        expect(body['id'], matches(uuidV7));

        return _successResponse({
          'id': 'srv-de-77',
          'shiftId': 'srv-shift-9f3a',
          'type': 'in',
          'amount': '300.00',
          'note': 'ทอนเงิน',
          'createdAt': '2019-03-04T05:30:00.000Z',
        },
            // The real endpoint has no @HttpCode override, so Nest's POST
            // default (201) applies — assert the client accepts that too.
            201);
      });

      final entry = await repo.addDrawerEntry('in', 300, 'ทอนเงิน');
      expect(entry.id, 'srv-de-77');
      expect(entry.shiftId, 'srv-shift-9f3a');
      expect(entry.amount, 300.00);
      expect(entry.note, 'ทอนเงิน');

      final local = await (db.select(
        db.drawerEntries,
      )..where((t) => t.id.equals('srv-de-77'))).getSingle();
      expect(local.shiftId, 'srv-shift-9f3a');
      expect(local.amount, 300.00);
    });

    test(
      'FK trap: a response naming a shiftId absent from the local cache is '
      'still returned, but is NOT inserted, and the DB stays consistent',
      () async {
        // Deliberately do NOT seed a 'ghost-shift' Shifts row.
        final repo = buildRepo((req) async {
          return _successResponse({
            'id': 'srv-de-orphan',
            'shiftId': 'ghost-shift-from-another-device',
            'type': 'out',
            'amount': '50.00',
            'note': null,
            'createdAt': '2019-03-04T06:00:00.000Z',
          }, 201);
        });

        final entry = await repo.addDrawerEntry('out', 50, null);

        // The caller still gets the authoritative row back — not swallowed.
        expect(entry.id, 'srv-de-orphan');
        expect(entry.shiftId, 'ghost-shift-from-another-device');
        expect(entry.amount, 50.00);

        // But nothing was written locally: no orphan FK row...
        final orphan = await (db.select(
          db.drawerEntries,
        )..where((t) => t.id.equals('srv-de-orphan'))).getSingleOrNull();
        expect(orphan, isNull);

        // ...and no placeholder Shifts row was fabricated to satisfy the FK.
        final ghostParent = await (db.select(
          db.shifts,
        )..where((t) => t.id.equals('ghost-shift-from-another-device')))
            .getSingleOrNull();
        expect(ghostParent, isNull);

        // The DB as a whole is left completely untouched by this call.
        expect(await db.select(db.drawerEntries).get(), isEmpty);
        expect(await db.select(db.shifts).get(), isEmpty);
      },
    );

    test(
      'a 409 DRAWER_CLOSED throws a plain Exception whose message is exactly '
      'the Thai sentence, and nothing is written locally',
      () async {
        final repo = buildRepo(
          (req) async => _errorResponse(
            409,
            'DRAWER_CLOSED',
            'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
          ),
        );

        try {
          await repo.addDrawerEntry('in', 100, 'สาย');
          fail('expected an Exception');
        } catch (e) {
          expect(e, isNot(isA<ApiException>()));
          expect(e, isA<Exception>());
          expect(
            e.toString().replaceFirst('Exception: ', ''),
            'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
          );
        }

        expect(await db.select(db.drawerEntries).get(), isEmpty);
      },
    );

    test('a lost reply must not become a second drawer entry', () async {
      // 🔴 Nothing else catches this. The endpoint mints its own id, the server
      // has no notion of "the same entry twice", and a duplicated row is money:
      // the closing count comes out over by the amount, and the drawer is
      // reconciled against a figure nobody typed.
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'srv-shift-9f3a',
              dateStr: '2019-03-04',
              startingCash: 1500,
              openedAt: DateTime.parse('2019-03-04T02:00:00.000Z'),
              isActive: const Value(true),
            ),
          );

      final keys = <String?>[];
      var attempt = 0;
      final repo = buildRepo((req) async {
        keys.add(req.headers['Idempotency-Key']);
        attempt++;
        if (attempt == 1) {
          // nginx timed out on the way back; the row is already written.
          return http.Response('<html>504 Gateway Time-out</html>', 504);
        }
        return _successResponse({
          'id': 'srv-de-77',
          'shiftId': 'srv-shift-9f3a',
          'type': 'in',
          'amount': '300.00',
          'note': 'ทอนเงิน',
          'createdAt': '2019-03-04T05:30:00.000Z',
        }, 201);
      });

      await expectLater(
        () => repo.addDrawerEntry('in', 300, 'ทอนเงิน'),
        throwsA(isA<Exception>()),
      );
      final entry = await repo.addDrawerEntry('in', 300, 'ทอนเงิน');

      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(1), reason: 'the retry must replay the key');
      expect(entry.id, 'srv-de-77');
      expect(await db.select(db.drawerEntries).get(), hasLength(1));
    });

    test('a verdict closes the attempt — the next entry is a new one', () async {
      final keys = <String?>[];
      var attempt = 0;
      final repo = buildRepo((req) async {
        keys.add(req.headers['Idempotency-Key']);
        attempt++;
        if (attempt == 1) {
          return _errorResponse(
            409,
            'SHIFT_ALREADY_CLOSED',
            'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
          );
        }
        return _successResponse({
          'id': 'srv-de-78',
          'shiftId': 'srv-shift-9f3a',
          'type': 'in',
          'amount': '300.00',
          'note': 'ทอนเงิน',
          'createdAt': '2019-03-04T05:30:00.000Z',
        }, 201);
      });

      await expectLater(
        () => repo.addDrawerEntry('in', 300, 'ทอนเงิน'),
        throwsA(isA<Exception>()),
      );
      await repo.addDrawerEntry('in', 300, 'ทอนเงิน');

      expect(keys.toSet(), hasLength(2));
    });
  });

  group('offline: shift.open / drawer.entry are queued (#452, 08 §6.1)', () {
    late SyncService sync;
    late List<http.Request> sent;

    ApiShiftsRepository offlineRepo(
      Future<http.Response> Function(http.Request) handler,
    ) {
      sent = [];
      final client = ApiClient(
        baseUrl: 'http://example.com',
        httpClient: MockClient((req) {
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
      return ApiShiftsRepository(
        api: client,
        db: db,
        drift: drift,
        syncService: sync,
      );
    }

    Future<List<OutboxOpRow>> ops() => db.select(db.outboxOps).get();

    Future<void> seedShift(String id, {DateTime? closedAt}) => db
        .into(db.shifts)
        .insert(
          ShiftsCompanion.insert(
            id: id,
            dateStr: '2019-03-04',
            startingCash: 500,
            openedAt: DateTime(2019, 3, 4, 8),
            closedAt: Value(closedAt),
            isActive: const Value(true),
          ),
        );

    test(
      'Degraded: openShift writes the shift + one shift.open op, archives the '
      'prior shift, and sends nothing online',
      () async {
        await seedShift('sh-prior');
        final repo = offlineRepo((_) async => fail('no online call'));
        sync.recordNonVerdictWrite();

        final row = await repo.openShift(1500);

        expect(row.id, matches(uuidV7));
        expect(row.isActive, isTrue);
        expect(sent, isEmpty);

        final prior = await (db.select(
          db.shifts,
        )..where((t) => t.id.equals('sh-prior'))).getSingle();
        expect(prior.isActive, isFalse);
        expect(prior.autoArchived, isTrue);

        final queued = await ops();
        expect(queued, hasLength(1));
        expect(queued.single.type, 'shift.open');
        expect(queued.single.status, 'pending');
        expect(queued.single.idempotencyKey, isNotEmpty);
        expect(jsonDecode(queued.single.aggregates), ['shift:${row.id}']);
        final payload = jsonDecode(queued.single.payload) as Map;
        expect(payload['id'], row.id);
        expect(payload['startingCash'], '1500.00');
        expect(payload['openedAt'], isA<String>());
      },
    );

    test('Degraded: re-opening an id already cached queues nothing', () async {
      await seedShift('sh-mine');
      final repo = offlineRepo((_) async => fail('no online call'));
      sync.recordNonVerdictWrite();

      final row = await repo.openShift(9999, id: 'sh-mine');

      expect(row.id, 'sh-mine');
      expect(row.startingCash, 500);
      expect(row.isActive, isTrue);
      expect(await ops(), isEmpty);
    });

    test(
      'a lost connection queues shift.open under the SAME id + key it was sent '
      'with',
      () async {
        final repo = offlineRepo(
          (_) async => throw http.ClientException('socket dropped'),
        );

        final row = await repo.openShift(800);

        final online = sent.singleWhere(
          (r) => r.url.path == '/api/v1/shifts/open',
        );
        final sentBody = jsonDecode(online.body) as Map;
        final queued = (await ops()).single;
        expect(queued.idempotencyKey, online.headers['Idempotency-Key']);
        expect((jsonDecode(queued.payload) as Map)['id'], sentBody['id']);
        expect(row.id, sentBody['id']);
        expect(sync.currentStatus, SyncStatus.degraded);
      },
    );

    test(
      'Degraded: addDrawerEntry writes the entry + one drawer.entry op that '
      'waits on its shift',
      () async {
        await seedShift('sh-open');
        final repo = offlineRepo((_) async => fail('no online call'));
        sync.recordNonVerdictWrite();

        final entry = await repo.addDrawerEntry('out', 120.5, 'ค่าน้ำแข็ง');

        expect(entry.id, matches(uuidV7));
        expect(entry.shiftId, 'sh-open');
        final local = await (db.select(
          db.drawerEntries,
        )..where((t) => t.id.equals(entry.id))).getSingle();
        expect(local.amount, 120.5);

        final queued = (await ops()).single;
        expect(queued.type, 'drawer.entry');
        expect(jsonDecode(queued.aggregates), [
          'drawer:${entry.id}',
          'shift:sh-open',
        ]);
        final payload = jsonDecode(queued.payload) as Map;
        expect(payload['id'], entry.id);
        expect(payload['type'], 'out');
        expect(payload['amount'], '120.50');
        expect(payload['note'], 'ค่าน้ำแข็ง');
        expect(payload['createdAt'], isA<String>());
      },
    );

    test(
      'Degraded: a cash-out over the local expected cash is refused before '
      'anything is queued (owner 2026-10-03)',
      () async {
        await seedShift('sh-open'); // starting cash ฿500
        final repo = offlineRepo((_) async => fail('no online call'));
        sync.recordNonVerdictWrite();

        await expectLater(
          repo.addDrawerEntry('out', 500.01, null),
          throwsA(
            isA<PosException>()
                .having((e) => e.code, 'code', 'DRAWER_INSUFFICIENT_CASH')
                .having(
                  (e) => e.message,
                  'message',
                  'เงินในลิ้นชักไม่พอ (มี ฿500)',
                ),
          ),
        );
        expect(await ops(), isEmpty);
        expect(await db.select(db.drawerEntries).get(), isEmpty);

        await repo.addDrawerEntry('out', 500, null);
        expect((await ops()).single.type, 'drawer.entry');
      },
    );

    test('a lost connection queues drawer.entry under the SAME id + key', () async {
      await seedShift('sh-open');
      final repo = offlineRepo(
        (_) async => throw http.ClientException('socket dropped'),
      );

      final entry = await repo.addDrawerEntry('in', 50, null);

      final online = sent.singleWhere(
        (r) => r.url.path == '/api/v1/shifts/current/entries',
      );
      final queued = (await ops()).single;
      expect(queued.idempotencyKey, online.headers['Idempotency-Key']);
      expect((jsonDecode(online.body) as Map)['id'], entry.id);
      expect((jsonDecode(queued.payload) as Map)['id'], entry.id);
    });

    test(
      'an applied shift.open deletes the op and takes the server openedAt',
      () async {
        final repo = offlineRepo((_) async => fail('no online call'));
        sync.recordNonVerdictWrite();
        final row = await repo.openShift(1500);
        final op = (await ops()).single;

        // The server clamped a future device time to its own now() (08 §10).
        final pusher = SyncService(
          db: db,
          apiClient: ApiClient(baseUrl: 'http://example.com'),
          tokenStorage: _MemTokenStorage(),
          httpClient: MockClient((req) async {
            expect(req.url.path, '/api/v1/sync/push');
            return _successResponse({
              'results': [
                {
                  'opId': op.opId,
                  'status': 'applied',
                  'response': {
                    'id': row.id,
                    'startingCash': '1500.00',
                    'openedAt': '2019-03-04T02:00:00.000Z',
                    'autoArchived': false,
                  },
                },
              ],
            });
          }),
          autoStartHealthProbe: false,
        );
        addTearDown(pusher.dispose);

        await pusher.push();

        expect(await ops(), isEmpty);
        final local = await (db.select(
          db.shifts,
        )..where((t) => t.id.equals(row.id))).getSingle();
        expect(
          local.openedAt,
          DateTime.parse('2019-03-04T02:00:00.000Z').toLocal(),
        );
      },
    );

    test('Degraded with the drawer closed: refused, nothing written', () async {
      await seedShift('sh-closed', closedAt: DateTime(2019, 3, 4, 18));
      final repo = offlineRepo((_) async => fail('no online call'));
      sync.recordNonVerdictWrite();

      await expectLater(
        () => repo.addDrawerEntry('in', 100, null),
        throwsA(
          isA<PosException>().having((e) => e.code, 'code', 'DRAWER_CLOSED'),
        ),
      );
      expect(await db.select(db.drawerEntries).get(), isEmpty);
      expect(await ops(), isEmpty);
    });
  });

  group('reads delegate to Drift unchanged', () {
    test('getCashDrawer / getShiftHistory read the local cache', () async {
      final repo = buildRepo((req) async {
        fail('reads must not hit the network in this slice');
      });

      expect(await repo.getCashDrawer(), isNull);
      expect(await repo.getShiftHistory(), isEmpty);

      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'local-only',
              dateStr: '2020-01-01',
              startingCash: 10,
              openedAt: DateTime(2020, 1, 1),
              isActive: const Value(true),
            ),
          );

      final drawer = await repo.getCashDrawer();
      expect(drawer!.shift.id, 'local-only');
    });
  });
}
