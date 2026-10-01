// TenantCacheGuard: one shop's cached Drift data never shows under another
// shop's login, a switch never silently destroys unsent local work, and a pull
// reply from the old session that lands after a reset writes nothing.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/api_settings_repository.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';

import 'auth_repository_test.dart' show FakeTokenStorage;

const _key = TenantCacheGuard.tenantKey;

Future<String?> _meta(AppDatabase db, String key) async =>
    (await (db.select(db.appMeta)..where((t) => t.key.equals(key)))
            .getSingleOrNull())
        ?.value;

Future<void> _setMeta(AppDatabase db, String key, String value) =>
    db.into(db.appMeta).insertOnConflictUpdate(
          AppMetaCompanion.insert(key: key, value: value),
        );

Future<int> _count(AppDatabase db, TableInfo table) async =>
    (await db.select(table).get()).length;

/// Shop A's cache: pulled data (catalogue, settings, cursor) and the till's
/// own history (sale, closed shift, counters, offline PIN).
Future<void> _seedShopA(AppDatabase db) async {
  await db.into(db.products).insert(ProductsCompanion.insert(
        id: 'pA',
        partNo: 'A-1',
        name: 'A part',
        nameTH: 'อะไหล่ร้าน A',
        category: 'เครื่องยนต์',
        brand: 'A',
        price: 100,
        cost: 50,
        stock: 5,
        minStock: 1,
      ));
  await db.into(db.customers).insert(CustomersCompanion.insert(
        id: 'cA',
        code: 'CA',
        name: 'A customer',
        nameTH: 'ลูกค้าร้าน A',
        createdAt: '2026-09-01T00:00:00.000Z',
      ));
  await db.into(db.categories).insert(
      CategoriesCompanion.insert(name: 'หมวดของร้าน A', position: 9));
  await db.into(db.syncCursors).insert(SyncCursorsCompanion.insert(
        entity: 'products',
        cursor: const Value('2026-09-30T00:00:00.000Z'),
      ));
  await db.into(db.sales).insert(SalesCompanion.insert(
        id: 'sA',
        receiptNo: 'RC01-2569-10-0001',
        subtotal: 100,
        total: 100,
        paymentMethod: 'เงินสด',
        date: DateTime(2026, 10, 1),
      ));
  await db.into(db.docCounters).insert(DocCountersCompanion.insert(
        deviceId: 'devA',
        deviceNo: 1,
        docType: 'receipt',
        period: '2569-10',
        lastNo: 42,
      ));
  await (db.update(db.settingsRow)..where((t) => t.id.equals(0)))
      .write(const SettingsRowCompanion(shopName: Value('ร้าน A')));
  await _setMeta(db, 'offline_pin_hash', 'hash-of-A-user');
  await db.into(db.shifts).insert(ShiftsCompanion.insert(
        id: 'shA',
        dateStr: '2026-10-01',
        startingCash: 500,
        openedAt: DateTime(2026, 10, 1, 8),
        isActive: const Value(true),
      ));
}

Future<void> _expectShopAKept(AppDatabase db) async {
  expect(await _count(db, db.products), 1);
  expect(await _count(db, db.customers), 1);
  expect(await _count(db, db.syncCursors), 1);
  expect(await _meta(db, 'offline_pin_hash'), 'hash-of-A-user');
}

Future<void> _expectBlankSettingsAndDefaultCategories(AppDatabase db) async {
  final settings = await db.select(db.settingsRow).getSingle();
  expect(settings.shopName, '');
  expect(settings.shopNameEN, '');
  expect(settings.address, isNull);
  expect(settings.phone, isNull);
  final cats = (await db.select(db.categories).get()).map((c) => c.name);
  expect(cats, isNot(contains('หมวดของร้าน A')));
  expect(cats, contains('เครื่องยนต์'));
}

/// Each kind of local work a reset would destroy.
final _unsentWork = <String, Future<void> Function(AppDatabase)>{
  'outbox op (rejected)': (db) => db.into(db.outboxOps).insert(
        OutboxOpsCompanion.insert(
          opId: 'op1',
          idempotencyKey: 'k1',
          type: 'sale.create',
          payload: '{}',
          aggregates: '[]',
          createdAt: DateTime(2026, 9, 30),
          status: 'rejected',
        ),
      ),
  'pending credit payment': (db) => db.into(db.pendingCreditPayments).insert(
        PendingCreditPaymentsCompanion.insert(
          id: 'cp1',
          idempotencyKey: 'k-cp1',
          mechanicId: 'm1',
          amount: '100.00',
          paymentMethod: 'เงินสด',
          createdAt: DateTime(2026, 9, 30),
        ),
      ),
  'parked bill': (db) => db.into(db.parkedSales).insert(
        ParkedSalesCompanion.insert(
          id: 'pk1',
          parkedAt: DateTime(2026, 9, 30),
          payload: '{}',
        ),
      ),
};

String _jwt(Map<String, Object?> claims) =>
    'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  late AppDatabase db;
  late TenantCacheGuard guard;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    guard = TenantCacheGuard(db);
    await _seedShopA(db);
  });

  tearDown(() => db.close());

  test('a token with no tid is refused', () async {
    expect(
      () => guard.admit(null, viaDeviceToken: true),
      throwsA(isA<PosException>()
          .having((e) => e.code, 'code', TenantCacheGuard.noTenantCode)),
    );
    await _expectShopAKept(db);
  });

  group('marker set (tenant A)', () {
    setUp(() => _setMeta(db, _key, 'tenant-A'));

    test('same tenant re-login keeps every row', () async {
      expect(await guard.admit('tenant-A', viaDeviceToken: true), isFalse);
      await _expectShopAKept(db);
      expect(await _meta(db, _key), 'tenant-A');
    });

    test('A → B empties every table, re-marks B, next pull starts from zero',
        () async {
      // An open shift is not unsent work: the server holds it.
      expect(await guard.admit('tenant-B', viaDeviceToken: false), isTrue);

      for (final table in db.allTables) {
        if (table == db.appMeta ||
            table == db.categories ||
            table == db.settingsRow) {
          continue;
        }
        expect(await _count(db, table), 0, reason: table.actualTableName);
      }
      await _expectBlankSettingsAndDefaultCategories(db);
      expect(await _meta(db, 'offline_pin_hash'), isNull);
      expect(await _meta(db, _key), 'tenant-B');
      for (final k in AppDatabase.deviceMetaKeys) {
        expect(await _meta(db, k), isNotNull, reason: k);
      }

      // The products pull now asks for everything, not "since A's mark".
      final asked = <Uri>[];
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) async {
          asked.add(req.url);
          return _json({
            'data': [],
            'meta': {'nextCursor': null},
          });
        }),
      );
      await ApiProductsRepository(db, client).syncFromServer();
      expect(asked.single.queryParameters['updatedSince'],
          '1970-01-01T00:00:00.000Z');
      expect(asked.single.queryParameters.containsKey('afterId'), isFalse);
    });

    for (final MapEntry(key: kind, value: add) in _unsentWork.entries) {
      test('A → B is refused while there is a $kind — nothing touched',
          () async {
        await add(db);
        await expectLater(
          guard.admit('tenant-B', viaDeviceToken: true),
          throwsA(isA<PosException>().having(
              (e) => e.code, 'code', TenantCacheGuard.unsentWorkCode)),
        );
        await _expectShopAKept(db);
        expect(await _meta(db, _key), 'tenant-A');
      });
    }
  });

  group('legacy DB (no marker)', () {
    test(
        'device-token login, nothing unsent: till history kept, pulled cache '
        're-downloaded from zero', () async {
      await _unsentWork['parked bill']!(db); // local, but not unsent
      expect(await guard.admit('tenant-A', viaDeviceToken: true), isTrue);

      // Kept: the till's own history, which no pull brings back.
      expect(await _count(db, db.sales), 1);
      expect(await _count(db, db.shifts), 1);
      expect(await _count(db, db.docCounters), 1);
      expect(await _count(db, db.parkedSales), 1);
      expect(await _meta(db, 'offline_pin_hash'), 'hash-of-A-user');
      // Gone: everything a pull re-downloads, cursors included.
      expect(await _count(db, db.products), 0);
      expect(await _count(db, db.customers), 0);
      expect(await _count(db, db.syncCursors), 0);
      await _expectBlankSettingsAndDefaultCategories(db);
      expect(await _meta(db, _key), 'tenant-A');
    });

    test(
        'device-token login with unsent work: products/customers/mechanics '
        'kept, only cursors (+ settings) reset', () async {
      await _unsentWork['outbox op (rejected)']!(db);
      expect(await guard.admit('tenant-A', viaDeviceToken: true), isTrue);

      expect(await _count(db, db.products), 1);
      expect(await _count(db, db.customers), 1);
      expect(await _count(db, db.outboxOps), 1);
      expect(await _count(db, db.sales), 1);
      expect(await _count(db, db.syncCursors), 0);
      await _expectBlankSettingsAndDefaultCategories(db);
      expect(await _meta(db, _key), 'tenant-A');
    });

    test(
        'device-token login with an unsent sale: its local stock survives '
        'the full pull', () async {
      // Local stock 5 already reflects the unsent sale; the server, which
      // has not seen it, still says 10.
      await db.into(db.outboxOps).insert(OutboxOpsCompanion.insert(
            opId: 'op-sale',
            idempotencyKey: 'k-sale',
            type: 'sale.create',
            payload: jsonEncode({
              'items': [
                {'productId': 'pA', 'qty': 5},
              ],
            }),
            aggregates: jsonEncode(['product:pA']),
            createdAt: DateTime(2026, 10, 1),
            status: 'pending',
          ));
      expect(await guard.admit('tenant-A', viaDeviceToken: true), isTrue);

      final asked = <Uri>[];
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) async {
          asked.add(req.url);
          return _json({
            'data': [
              {
                'id': 'pA',
                'partNo': 'A-1',
                'name': 'A part',
                'nameTH': 'อะไหล่ร้าน A',
                'category': 'เครื่องยนต์',
                'price': 100,
                'cost': 50,
                'stock': 10,
                'updatedAt': '2026-10-01T00:00:00.000Z',
              }
            ],
            'meta': {'nextCursor': null},
          });
        }),
      );
      await ApiProductsRepository(db, client).syncFromServer();

      expect(asked.single.queryParameters['updatedSince'],
          '1970-01-01T00:00:00.000Z');
      final row = await (db.select(db.products)
            ..where((t) => t.id.equals('pA')))
          .getSingle();
      expect(row.stock, 5);
    });

    test('no device token, nothing unsent: emptied (owner unknown)', () async {
      expect(await guard.admit('tenant-B', viaDeviceToken: false), isTrue);
      expect(await _count(db, db.products), 0);
      expect(await _count(db, db.sales), 0);
      expect(await _meta(db, _key), 'tenant-B');
    });

    test('no device token with unsent work: refused, nothing touched',
        () async {
      await _unsentWork['parked bill']!(db);
      await expectLater(
        guard.admit('tenant-B', viaDeviceToken: false),
        throwsA(isA<PosException>()),
      );
      await _expectShopAKept(db);
      expect(await _meta(db, _key), isNull);
    });
  });

  group('late reply from the old session', () {
    setUp(() => _setMeta(db, _key, 'tenant-A'));

    test('a products page that lands after the reset writes nothing',
        () async {
      await db.delete(db.syncCursors).go();
      final reply = Completer<http.Response>();
      var requests = 0;
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) async {
          requests++;
          if (requests == 1) return reply.future;
          return _json({
            'data': [],
            'meta': {'nextCursor': null},
          });
        }),
      );
      final pull = ApiProductsRepository(db, client).syncFromServer();
      await Future<void>.delayed(Duration.zero);

      expect(await guard.admit('tenant-B', viaDeviceToken: false), isTrue);
      reply.complete(_json({
        'data': [
          {
            'id': 'pA-late',
            'partNo': 'A-2',
            'name': 'late A part',
            'nameTH': 'อะไหล่ร้าน A',
            'category': 'เครื่องยนต์',
            'price': 1,
            'cost': 1,
            'stock': 1,
            'updatedAt': '2026-10-01T00:00:00.000Z',
          }
        ],
        'meta': {
          'nextCursor': {
            'updatedSince': '2026-10-01T00:00:00.000Z',
            'afterId': 'pA-late',
          },
        },
      }));
      await pull;

      expect(await _count(db, db.products), 0);
      expect(await _count(db, db.syncCursors), 0);
      expect(requests, 1, reason: 'no next page after the reset');
    });

    test('a settings reply that lands after the reset writes nothing',
        () async {
      final reply = Completer<http.Response>();
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) => reply.future),
      );
      final pull = ApiSettingsRepository(db, client).pullFromServer();
      await Future<void>.delayed(Duration.zero);

      await guard.admit('tenant-B', viaDeviceToken: false);
      reply.complete(_json({'shopName': 'ร้าน A', 'shopNameEn': 'Shop A'}));
      expect(await pull, isFalse);
      await _expectBlankSettingsAndDefaultCategories(db);
    });
  });

  group('AuthRepository', () {
    late FakeTokenStorage storage;
    var resets = 0;
    var calls = 0;

    AuthRepository repoFor(String tid) {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((req) async {
          calls++;
          if (req.url.path == '/api/v1/auth/device') {
            return _json({'deviceToken': 'dev-B'});
          }
          return _json({
            'accessToken': _jwt({'sub': 'u1', 'tid': tid, 'iat': 1}),
            'refreshToken': 'rt-$tid',
            'user': {'id': 'u1', 'username': 'owner', 'role': 'owner'},
          });
        }),
      );
      return AuthRepository(
        apiClient: client,
        tokenStorage: storage,
        tenantGuard: guard,
        onTenantCacheReset: () async => resets++,
      );
    }

    setUp(() async {
      storage = FakeTokenStorage();
      resets = 0;
      calls = 0;
      await _setMeta(db, _key, 'tenant-A');
    });

    test('a refused switch stores no session and shows the Thai sentence',
        () async {
      await _unsentWork['outbox op (rejected)']!(db);
      Object? error;
      try {
        await repoFor('tenant-B').login(username: 'owner', password: 'pw');
      } catch (e) {
        error = e;
      }
      expect(error, isA<PosException>());
      expect(AuthCubit.loginRefusalMessage(error!),
          TenantCacheGuard.unsentWorkMessage);
      expect(storage.accessToken, isNull);
      expect(storage.refreshToken, isNull);
      await _expectShopAKept(db);
      expect(resets, 0);
    });

    test('a clean switch stores the session and triggers a full pull',
        () async {
      await repoFor('tenant-B').login(username: 'owner', password: 'pw');
      expect(storage.refreshToken, 'rt-tenant-B');
      expect(await _count(db, db.products), 0);
      // Reset, then fenced again after beginSession.
      expect(db.cacheGeneration, 2);
      await Future<void>.delayed(Duration.zero);
      expect(resets, 1);
    });

    test('same tenant: session stored, cache kept, no pull fired', () async {
      await repoFor('tenant-A').login(username: 'owner', password: 'pw');
      expect(storage.refreshToken, 'rt-tenant-A');
      await _expectShopAKept(db);
      await Future<void>.delayed(Duration.zero);
      expect(resets, 0);
    });

    for (final MapEntry(key: kind, value: add) in _unsentWork.entries) {
      test('enrolment is refused before the code is spent with a $kind',
          () async {
        await add(db);
        await expectLater(
          repoFor('tenant-B').enrolDevice('ABCD1234'),
          throwsA(isA<PosException>().having((e) => e.code, 'code',
              TenantCacheGuard.enrolUnsentWorkCode)),
        );
        expect(calls, 0);
        expect(storage.deviceToken, isNull);
      });
    }

    test('enrolment with nothing unsent goes ahead', () async {
      expect(await repoFor('tenant-B').enrolDevice('ABCD1234'), 'dev-B');
      expect(calls, 1);
    });
  });
}
