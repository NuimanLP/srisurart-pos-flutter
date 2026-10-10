// QR payment accounts (owner request 2026-10-10, contract §5): the Drift
// build's local CRUD, and the API build's online-only writes / whole-table pull.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_payment_accounts_repository.dart';
import 'package:srisurart_pos/data/repositories/payment_accounts_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/repositories/snapshot_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

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

Map<String, Object?> _wire(
  String id, {
  String nickname = 'บัญชีร้าน',
  String kind = 'promptpay',
  String? promptpayId = '0812345678',
  String? imageBase64,
  bool isDefault = false,
  int sortOrder = 0,
}) =>
    {
      'id': id,
      'nickname': nickname,
      'bankCode': 'KBANK',
      'kind': kind,
      'promptpayId': promptpayId,
      'imageBase64': imageBase64,
      'imageMime': imageBase64 == null ? null : 'image/png',
      'isDefault': isDefault,
      'sortOrder': sortOrder,
      'updatedAt': '2026-10-10T03:00:00.000Z',
    };

PaymentAccountInput _pp(String nickname, {bool isDefault = false}) =>
    PaymentAccountInput(
      nickname: nickname,
      bankCode: 'KBANK',
      kind: 'promptpay',
      promptpayId: '0812345678',
      isDefault: isDefault,
    );

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<List<PaymentAccountRow>> local() =>
      PaymentAccountsRepository(db).getAccounts();

  group('PaymentAccountsRepository (Drift build)', () {
    test('adds in order, keeps one default, refuses a sixth', () async {
      final repo = PaymentAccountsRepository(db);
      expect(repo.ownerOnly, isFalse);
      await repo.addAccount(_pp('หนึ่ง', isDefault: true));
      final two = await repo.addAccount(_pp('สอง', isDefault: true));
      for (final n in ['สาม', 'สี่', 'ห้า']) {
        await repo.addAccount(_pp(n));
      }
      final rows = await local();
      expect(rows.map((r) => r.nickname), ['หนึ่ง', 'สอง', 'สาม', 'สี่', 'ห้า']);
      expect(rows.where((r) => r.isDefault).map((r) => r.id), [two.id]);
      expect(defaultPaymentAccount(rows)!.id, two.id);

      await expectLater(
        repo.addAccount(_pp('หก')),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'PAYMENT_ACCOUNT_LIMIT')
            .having((e) => e.message, 'message', paymentAccountLimitMessage)),
      );
      expect(await local(), hasLength(maxPaymentAccounts));
    });

    test('validates like the server: nickname, bank, PromptPay id, image', () async {
      final repo = PaymentAccountsRepository(db);
      for (final bad in [
        const PaymentAccountInput(nickname: '  ', bankCode: 'KBANK', kind: 'promptpay', promptpayId: '0812345678'),
        const PaymentAccountInput(nickname: 'x', bankCode: 'NOPE', kind: 'promptpay', promptpayId: '0812345678'),
        const PaymentAccountInput(nickname: 'x', bankCode: 'KBANK', kind: 'promptpay', promptpayId: '12345'),
        const PaymentAccountInput(nickname: 'x', bankCode: 'KBANK', kind: 'image'),
        PaymentAccountInput(
          nickname: 'x',
          bankCode: 'KBANK',
          kind: 'image',
          image: Uint8List(maxQrImageBytes + 1),
          imageMime: 'image/png',
        ),
      ]) {
        await expectLater(repo.addAccount(bad), throwsA(isA<PosException>()));
      }
      expect(await local(), isEmpty);
    });

    test('setDefault moves the default; delete leaves none and checkout falls back to the first',
        () async {
      final repo = PaymentAccountsRepository(db);
      final a = await repo.addAccount(_pp('หนึ่ง', isDefault: true));
      final b = await repo.addAccount(_pp('สอง'));
      await repo.setDefault(b.id);
      var rows = await local();
      expect(rows.firstWhere((r) => r.id == a.id).isDefault, isFalse);
      expect(rows.firstWhere((r) => r.id == b.id).isDefault, isTrue);

      await repo.deleteAccount(b.id);
      rows = await local();
      expect(rows.map((r) => r.id), [a.id]);
      expect(rows.single.isDefault, isFalse);
      expect(defaultPaymentAccount(rows)!.id, a.id);
      expect(defaultPaymentAccount(const []), isNull);
    });

    test('an edit never changes the kind', () async {
      final repo = PaymentAccountsRepository(db);
      final a = await repo.addAccount(_pp('หนึ่ง'));
      await repo.updateAccount(
        a.id,
        const PaymentAccountsCompanion(nickname: Value('ใหม่'), kind: Value('image')),
      );
      final row = (await local()).single;
      expect(row.nickname, 'ใหม่');
      expect(row.kind, 'promptpay');
    });

    test('saveSale stores the account for โอน/QR only', () async {
      await db.into(db.products).insert(ProductsCompanion.insert(
            id: 'tp1',
            partNo: 'TP-1',
            name: 'Pad',
            nameTH: 'ผ้าเบรก',
            category: 'เบรก',
            brand: 'X',
            price: 100,
            cost: 60,
            stock: 10,
            minStock: 1,
          ));
      SaleInput sale(String method) => SaleInput(
            subtotal: 100,
            discount: 0,
            total: 100,
            paymentMethod: method,
            paymentAccountId: 'pa1',
            items: const [SaleLineInput(productId: 'tp1', name: 'Pad', qty: 1, price: 100)],
          );
      final qr = await SalesRepository(db).saveSale(sale('โอน/QR'));
      final cash = await SalesRepository(db).saveSale(sale('เงินสด'));
      final rows = {for (final s in await db.select(db.sales).get()) s.id: s};
      expect(rows[qr.id]!.paymentAccountId, 'pa1');
      expect(rows[cash.id]!.paymentAccountId, isNull);
    });
  });

  group('ApiPaymentAccountsRepository (API build)', () {
    ApiPaymentAccountsRepository repoWith(
      MockClientHandler handler, {
      SyncFacade? syncFacade,
    }) =>
        ApiPaymentAccountsRepository(
          db,
          ApiClient(httpClient: MockClient(handler)),
          syncFacade: syncFacade,
        );

    test('GET /payment-accounts replaces the cache; a deleted account leaves it', () async {
      final png = base64Encode([0x89, 0x50, 0x4E, 0x47]);
      var reply = [
        _wire('pa1', isDefault: true),
        _wire('pa2', kind: 'image', promptpayId: null, imageBase64: png, sortOrder: 1),
      ];
      final repo = repoWith((req) async {
        expect('${req.method} ${req.url.path}', 'GET /api/v1/payment-accounts');
        return _ok(reply);
      });
      expect(repo.ownerOnly, isTrue);
      expect(await repo.pullFromServer(), isTrue);
      var rows = await local();
      expect(rows.map((r) => r.id), ['pa1', 'pa2']);
      expect(rows[1].image, [0x89, 0x50, 0x4E, 0x47]);
      expect(rows[1].imageMime, 'image/png');

      reply = [_wire('pa2', kind: 'image', promptpayId: null, imageBase64: png)];
      expect(await repo.pullFromServer(), isTrue);
      rows = await local();
      expect(rows.map((r) => r.id), ['pa2']);
    });

    test('a failed or malformed pull leaves the cache and never throws', () async {
      await repoWith((_) async => _ok([_wire('pa1')])).pullFromServer();
      for (final handler in <MockClientHandler>[
        (_) async => throw http.ClientException('down'),
        (_) async => _error(500, 'INTERNAL_ERROR'),
        (_) async => _ok({'not': 'a list'}),
        (_) async => _ok([{'id': 'pa9'}]),
      ]) {
        expect(await repoWith(handler).pullFromServer(), isFalse);
        expect((await local()).map((r) => r.id), ['pa1']);
      }
    });

    test('add: POST with a client id and key; Drift written from the reply, other defaults cleared',
        () async {
      await repoWith((_) async => _ok([_wire('pa-old', isDefault: true)])).pullFromServer();
      late http.Request sent;
      final repo = repoWith((req) async {
        sent = req;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return _ok(_wire(body['id'] as String, nickname: 'สาขา 2', isDefault: true), 201);
      });
      final row = await repo.addAccount(_pp('สาขา 2', isDefault: true));

      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/v1/payment-accounts');
      expect(sent.headers['Idempotency-Key'], isNotEmpty);
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['id'], row.id);
      expect(body['kind'], 'promptpay');
      expect(body['promptpayId'], '0812345678');
      expect(body['isDefault'], isTrue);
      final rows = {for (final r in await local()) r.id: r};
      expect(rows[row.id]!.isDefault, isTrue);
      expect(rows['pa-old']!.isDefault, isFalse);
    });

    test('a 5xx writes nothing and the retry reuses the SAME id and key', () async {
      final bodies = <Map<String, dynamic>>[];
      final keys = <String?>[];
      var attempt = 0;
      final repo = repoWith((req) async {
        attempt++;
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        keys.add(req.headers['Idempotency-Key']);
        if (attempt == 1) return _error(502, 'BAD_GATEWAY');
        return _ok(_wire(bodies.last['id'] as String), 201);
      });
      await expectLater(repo.addAccount(_pp('ร้าน')), throwsA(isA<PosException>()));
      expect(await local(), isEmpty);
      await repo.addAccount(_pp('ร้าน'));
      expect(bodies[0]['id'], bodies[1]['id']);
      expect(keys[0], keys[1]);
      expect(await local(), hasLength(1));
    });

    test('a 4xx verdict closes the attempt: the next press is a new id and key', () async {
      final keys = <String?>[];
      final repo = repoWith((req) async {
        keys.add(req.headers['Idempotency-Key']);
        return _error(409, 'PAYMENT_ACCOUNT_LIMIT');
      });
      for (var i = 0; i < 2; i++) {
        await expectLater(
          repo.addAccount(_pp('ร้าน')),
          throwsA(isA<PosException>()
              .having((e) => e.message, 'message', paymentAccountLimitMessage)),
        );
      }
      expect(keys.toSet(), hasLength(2));
    });

    test('a 4xx keeps its Thai verdict; a 5xx shows the connection sentence, never the server text',
        () async {
      http.Response raw(int status, String code, String message) => http.Response(
            jsonEncode({
              'status': 'error',
              'error': {'code': code, 'message': message},
            }),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
      final cases = <http.Response, String>{
        raw(409, 'PAYMENT_ACCOUNT_LIMIT', 'limit'): paymentAccountLimitMessage,
        raw(403, 'OWNER_ONLY', 'owner only'): paymentAccountOwnerOnlyMessage,
        raw(409, 'CLIENT_ID_REUSED', 'reused'): 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
        raw(404, 'NOT_FOUND', 'Payment account not found'): paymentAccountGoneMessage,
        raw(400, 'BAD_REQUEST', 'nickname is required'):
            'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่',
        raw(500, 'INTERNAL_ERROR', 'Internal server error'):
            'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
        raw(502, 'BAD_GATEWAY', '<html>bad gateway</html>'):
            'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
      };
      for (final MapEntry(key: reply, value: thai) in cases.entries) {
        final repo = repoWith((_) async => reply);
        for (final write in <Future<Object?> Function()>[
          () => repo.addAccount(_pp('ร้าน')),
          () => repo.updateAccount('pa1', const PaymentAccountsCompanion(nickname: Value('x'))),
          () => repo.deleteAccount('pa1'),
        ]) {
          await expectLater(
            write(),
            throwsA(isA<PosException>().having((e) => e.message, 'message', thai)),
            reason: '${reply.statusCode}',
          );
        }
      }
    });

    test('Degraded: every write is refused before the network', () async {
      final repo = repoWith(
        (_) async => fail('no request while Degraded'),
        syncFacade: FakeSyncFacade(initialStatus: SyncStatus.degraded),
      );
      for (final write in <Future<Object?> Function()>[
        () => repo.addAccount(_pp('ร้าน')),
        () => repo.updateAccount('pa1', const PaymentAccountsCompanion(nickname: Value('x'))),
        () => repo.setDefault('pa1'),
        () => repo.deleteAccount('pa1'),
      ]) {
        await expectLater(
          write(),
          throwsA(isA<PosException>()
              .having((e) => e.message, 'message', paymentAccountsOfflineRefusal)),
        );
      }
      // The read side answers from the cache without a request.
      expect(await repo.getLatestAccounts(), isEmpty);
    });

    test('PATCH sends only the set fields; a different newer edit gets a fresh key', () async {
      await repoWith((_) async => _ok([_wire('pa1')])).pullFromServer();
      final sent = <http.Request>[];
      var fail502 = true;
      final repo = repoWith((req) async {
        sent.add(req);
        if (fail502) return _error(502, 'BAD_GATEWAY');
        return _ok(_wire('pa1', nickname: 'ล่าสุด'));
      });
      await expectLater(
        repo.updateAccount('pa1', const PaymentAccountsCompanion(nickname: Value('แรก'))),
        throwsA(isA<PosException>()),
      );
      fail502 = false;
      await repo.updateAccount('pa1', const PaymentAccountsCompanion(nickname: Value('ล่าสุด')));
      expect(sent[0].method, 'PATCH');
      expect(sent[0].url.path, '/api/v1/payment-accounts/pa1');
      expect(jsonDecode(sent[1].body), {'nickname': 'ล่าสุด'});
      expect(sent[0].headers['Idempotency-Key'], isNot(sent[1].headers['Idempotency-Key']));
      expect((await local()).single.nickname, 'ล่าสุด');
    });

    test('DELETE removes the row only after the server accepted it', () async {
      await repoWith((_) async => _ok([_wire('pa1'), _wire('pa2')])).pullFromServer();
      await expectLater(
        repoWith((_) async => _error(403, 'OWNER_ONLY')).deleteAccount('pa1'),
        throwsA(isA<PosException>()
            .having((e) => e.message, 'message', paymentAccountOwnerOnlyMessage)),
      );
      expect(await local(), hasLength(2));
      late http.Request sent;
      await repoWith((req) async {
        sent = req;
        return _ok({'id': 'pa1'});
      }).deleteAccount('pa1');
      expect(sent.method, 'DELETE');
      expect(sent.headers['Idempotency-Key'], isNotEmpty);
      expect((await local()).map((r) => r.id), ['pa2']);
    });

    test('a tenant cache reset and the pulled-cache reset both empty the table', () async {
      await repoWith((_) async => _ok([_wire('pa1')])).pullFromServer();
      await db.resetTenantCache();
      expect(await local(), isEmpty);
      await repoWith((_) async => _ok([_wire('pa1')])).pullFromServer();
      await db.resetPulledCache(keepStockAndLedgers: true);
      expect(await local(), isEmpty);
    });

    test('a pull that lands after a tenant reset writes nothing', () async {
      late ApiPaymentAccountsRepository repo;
      repo = repoWith((_) async {
        await db.resetTenantCache();
        return _ok([_wire('pa-old-shop')]);
      });
      expect(await repo.pullFromServer(), isFalse);
      expect(await local(), isEmpty);
    });
  });

  group('backup (sa_payment_accounts, the server\'s tenant-backup key)', () {
    test('export → import keeps the accounts, the image and each bill\'s account', () async {
      final repo = PaymentAccountsRepository(db);
      final a = await repo.addAccount(_pp('บัญชีร้าน', isDefault: true));
      await repo.addAccount(PaymentAccountInput(
        nickname: 'รูป QR',
        bankCode: 'SCB',
        kind: 'image',
        image: Uint8List.fromList([1, 2, 3]),
        imageMime: 'image/png',
      ));
      final p = (await db.select(db.products).get()).first;
      final sale = await SalesRepository(db).saveSale(SaleInput(
        subtotal: p.price,
        discount: 0,
        total: p.price,
        paymentMethod: 'โอน/QR',
        paymentAccountId: a.id,
        items: [SaleLineInput(productId: p.id, name: p.name, qty: 1, price: p.price)],
      ));

      final snap = await SnapshotRepository(db).exportSnapshot();
      final store = snap['sa_payment_accounts'] as List;
      expect(store, hasLength(2));
      expect((store[1] as Map)['imageBase64'], base64Encode([1, 2, 3]));
      expect(((snap['__meta'] as Map)['recordCounts'] as Map)['paymentAccounts'], 2);
      final exportedSale = (snap['sa_sales'] as List).cast<Map>().firstWhere((s) => s['id'] == sale.id);
      expect(exportedSale['paymentAccountId'], a.id);

      // A deleted row in a server backup is not restored into this active-only cache.
      store.add({..._wire('pa-deleted'), 'deletedAt': '2026-10-09T00:00:00.000Z'});

      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      await SnapshotRepository(fresh).importLegacyBackup(jsonDecode(jsonEncode(snap)) as Map<String, dynamic>);
      final restored = await PaymentAccountsRepository(fresh).getAccounts();
      expect(restored.map((r) => r.nickname), ['บัญชีร้าน', 'รูป QR']);
      expect(restored.first.isDefault, isTrue);
      expect(restored[1].image, [1, 2, 3]);
      final restoredSale = await (fresh.select(fresh.sales)..where((t) => t.id.equals(sale.id))).getSingle();
      expect(restoredSale.paymentAccountId, a.id);
      // Typed store, not stashed as an unknown one.
      expect(
        (await fresh.select(fresh.appMeta).get())
            .where((r) => r.key.startsWith(SnapshotRepository.unknownStorePrefix)),
        isEmpty,
      );
    });

    test("a file with no accounts (absent or []) keeps the shop's; a non-empty one replaces them",
        () async {
      final repo = PaymentAccountsRepository(db);
      await repo.addAccount(_pp('บัญชีเดิม', isDefault: true));
      final snap = await SnapshotRepository(db).exportSnapshot();

      for (final store in <Object?>[null, <Object?>[]]) {
        final file = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
        if (store == null) {
          file.remove('sa_payment_accounts');
        } else {
          file['sa_payment_accounts'] = store;
        }
        await SnapshotRepository(db).importLegacyBackup(file);
        expect((await repo.getAccounts()).map((r) => r.nickname), ['บัญชีเดิม'], reason: '$store');
      }

      final file = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
      file['sa_payment_accounts'] = [_wire('pa-file', nickname: 'จากไฟล์')];
      await SnapshotRepository(db).importLegacyBackup(file);
      expect((await repo.getAccounts()).map((r) => r.id), ['pa-file']);
    });
  });
}
