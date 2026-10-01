// TenantCacheGuard: one shop's cached Drift data never shows under another
// shop's login, and a switch never silently destroys unsent local work.

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

/// Shop A's cache: catalogue, history, settings, counters, cursor, PIN.
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
  await db.into(db.syncCursors).insert(SyncCursorsCompanion.insert(
        entity: 'products',
        cursor: const Value('2026-09-30T00:00:00.000Z'),
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
  // A shift opened and already closed: history, not unsent work.
  await db.into(db.shifts).insert(ShiftsCompanion.insert(
        id: 'shA',
        dateStr: '2026-09-30',
        startingCash: 500,
        openedAt: DateTime(2026, 9, 30, 8),
        closedAt: Value(DateTime(2026, 9, 30, 18)),
        isActive: const Value(true),
      ));
}

Future<void> _expectShopAKept(AppDatabase db) async {
  expect(await db.select(db.products).get(), hasLength(1));
  expect(await db.select(db.customers).get(), hasLength(1));
  expect(await db.select(db.syncCursors).get(), hasLength(1));
  expect(await _meta(db, 'offline_pin_hash'), 'hash-of-A-user');
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
  'open shift': (db) => db.into(db.shifts).insert(ShiftsCompanion.insert(
        id: 'shOpen',
        dateStr: '2026-10-01',
        startingCash: 500,
        openedAt: DateTime(2026, 10, 1, 8),
        isActive: const Value(true),
      )),
};

String _jwt(Map<String, Object?> claims) =>
    'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

void main() {
  late AppDatabase db;
  late TenantCacheGuard guard;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    guard = TenantCacheGuard(db);
    await _seedShopA(db);
  });

  tearDown(() => db.close());

  group('marker set (tenant A)', () {
    setUp(() => _setMeta(db, _key, 'tenant-A'));

    test('same tenant re-login keeps every row', () async {
      expect(await guard.admit('tenant-A', viaDeviceToken: true), isFalse);
      await _expectShopAKept(db);
      expect(await _meta(db, _key), 'tenant-A');
    });

    test('A → B empties the cache, re-marks B, next pull starts from zero',
        () async {
      expect(await guard.admit('tenant-B', viaDeviceToken: false), isTrue);

      expect(await db.select(db.products).get(), isEmpty);
      expect(await db.select(db.customers).get(), isEmpty);
      expect(await db.select(db.shifts).get(), isEmpty);
      expect(await db.select(db.syncCursors).get(), isEmpty);
      expect(await db.select(db.docCounters).get(), isEmpty);
      expect(await _meta(db, 'offline_pin_hash'), isNull);
      expect(await _meta(db, _key), 'tenant-B');
      // DB-file meta survives; defaults a new DB has are back.
      expect(await _meta(db, 'schema_version'), '2');
      expect(await _meta(db, AppDatabase.demoSeedPurgedKey), '1');
      final settings = await db.select(db.settingsRow).getSingle();
      expect(settings.shopName, isNot('ร้าน A'));
      expect(await db.select(db.categories).get(), isNotEmpty);

      // The products pull now asks for everything, not "since A's mark".
      final asked = <Uri>[];
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) async {
          asked.add(req.url);
          return http.Response(
            jsonEncode({
              'data': [],
              'meta': {'nextCursor': null},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
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
    test('device-token login adopts the data as this tenant\'s', () async {
      await _unsentWork['outbox op (rejected)']!(db);
      expect(await guard.admit('tenant-A', viaDeviceToken: true), isFalse);
      await _expectShopAKept(db);
      expect(await _meta(db, _key), 'tenant-A');
    });

    test('no device token, nothing unsent: emptied (owner unknown)', () async {
      expect(await guard.admit('tenant-B', viaDeviceToken: false), isTrue);
      expect(await db.select(db.products).get(), isEmpty);
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

    test('empty API-build DB: adopted, pulls from zero', () async {
      await db.resetTenantCache(); // a browser that never signed in
      expect(await guard.admit('tenant-B', viaDeviceToken: false), isTrue);
      expect(await _meta(db, _key), 'tenant-B');
      expect(await db.select(db.settingsRow).get(), hasLength(1));
    });
  });

  group('AuthRepository.login', () {
    late FakeTokenStorage storage;
    var resets = 0;

    AuthRepository repoFor(String tid) {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'accessToken': _jwt({'sub': 'u1', 'tid': tid, 'iat': 1}),
                'refreshToken': 'rt-$tid',
                'user': {'id': 'u1', 'username': 'owner', 'role': 'owner'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
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
      expect(await db.select(db.products).get(), isEmpty);
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
  });
}
