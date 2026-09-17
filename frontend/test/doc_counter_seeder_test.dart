// #188 — seeding the local document-number counter from GET /doc-counters.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/services/doc_counter_seeder.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode({'status': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _dev = 'dv_demo_1';

Map<String, Object> _reply(
  List<Map<String, Object>> counters, {
  String deviceId = _dev,
  int deviceNo = 1,
}) => {
  'deviceId': deviceId,
  'deviceNo': deviceNo,
  'period': '2569-09',
  'counters': counters,
};

void main() {
  late AppDatabase db;
  late List<http.Request> requests;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    requests = [];
  });

  tearDown(() async {
    await db.close();
  });

  DocCounterSeeder seederReplying(
    Future<http.Response> Function(http.Request) reply,
  ) => DocCounterSeeder(
    db: db,
    apiClient: ApiClient(
      httpClient: MockClient((r) {
        requests.add(r);
        return reply(r);
      }),
    ),
  );

  Future<void> putLocal(String docType, String period, int lastNo) => db
      .into(db.docCounters)
      .insert(
        DocCountersCompanion.insert(
          deviceId: _dev,
          deviceNo: 1,
          docType: docType,
          period: period,
          lastNo: lastNo,
        ),
      );

  Future<Map<String, int>> localCounters() async => {
    for (final r in await db.select(db.docCounters).get())
      '${r.deviceId}#${r.deviceNo}/${r.docType}/${r.period}': r.lastNo,
  };

  Future<List<String>> seedMarkers() async => [
    for (final s in await db.select(db.docCounterSeeds).get())
      '${s.deviceId}/${s.period}',
  ];

  test('local = max(local, server) per row, and the period is recorded as seeded', () async {
    await putLocal('receipt', '2569-09', 50); // local ahead: kept
    await putLocal('cn', '2569-09', 2); // server ahead: raised
    await putLocal('receipt', '2569-08', 10); // absent on server: untouched

    final seeder = seederReplying(
      (_) async => _ok(
        _reply([
          {'docType': 'receipt', 'period': '2569-09', 'lastNo': 42},
          {'docType': 'cn', 'period': '2569-09', 'lastNo': 7},
          {'docType': 'po', 'period': '2569-09', 'lastNo': 3}, // new row
        ]),
      ),
    );

    expect(await seeder.seed(), isTrue);

    expect(await localCounters(), {
      '$_dev#1/receipt/2569-09': 50,
      '$_dev#1/cn/2569-09': 7,
      '$_dev#1/receipt/2569-08': 10,
      '$_dev#1/po/2569-09': 3,
    });
    expect(await seedMarkers(), ['$_dev/2569-09']);

    // The device comes from the token on the server — nothing names it here.
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/v1/doc-counters');
    expect(requests.single.url.query, isEmpty);
  });

  test('seeding twice is harmless and still never lowers', () async {
    final seeder = seederReplying(
      (_) async => _ok(
        _reply([
          {'docType': 'receipt', 'period': '2569-09', 'lastNo': 5},
        ]),
      ),
    );
    expect(await seeder.seed(), isTrue);
    await (db.update(db.docCounters)).write(
      const DocCountersCompanion(lastNo: Value(9)),
    );
    expect(await seeder.seed(), isTrue);

    expect(await localCounters(), {'$_dev#1/receipt/2569-09': 9});
    expect(await seedMarkers(), hasLength(1));
  });

  // The reviewer's probe: a browser seeded as device no 1 of the demo tenant,
  // then re-enrolled into the real shop as ITS device no 1.
  test('a re-enrolled device with the same deviceNo inherits no counter and no seed marker', () async {
    expect(
      await seederReplying(
        (_) async => _ok(
          _reply([
            {'docType': 'receipt', 'period': '2569-09', 'lastNo': 500},
          ], deviceId: 'dv_demo_1'),
        ),
      ).seed(),
      isTrue,
    );

    // The new device's first seed fails: nothing may say its period is seeded.
    expect(
      await seederReplying(
        (_) async => throw http.ClientException('offline'),
      ).seed(),
      isFalse,
    );
    Future<List<DocCounterSeedRow>> markersOfNew() => (db.select(
      db.docCounterSeeds,
    )..where((t) => t.deviceId.equals('dv_shop_1'))).get();
    expect(await markersOfNew(), isEmpty);

    // Its real seed: the demo tenant's 500 must not win the max.
    expect(
      await seederReplying(
        (_) async => _ok(
          _reply([
            {'docType': 'receipt', 'period': '2569-09', 'lastNo': 3},
          ], deviceId: 'dv_shop_1'),
        ),
      ).seed(),
      isTrue,
    );
    final newRows = await (db.select(
      db.docCounters,
    )..where((t) => t.deviceId.equals('dv_shop_1'))).get();
    expect(newRows.map((r) => (r.docType, r.period, r.lastNo)), [
      ('receipt', '2569-09', 3),
    ]);
    expect(await markersOfNew(), hasLength(1));
  });

  group('a failed fetch leaves local untouched and does not throw', () {
    final failures = <String, Future<http.Response> Function(http.Request)>{
      'transport failure': (_) async => throw http.ClientException('offline'),
      '5xx': (_) async => http.Response('<html>502</html>', 502),
      '403 refusal': (_) async => http.Response(
        jsonEncode({
          'status': 'error',
          'error': {'code': 'DEVICE_ROLE_FORBIDDEN', 'message': 'x'},
        }),
        403,
      ),
      'malformed counter after a valid one': (_) async => _ok(
        _reply([
          {'docType': 'receipt', 'period': '2569-09', 'lastNo': 99},
          {'docType': 'cn', 'period': '2569-09', 'lastNo': '7'},
        ]),
      ),
      'missing deviceId': (_) async =>
          _ok({'deviceNo': 1, 'period': '2569-09', 'counters': []}),
    };

    for (final entry in failures.entries) {
      test(entry.key, () async {
        await putLocal('receipt', '2569-09', 4);

        final ok = await seederReplying(entry.value).seed();

        expect(ok, isFalse);
        expect(await localCounters(), {'$_dev#1/receipt/2569-09': 4});
        expect(await seedMarkers(), isEmpty);
      });
    }
  });

  // A write that fails inside the local transaction rolls back every write of
  // that seed. Two failure points, so that neither moving the marker insert out
  // of the transaction (after the counters) nor ahead of it passes.
  group('a failure mid-transaction leaves no marker and no partial counters', () {
    final triggers = {
      'the marker insert fails':
          'CREATE TRIGGER boom BEFORE INSERT ON doc_counter_seeds '
          "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      'the second counter fails':
          'CREATE TRIGGER boom BEFORE INSERT ON doc_counters '
          "WHEN NEW.doc_type = 'cn' BEGIN SELECT RAISE(ABORT, 'boom'); END",
    };

    for (final entry in triggers.entries) {
      test(entry.key, () async {
        await db.customStatement(entry.value);

        final ok = await seederReplying(
          (_) async => _ok(
            _reply([
              {'docType': 'receipt', 'period': '2569-09', 'lastNo': 42},
              {'docType': 'cn', 'period': '2569-09', 'lastNo': 7},
            ]),
          ),
        ).seed();

        expect(ok, isFalse);
        expect(await localCounters(), isEmpty);
        expect(await seedMarkers(), isEmpty);
      });
    }
  });
}
