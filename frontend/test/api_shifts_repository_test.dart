// Unit tests for ApiShiftsRepository (#56 fe.3).
//
// Every mock response below carries values the LOCAL client would never
// have produced on its own (a dateStr far from today, an id shaped nothing
// like `newId('sh')`, a note the caller never typed) — on purpose, so a test
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
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';

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

          return _successResponse({
            // A server-issued TEXT id shaped nothing like newId('sh') —
            // proves the id on the local row came off the wire, not
            // `newId('sh')`.
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
            'กะนี้ปิดแล้ว',
          );
        }
      },
    );
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
