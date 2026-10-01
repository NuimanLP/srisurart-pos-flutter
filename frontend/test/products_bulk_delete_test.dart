// Bulk product delete (stock screen): repository rules on both builds.
//
//  • ids an unsent outbox op references are refused up front, with the Thai
//    reason, and never reach delete();
//  • every other id is deleted on its own — one failure does not stop or hide
//    the rest, and is reported per id (server's Thai sentence, or a generic one
//    for a transport failure);
//  • API build: one DELETE per id, each with its OWN Idempotency-Key, and the
//    local soft delete only happens for an id the server accepted.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/sync/outbox_product_refs.dart';

Future<void> _queueOp(
  AppDatabase db,
  String opId, {
  String payload = '{}',
  String aggregates = '[]',
  String status = 'pending',
}) => db
    .into(db.outboxOps)
    .insert(
      OutboxOpsCompanion.insert(
        opId: opId,
        idempotencyKey: 'k-$opId',
        type: 'sale.create',
        payload: payload,
        aggregates: aggregates,
        createdAt: DateTime.utc(2026, 10, 1),
        status: status,
      ),
    );

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('productIdsInOutbox', () {
    test('finds payload productId, product: aggregates and op_effects keys, '
        'for any op status', () async {
      await _queueOp(
        db,
        'op1',
        payload: '{"items":[{"productId":"p1","qty":1}]}',
        status: 'rejected',
      );
      await _queueOp(db, 'op2', aggregates: '["sale:s1","product:p2"]');
      await db
          .into(db.opEffects)
          .insert(
            const OpEffectRow(opId: 'op3', effects: '{"stock":{"p3":-1}}'),
          );
      await _queueOp(db, 'op4', payload: 'not json', aggregates: 'nope');

      expect(await productIdsInOutbox(db), {'p1', 'p2', 'p3'});
    });
  });

  group('ProductsRepository.deleteMany (Drift build)', () {
    test(
      'deletes the free ids, refuses the ones an unsent op references',
      () async {
        final repo = ProductsRepository(db);
        await _queueOp(
          db,
          'op1',
          payload: '{"items":[{"productId":"p2","qty":1}]}',
          status: 'stuck',
        );

        final r = await repo.deleteMany(['p1', 'p2', 'p3']);

        expect(r.deleted, ['p1', 'p3']);
        expect(r.failed, {'p2': productHasUnsyncedOps});
        final left = (await repo.getAll()).map((p) => p.id).toSet();
        expect(left.contains('p1'), isFalse);
        expect(left.contains('p3'), isFalse);
        expect(left.contains('p2'), isTrue);
      },
    );

    test('duplicate ids are deleted once', () async {
      final r = await ProductsRepository(db).deleteMany(['p1', 'p1']);
      expect(r.deleted, ['p1']);
      expect(r.failed, isEmpty);
    });
  });

  group('ApiProductsRepository.deleteMany (API build)', () {
    test('one DELETE + distinct Idempotency-Key per id; partial failure '
        'reported per id; local soft delete only for accepted ids', () async {
      final keys = <String>[];
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add('${req.method} ${req.url.path}');
        keys.add(req.headers['Idempotency-Key'] ?? '');
        if (req.url.path.endsWith('/p2')) {
          return http.Response(
            '{"status":"error","error":{"code":"FORBIDDEN","message":"x"}}',
            403,
            headers: {'content-type': 'application/json'},
          );
        }
        if (req.url.path.endsWith('/p3')) {
          throw http.ClientException('Offline');
        }
        return http.Response(
          '{"status":"success","data":{"deleted":true}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final repo = ApiProductsRepository(db, ApiClient(httpClient: client));

      final r = await repo.deleteMany(['p1', 'p2', 'p3', 'p4']);

      expect(paths, [
        'DELETE /api/v1/products/p1',
        'DELETE /api/v1/products/p2',
        'DELETE /api/v1/products/p3',
        'DELETE /api/v1/products/p4',
      ]);
      expect(keys.every((k) => k.isNotEmpty), isTrue);
      expect(keys.toSet().length, 4, reason: 'a fresh key per product');
      expect(r.deleted, ['p1', 'p4']);
      expect(r.failed.keys, unorderedEquals(['p2', 'p3']));
      // A server refusal is its Thai sentence, never an ApiException string.
      expect(r.failed['p2'], isNot(contains('ApiException')));
      expect(r.failed['p3'], productDeleteFailed);

      Future<DateTime?> deletedAt(String id) async => (await (db.select(
        db.products,
      )..where((t) => t.id.equals(id))).getSingle()).deletedAt;
      expect(await deletedAt('p1'), isNotNull);
      expect(await deletedAt('p4'), isNotNull);
      expect(await deletedAt('p2'), isNull);
      expect(await deletedAt('p3'), isNull);
    });

    test('an outbox-referenced id never reaches the server', () async {
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add(req.url.path);
        return http.Response(
          '{"status":"success","data":{}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await _queueOp(db, 'op1', aggregates: '["product:p5"]');
      final repo = ApiProductsRepository(db, ApiClient(httpClient: client));

      final r = await repo.deleteMany(['p5', 'p6']);

      expect(paths, ['/api/v1/products/p6']);
      expect(r.failed, {'p5': productHasUnsyncedOps});
    });
  });
}
