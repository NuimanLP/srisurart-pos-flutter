// SalePhotosRepository against a fake HTTP layer that follows
// 10_SALE_PHOTO_EVIDENCE.md §4: the PUT carries the caller's id + key
// unchanged on every retry, only a 4xx is a verdict, and an ApiException never
// leaves the repository.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/fake_sale_photos_repository.dart';
import 'package:srisurart_pos/data/repositories/sale_photos_repository.dart';

const _sale = '0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b';
const _photo = '0199d4a2-7c1e-7a3b-9c4d-5e6f7a8b9c0d';
const _key = 'salephoto-$_photo';
const _connection = 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์';

Map<String, dynamic> _photoJson({String id = _photo, int sortOrder = 0}) => {
  'id': id,
  'saleId': _sale,
  'sortOrder': sortOrder,
  'width': 1600,
  'height': 1200,
  'takenAt': '2026-10-12T07:05:11.000Z',
  'createdAt': '2026-10-12T07:05:14.512Z',
};

http.Response _ok(Object data) => http.Response(
  jsonEncode({'status': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _err(int status, String code) => http.Response(
  jsonEncode({
    'status': 'error',
    'error': {'code': code, 'message': 'x'},
  }),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late AppDatabase db;
  late List<http.Request> sent;
  late FutureOr<http.Response> Function(http.Request) reply;
  late ApiSalePhotosRepository repo;
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
  final takenAt = DateTime.utc(2026, 10, 12, 7, 5, 11);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    sent = [];
    reply = (_) => _ok(_photoJson());
    repo = ApiSalePhotosRepository(
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

  Future<SalePhoto> upload({int sortOrder = 0}) => repo.upload(
    saleId: _sale,
    photoId: _photo,
    idempotencyKey: _key,
    bytes: jpeg,
    takenAt: takenAt,
    sortOrder: sortOrder,
  );

  group('upload', () {
    test(
      'PUT raw JPEG to /sales/:saleId/photos/:photoId with the caller\'s key',
      () async {
        final p = await upload(sortOrder: 2);
        final req = sent.single;
        expect(req.method, 'PUT');
        expect(req.url.path, '/api/v1/sales/$_sale/photos/$_photo');
        expect(req.url.queryParameters['takenAt'], '2026-10-12T07:05:11.000Z');
        expect(req.url.queryParameters['sortOrder'], '2');
        expect(req.headers['content-type'], 'image/jpeg');
        expect(req.headers['idempotency-key'], _key);
        expect(req.bodyBytes, jpeg);
        expect(p.id, _photo);
        expect(
          p.sortOrder,
          0,
          reason: 'what the server answers, not what we sent',
        );
      },
    );

    test(
      '5xx keeps the photo pending: retryable, connection sentence, retry resends the SAME id + key',
      () async {
        reply = (_) => http.Response('<html>bad gateway</html>', 502);
        await expectLater(
          upload(),
          throwsA(
            isA<SalePhotoException>()
                .having((e) => e.retryable, 'retryable', isTrue)
                .having((e) => e.message, 'message', _connection),
          ),
        );
        reply = (_) => _ok(_photoJson());
        await upload();
        expect(sent, hasLength(2));
        expect(sent[1].url.path, sent[0].url.path);
        expect(sent[1].headers['idempotency-key'], _key);
        expect(sent[0].headers['idempotency-key'], _key);
      },
    );

    test('429, 503 IN_FLIGHT and 401 are retryable', () async {
      for (final (status, code) in [
        (429, 'RATE_LIMITED'),
        (503, 'IDEMPOTENCY_KEY_IN_FLIGHT'),
        (401, 'UNAUTHORIZED'),
      ]) {
        reply = (_) => _err(status, code);
        await expectLater(
          upload(),
          throwsA(
            isA<SalePhotoException>().having(
              (e) => e.retryable,
              '$status retryable',
              isTrue,
            ),
          ),
        );
      }
    });

    test('4xx is a verdict: not retryable, in Thai', () async {
      for (final (status, code, thai) in [
        (409, 'SALE_PHOTO_LIMIT', 'บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว'),
        (404, 'SALE_NOT_FOUND', 'ไม่พบบิลนี้บนเซิร์ฟเวอร์'),
        (
          400,
          'PRODUCT_IMAGE_INVALID',
          'ไฟล์รูปไม่ถูกต้อง กรุณาใช้รูป JPG, PNG หรือ WebP',
        ),
        (413, 'PRODUCT_IMAGE_TOO_LARGE', 'รูปใหญ่เกิน 3 MB'),
        (409, 'CLIENT_ID_REUSED', 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ'),
      ]) {
        reply = (_) => _err(status, code);
        await expectLater(
          upload(),
          throwsA(
            isA<SalePhotoException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.retryable, '$code retryable', isFalse)
                .having((e) => e.message, '$code message', thai),
          ),
        );
      }
    });

    test('a lost connection is retryable', () async {
      reply = (_) => throw http.ClientException('socket closed');
      await expectLater(
        upload(),
        throwsA(
          isA<SalePhotoException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.message, 'message', _connection),
        ),
      );
    });

    test('an unreadable 200 is retryable (the replay is safe)', () async {
      reply = (_) => _ok('not a photo');
      await expectLater(
        upload(),
        throwsA(
          isA<SalePhotoException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });

    test('no status ever lets an ApiException out', () async {
      for (final status in [400, 401, 403, 404, 409, 413, 429, 500, 502, 503]) {
        reply = (_) => _err(status, 'WHATEVER');
        for (final call in <Future<Object?> Function()>[
          upload,
          () => repo.list(_sale),
          () => repo.bytes(_sale, _photo, SalePhotoVariant.thumb),
        ]) {
          try {
            await call();
            fail('expected a failure for $status');
          } catch (e) {
            expect(e, isA<SalePhotoException>(), reason: 'status $status');
            expect(e, isNot(isA<ApiException>()));
          }
        }
      }
    });
  });

  group('read', () {
    test('list parses SalePhoto[] from GET /sales/:saleId/photos', () async {
      reply = (_) => _ok([_photoJson(), _photoJson(id: 'b', sortOrder: 1)]);
      final photos = await repo.list(_sale);
      expect(sent.single.method, 'GET');
      expect(sent.single.url.path, '/api/v1/sales/$_sale/photos');
      expect(photos.map((p) => p.sortOrder), [0, 1]);
      expect(photos.first.takenAt.toUtc(), takenAt);
      expect(photos.first.createdAt.isAfter(photos.first.takenAt), isTrue);
    });

    test('bytes GETs …/:photoId/(t|p) and returns the raw body', () async {
      reply = (_) => http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'image/webp'},
      );
      expect(await repo.bytes(_sale, _photo, SalePhotoVariant.thumb), [
        1,
        2,
        3,
      ]);
      await repo.bytes(_sale, _photo, SalePhotoVariant.preview);
      expect(sent[0].url.path, '/api/v1/sales/$_sale/photos/$_photo/t');
      expect(sent[1].url.path, '/api/v1/sales/$_sale/photos/$_photo/p');
    });
  });

  group('hasPendingSaleCreate', () {
    Future<void> op(String type, String aggregates) => db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opId: 'op-$type-$aggregates',
            idempotencyKey: 'k',
            type: type,
            payload: '{}',
            aggregates: aggregates,
            createdAt: DateTime.now(),
            status: 'pending',
          ),
        );

    test('true only for a sale.create that names this sale', () async {
      expect(await repo.hasPendingSaleCreate(_sale), isFalse);
      await op('sale.void_offline', jsonEncode(['sale:$_sale']));
      await op('sale.create', jsonEncode(['sale:other']));
      expect(await repo.hasPendingSaleCreate(_sale), isFalse);
      await op('sale.create', jsonEncode(['sale:$_sale', 'shift:s1']));
      expect(await repo.hasPendingSaleCreate(_sale), isTrue);
    });
  });

  group('FakeSalePhotosRepository follows §4.3', () {
    test(
      'replay is 200, other bytes under the same id 409, sixth photo 409',
      () async {
        final fake = FakeSalePhotosRepository();
        Future<SalePhoto> put(String id, Uint8List b, [int order = 0]) =>
            fake.upload(
              saleId: _sale,
              photoId: id,
              idempotencyKey: 'salephoto-$id',
              bytes: b,
              takenAt: takenAt,
              sortOrder: order,
            );
        final first = await put('a', jpeg);
        expect((await put('a', jpeg)).id, first.id);
        await expectLater(
          put('a', Uint8List.fromList([9])),
          throwsA(
            isA<SalePhotoException>().having(
              (e) => e.code,
              'code',
              'CLIENT_ID_REUSED',
            ),
          ),
        );
        for (var i = 1; i < 5; i++) {
          await put('p$i', jpeg, i);
        }
        await expectLater(
          put('p6', jpeg, 4),
          throwsA(
            isA<SalePhotoException>().having(
              (e) => e.code,
              'code',
              'SALE_PHOTO_LIMIT',
            ),
          ),
        );
      },
    );
  });
}
