// Product pictures, client side (owner request 2026-10-10, contract §3/§5):
// the URL helper, where the tenant id comes from, and the online-only
// PUT / DELETE /products/:id/image write path (Idempotency-Key parked on a
// 5xx, Thai on a refusal, only the reply's imageKey written to Drift).

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/core/utils/product_image.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';

const _tenant = '0199c3a0-1111-7abc-8def-0123456789ab';
const _key = 'aaaaaaaabbbbbbbbccccccccdddddddd';
const _key2 = 'eeeeeeeeffffffff0000000011111111';

void main() {
  group('productImageUrl', () {
    test('builds /img/<tenant>/<key>_t.webp and _p.webp under the API origin', () {
      final urls = const ProductImageUrls(
        baseUrl: 'https://172.30.58.20/',
        tenantId: _tenant,
      );
      expect(urls.thumb(_key), 'https://172.30.58.20/img/$_tenant/${_key}_t.webp');
      expect(urls.preview(_key), 'https://172.30.58.20/img/$_tenant/${_key}_p.webp');
    });

    test('web build (empty API base) gets a same-origin relative URL', () {
      expect(
        productImageUrl(baseUrl: '', tenantId: _tenant, imageKey: _key),
        '/img/$_tenant/${_key}_t.webp',
      );
    });

    test('an uppercase tenant id is lowercased (nginx /img/ matches lowercase only)', () {
      expect(
        productImageUrl(baseUrl: '', tenantId: _tenant.toUpperCase(), imageKey: _key),
        '/img/$_tenant/${_key}_t.webp',
      );
    });

    test('no key, or anything but the exact server shapes → null (no request)', () {
      String? url(String? tenant, String? key) =>
          productImageUrl(baseUrl: 'https://h', tenantId: tenant, imageKey: key);
      expect(url(_tenant, null), isNull);
      expect(url(null, _key), isNull);
      expect(url(_tenant, '../../etc/passwd'), isNull);
      expect(url(_tenant, _key.toUpperCase()), isNull);
      expect(url(_tenant, '${_key}0'), isNull);
      expect(url('../$_tenant', _key), isNull);
      expect(url('not-a-uuid', _key), isNull);
    });
  });

  late AppDatabase db;
  late List<http.Request> sent;
  late http.Response Function(http.Request) reply;
  late ApiProductsRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: 'p1',
          partNo: 'HN-01',
          name: 'Oil Filter',
          nameTH: 'กรองน้ำมัน',
          category: 'เครื่องยนต์',
          brand: 'Honda',
          price: 85,
          cost: 45,
          stock: 7,
          minStock: 2,
        ));
    sent = [];
    reply = (_) => http.Response('{}', 200);
    repo = ApiProductsRepository(
      db,
      ApiClient(
        baseUrl: 'https://shop.test',
        httpClient: MockClient((req) async {
          sent.add(req);
          return reply(req);
        }),
      ),
    );
  });

  tearDown(() => db.close());

  http.Response product(String? key, {int stock = 99}) => http.Response(
        jsonEncode({
          'status': 'success',
          'data': {'id': 'p1', 'stock': stock, 'imageKey': key},
        }),
        200,
      );
  http.Response refusal(int status, String code) => http.Response(
        jsonEncode({
          'status': 'error',
          'error': {'code': code, 'message': 'x'},
        }),
        status,
      );
  Future<ProductRow> row() =>
      (db.select(db.products)..where((t) => t.id.equals('p1'))).getSingle();
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);

  group('getImageUrls', () {
    test('Drift build: none', () async {
      expect(await ProductsRepository(db).getImageUrls(), isNull);
    });

    test('API build: none until a tenant is known, then from app_meta + baseUrl',
        () async {
      expect(await repo.getImageUrls(), isNull);
      await db.into(db.appMeta).insert(AppMetaCompanion.insert(
            key: TenantCacheGuard.tenantKey,
            value: _tenant,
          ));
      final urls = await repo.getImageUrls();
      expect(urls!.thumb(_key), 'https://shop.test/img/$_tenant/${_key}_t.webp');
    });
  });

  group('setImage / removeImage', () {
    test('PUT sends the raw JPEG with an Idempotency-Key; only imageKey reaches Drift',
        () async {
      reply = (_) => product(_key);
      await repo.setImage('p1', jpeg);
      final req = sent.single;
      expect(req.method, 'PUT');
      expect(req.url.path, '/api/v1/products/p1/image');
      expect(req.headers['content-type'], 'image/jpeg');
      expect(req.bodyBytes, jpeg);
      expect(req.headers['idempotency-key'], isNotEmpty);
      final r = await row();
      expect(r.imageKey, _key);
      expect(r.stock, 7, reason: 'the reply never overwrites local stock');
    });

    test('DELETE clears the key from the reply', () async {
      await (db.update(db.products)..where((t) => t.id.equals('p1')))
          .write(const ProductsCompanion(imageKey: Value(_key)));
      reply = (_) => product(null);
      await repo.removeImage('p1');
      expect(sent.single.method, 'DELETE');
      expect(sent.single.url.path, '/api/v1/products/p1/image');
      expect(sent.single.headers['idempotency-key'], isNotEmpty);
      expect((await row()).imageKey, isNull);
    });

    test('5xx: connection sentence, key parked — the same picture retries under the same key',
        () async {
      reply = (_) => http.Response('<html>bad gateway</html>', 502);
      await expectLater(
        repo.setImage('p1', jpeg),
        throwsA(isA<PosException>().having(
            (e) => e.message, 'message', 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์')),
      );
      reply = (_) => product(_key);
      await repo.setImage('p1', jpeg);
      expect(sent, hasLength(2));
      expect(sent[1].headers['idempotency-key'], sent[0].headers['idempotency-key']);
      expect((await row()).imageKey, _key);
    });

    test('a different picture after a parked one supersedes it (fresh key)', () async {
      reply = (_) => http.Response('', 503);
      await expectLater(repo.setImage('p1', jpeg), throwsA(isA<PosException>()));
      reply = (_) => product(_key2);
      await repo.setImage('p1', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]));
      expect(sent[1].headers['idempotency-key'],
          isNot(sent[0].headers['idempotency-key']));
    });

    test('4xx refusals reach the screen in Thai and close the attempt', () async {
      for (final (status, code, thai) in [
        (400, 'PRODUCT_IMAGE_INVALID', 'ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP'),
        (413, 'PRODUCT_IMAGE_TOO_LARGE', 'รูปใหญ่เกิน 3 MB'),
        (403, 'OWNER_ONLY', ApiProductsRepository.imageOwnerOnlyMessage),
      ]) {
        reply = (_) => refusal(status, code);
        await expectLater(
          repo.setImage('p1', jpeg),
          throwsA(isA<PosException>().having((e) => e.message, 'message', thai)),
        );
      }
      // Each refusal closed its attempt: three presses, three keys.
      final keys = sent.map((r) => r.headers['idempotency-key']).toSet();
      expect(keys, hasLength(3));
      expect((await row()).imageKey, isNull);
    });

    test('a transport failure is the connection sentence, never an ApiException',
        () async {
      reply = (_) => throw http.ClientException('socket closed');
      await expectLater(
        repo.removeImage('p1'),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'NETWORK_ERROR')),
      );
    });

    test('a 2xx without imageKey is unreadable: nothing written, attempt parked',
        () async {
      reply = (_) => http.Response(jsonEncode({'status': 'success', 'data': {}}), 200);
      await expectLater(repo.setImage('p1', jpeg), throwsA(isA<PosException>()));
      reply = (_) => product(_key);
      await repo.setImage('p1', jpeg);
      expect(sent[1].headers['idempotency-key'], sent[0].headers['idempotency-key']);
    });
  });

  test('Drift build has no upload', () {
    expect(() => ProductsRepository(db).setImage('p1', jpeg),
        throwsUnsupportedError);
    expect(() => ProductsRepository(db).removeImage('p1'), throwsUnsupportedError);
  });
}
