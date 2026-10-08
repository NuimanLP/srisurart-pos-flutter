// 2026-10-08 — the API build's suppliers: pulled whole from `GET /suppliers`
// into Drift (an owner backup import writes them server-side), edited through
// `POST/PATCH/DELETE /suppliers`, never written locally without the server's
// accepted reply.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_wire.dart' show wireMoney;
import 'package:srisurart_pos/data/repositories/api_suppliers_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';

import 'support/fake_sync_facade.dart';

http.Response _ok(Object data, [int status = 200]) => http.Response(
  jsonEncode({'status': 'success', 'data': data}),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(int status, String code) => http.Response(
  jsonEncode({
    'status': 'error',
    'error': {'code': code, 'message': code},
  }),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object> _wire(String id, String productId, String name,
        [String unitCost = '100.00', String freight = '0.00']) =>
    {
      'id': id,
      'productId': productId,
      'name': name,
      'unitCost': unitCost,
      'freight': freight,
    };

void main() {
  late AppDatabase db;

  Future<void> markPulled() => db.into(db.appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(
            key: ApiSuppliersRepository.suppliersPulledKey, value: '1'),
      );
  Future<bool> isMarked() async =>
      await (db.select(db.appMeta)
            ..where((t) => t.key.equals(ApiSuppliersRepository.suppliersPulledKey)))
          .getSingleOrNull() !=
      null;

  // The demo seed (6 suppliers) stays in: a pull must replace it. Marked as
  // already pulled, so only the 'first pull' group sends local rows up.
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await markPulled();
  });
  tearDown(() => db.close());

  ApiSuppliersRepository repoWith(MockClientHandler handler,
          {SyncFacade? syncFacade}) =>
      ApiSuppliersRepository(db, ApiClient(httpClient: MockClient(handler)),
          syncFacade: syncFacade);

  Future<List<SupplierRow>> local() => db.select(db.suppliers).get();

  group('pullFromServer', () {
    test('GET /suppliers replaces the whole Drift table', () async {
      expect(await local(), hasLength(6));
      final seen = <String>[];
      final repo = repoWith((req) async {
        seen.add('${req.method} ${req.url.path}');
        return _ok([
          _wire('s1', 'p1', 'จิ้นเซ่งฮวดอะไหล่ยนต์', '100.00', '0.00'),
          _wire('s2', 'p2', 'ร้านสอง', '85.50', '12.25'),
        ]);
      });

      expect(await repo.pullFromServer(), isTrue);

      expect(seen, ['GET /api/v1/suppliers']);
      final rows = {for (final r in await local()) r.id: r};
      expect(rows.keys, unorderedEquals(['s1', 's2']));
      expect(rows['s2']!.productId, 'p2');
      expect(rows['s2']!.unitCost, 85.5);
      expect(rows['s2']!.freight, 12.25);
      expect(await repo.getSuppliersForProduct('p1'), hasLength(1));
    });

    test('an empty server set empties the cache', () async {
      final repo = repoWith((_) async => _ok(<Object>[]));
      expect(await repo.pullFromServer(), isTrue);
      expect(await local(), isEmpty);
    });

    test('a failure leaves the cache as it was and never throws', () async {
      final before = await local();
      for (final handler in <MockClientHandler>[
        (_) async => throw http.ClientException('down'),
        (_) async => _error(500, 'INTERNAL_ERROR'),
        (_) async => _ok({'not': 'a list'}),
        (_) async => _ok([{'id': 's1'}]), // unreadable row
      ]) {
        expect(await repoWith(handler).pullFromServer(), isFalse);
        expect(await local(), before);
      }
    });

    test('getSuppliers pulls first, then reads Drift', () async {
      final repo = repoWith((_) async => _ok([_wire('s9', 'p1', 'ใหม่')]));
      final rows = await repo.getSuppliers();
      expect(rows.map((r) => r.id), ['s9']);
    });

    test('Degraded: getSuppliers answers the cache without a request', () async {
      var requests = 0;
      final repo = repoWith(
        (_) async {
          requests++;
          return _ok(<Object>[]);
        },
        syncFacade: FakeSyncFacade(initialStatus: SyncStatus.degraded),
      );
      expect(await repo.getSuppliers(), hasLength(6));
      expect(requests, 0);
    });

    test('offline: getSuppliers still answers the cache', () async {
      final repo = repoWith((_) async => throw http.ClientException('down'));
      expect(await repo.getSuppliers(), hasLength(6));
    });

    test('a reply from before a tenant reset writes nothing', () async {
      final reply = Completer<http.Response>();
      final repo = repoWith((_) => reply.future);
      final pull = repo.pullFromServer();
      await Future<void>.delayed(Duration.zero);
      db.fenceCacheWrites();
      reply.complete(_ok([_wire('old-shop', 'p1', 'ร้านเก่า')]));

      expect(await pull, isFalse);
      expect(await local(), hasLength(6));
    });

    test('a pull that started before a write does not drop the written row', () async {
      final getReply = Completer<http.Response>();
      final repo = repoWith((req) {
        if (req.method == 'GET') return getReply.future;
        return Future.value(_ok(_wire('s-new', 'p1', 'เพิ่มใหม่'), 201));
      });
      final pull = repo.pullFromServer();
      await Future<void>.delayed(Duration.zero);
      await repo.addSupplier(productId: 'p1', name: 'เพิ่มใหม่', unitCost: 10);
      getReply.complete(_ok(<Object>[])); // the snapshot from before the add

      expect(await pull, isFalse);
      expect((await local()).map((r) => r.id), contains('s-new'));
    });
  });

  group('first pull: local-only suppliers are sent up before the replace', () {
    setUp(() => (db.delete(db.appMeta)
          ..where((t) => t.key.equals(ApiSuppliersRepository.suppliersPulledKey)))
        .go());

    test('each one is POSTed under a key from its id; then replace + marker', () async {
      final seed = await local();
      final posts = <String, Object?>{}; // key → body
      final repo = repoWith((req) async {
        if (req.method == 'GET') {
          // s-srv is the server's own; seed[0] is already there under its id.
          return _ok([
            _wire('s-srv', 'p9', 'ของเซิร์ฟเวอร์'),
            _wire(seed[0].id, seed[0].productId, seed[0].name),
          ]);
        }
        final key = req.headers['Idempotency-Key']!;
        final body = jsonDecode(req.body) as Map;
        posts[key] = body;
        return _ok(
            _wire('new-${key.substring(12)}', body['productId'] as String,
                body['name'] as String, body['unitCost'] as String),
            201);
      });

      expect(await repo.pullFromServer(), isTrue);

      final sent = seed.skip(1).toList();
      expect(posts.keys,
          unorderedEquals([for (final r in sent) 'idem-supmig-${r.id}']));
      expect(posts['idem-supmig-${sent.first.id}'], {
        'productId': sent.first.productId,
        'name': sent.first.name,
        'unitCost': wireMoney(sent.first.unitCost),
        'freight': wireMoney(sent.first.freight),
      });
      expect((await local()).map((r) => r.id), unorderedEquals([
        's-srv',
        seed[0].id,
        for (final r in sent) 'new-${r.id}',
      ]));
      expect(await isMarked(), isTrue);

      // Marked: the next pull is a plain replace, nothing is sent again.
      posts.clear();
      expect(await repo.pullFromServer(), isTrue);
      expect(posts, isEmpty);
    });

    test('no verdict (5xx / no network): the row stays, no marker, the retry reuses its key',
        () async {
      final seed = await local();
      final failing = seed.first.id;
      final keys = <String>[];
      var fail = true;
      final repo = repoWith((req) async {
        if (req.method == 'GET') return _ok(<Object>[]);
        final key = req.headers['Idempotency-Key']!;
        keys.add(key);
        if (fail && key == 'idem-supmig-$failing') {
          return _error(503, 'SERVICE_UNAVAILABLE');
        }
        final body = jsonDecode(req.body) as Map;
        return _ok(
            _wire('new-${key.substring(12)}', body['productId'] as String,
                body['name'] as String),
            201);
      });

      expect(await repo.pullFromServer(), isTrue);
      final ids = (await local()).map((r) => r.id).toSet();
      expect(ids, contains(failing)); // kept, not deleted
      expect(ids, isNot(contains('new-$failing')));
      expect(await isMarked(), isFalse);

      fail = false;
      keys.clear();
      expect(await repo.pullFromServer(), isTrue);
      // Only the kept row was local-only this time, under the same key.
      expect(keys, contains('idem-supmig-$failing'));
      expect((await local()).map((r) => r.id), contains('new-$failing'));
      expect(await isMarked(), isTrue);
    });

    test('a 401 says nothing about the row: it is kept', () async {
      final repo = repoWith((req) async {
        if (req.method == 'GET') return _ok(<Object>[]);
        return _error(401, 'UNAUTHENTICATED');
      });
      expect(await repo.pullFromServer(), isTrue);
      expect(await local(), hasLength(6));
      expect(await isMarked(), isFalse);
    });

    test('a 404 (no such product on the server) is final: the row is let go and the marker is set', () async {
      final repo = repoWith((req) async {
        if (req.method == 'GET') return _ok(<Object>[]);
        return _error(404, 'PRODUCT_NOT_FOUND');
      });

      expect(await repo.pullFromServer(), isTrue);
      expect(await local(), isEmpty);
      expect(await isMarked(), isTrue);
    });
  });

  group('addSupplier', () {
    test('POST /suppliers with money as strings; Drift gets the server row', () async {
      late http.Request sent;
      final repo = repoWith((req) async {
        sent = req;
        return _ok(_wire('srv-id', 'p3', 'ร้านใหม่', '85.00', '5.00'), 201);
      });

      final row = await repo.addSupplier(
        productId: 'p3',
        name: 'ร้านใหม่',
        unitCost: 85,
        freight: 5,
      );

      expect('${sent.method} ${sent.url.path}', 'POST /api/v1/suppliers');
      expect(sent.headers['Idempotency-Key'], isNotEmpty);
      expect(jsonDecode(sent.body), {
        'productId': 'p3',
        'name': 'ร้านใหม่',
        'unitCost': '85.00',
        'freight': '5.00',
      });
      expect(row.id, 'srv-id'); // the server mints the id
      final stored = await repo.getSuppliersForProduct('p3');
      expect(stored.single.id, 'srv-id');
      expect(stored.single.unitCost, 85);
    });

    test('a 5xx is no verdict: no local write, and the retry reuses the key', () async {
      final keys = <String?>[];
      var status = 503;
      final repo = repoWith((req) async {
        keys.add(req.headers['Idempotency-Key']);
        if (status != 201) return _error(status, 'SERVICE_UNAVAILABLE');
        return _ok(_wire('srv-id', 'p3', 'ร้านใหม่'), 201);
      });
      final before = await local();

      await expectLater(
        repo.addSupplier(productId: 'p3', name: 'ร้านใหม่', unitCost: 100),
        throwsA(isA<PosException>()),
      );
      expect(await local(), before);

      status = 201;
      await repo.addSupplier(productId: 'p3', name: 'ร้านใหม่', unitCost: 100);
      expect(keys, hasLength(2));
      expect(keys[1], keys[0]);

      // Settled: the same supplier pressed again is a new action.
      await repo.addSupplier(productId: 'p3', name: 'ร้านใหม่', unitCost: 100);
      expect(keys[2], isNot(keys[0]));
    });

    test('a 4xx is a verdict: the next press mints a new key', () async {
      final keys = <String?>[];
      final repo = repoWith((req) async {
        keys.add(req.headers['Idempotency-Key']);
        return _error(404, 'PRODUCT_NOT_FOUND');
      });
      for (var i = 0; i < 2; i++) {
        await expectLater(
          repo.addSupplier(productId: 'gone', name: 'x', unitCost: 1),
          throwsA(isA<PosException>()),
        );
      }
      expect(keys[1], isNot(keys[0]));
    });

    test('no network: the Thai connection sentence and no local write', () async {
      final before = await local();
      final repo = repoWith((_) async => throw http.ClientException('down'));
      await expectLater(
        repo.addSupplier(productId: 'p3', name: 'x', unitCost: 1),
        throwsA(
          isA<PosException>().having(
            (e) => e.toString(),
            'message',
            'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
          ),
        ),
      );
      expect(await local(), before);
    });
  });

  group('updateSupplier', () {
    test('PATCH sends only the set fields; Drift takes the reply', () async {
      final id = (await local()).first.id;
      late http.Request sent;
      final repo = repoWith((req) async {
        sent = req;
        return _ok(_wire(id, 'p1', 'ชื่อเดิม', '80.00', '0.00'));
      });

      await repo.updateSupplier(id, unitCost: const Value(80));

      expect('${sent.method} ${sent.url.path}', 'PATCH /api/v1/suppliers/$id');
      expect(sent.headers['Idempotency-Key'], isNotEmpty);
      expect(jsonDecode(sent.body), {'unitCost': '80.00'});
      final row = (await local()).firstWhere((r) => r.id == id);
      expect(row.unitCost, 80);
      expect(row.name, 'ชื่อเดิม');
    });

    test('a refusal leaves the row alone', () async {
      final before = await local();
      final repo = repoWith((_) async => _error(404, 'SUPPLIER_NOT_FOUND'));
      await expectLater(
        repo.updateSupplier(before.first.id, name: const Value('x')),
        throwsA(isA<PosException>()),
      );
      expect(await local(), before);
    });
  });

  group('deleteSupplier', () {
    test('DELETE first, then the Drift row goes', () async {
      final id = (await local()).first.id;
      late http.Request sent;
      final repo = repoWith((req) async {
        sent = req;
        return _ok({'id': id, 'deleted': true});
      });

      await repo.deleteSupplier(id);

      expect('${sent.method} ${sent.url.path}', 'DELETE /api/v1/suppliers/$id');
      expect(sent.headers['Idempotency-Key'], isNotEmpty);
      expect((await local()).map((r) => r.id), isNot(contains(id)));
    });

    test('a failure keeps the row', () async {
      final before = await local();
      final repo = repoWith((_) async => _error(500, 'INTERNAL_ERROR'));
      await expectLater(
        repo.deleteSupplier(before.first.id),
        throwsA(isA<PosException>()),
      );
      expect(await local(), before);
    });
  });
}
