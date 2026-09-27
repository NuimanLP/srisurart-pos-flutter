// #460 — the API build's settings: pulled from `GET /settings` on sign-in,
// edited through `PATCH /settings`, refused (never written locally) when the
// server cannot take the edit.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_settings_repository.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/settings_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/settings_pull.dart';

import 'support/fake_sync_facade.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode({'status': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _serverSettings = {
  'shopName': 'ร้านของ tenant',
  'shopNameEn': 'Tenant Shop',
  'taxRate': 7.5,
  'quoteValidDays': 14,
  'address': null,
  'phone': '077-000000',
  'cashierName': null,
  'taxId': '0123456789012',
  'branchNo': '00000',
  'updatedAt': '2026-09-27T03:00:00.000Z',
};

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  ApiSettingsRepository repoWith(
    MockClientHandler handler, {
    SyncFacade? syncFacade,
  }) => ApiSettingsRepository(
    db,
    ApiClient(httpClient: MockClient(handler)),
    syncFacade: syncFacade,
  );

  group('pullFromServer', () {
    test('GET /settings replaces the Drift seed, server casing included', () async {
      final seen = <String>[];
      final repo = repoWith((req) async {
        seen.add('${req.method} ${req.url.path}');
        return _ok(_serverSettings);
      });

      expect(await repo.pullFromServer(), isTrue);

      expect(seen, ['GET /api/v1/settings']);
      final s = await repo.getSettings();
      expect(s.shopName, 'ร้านของ tenant');
      expect(s.shopNameEN, 'Tenant Shop'); // the wire key is `shopNameEn`
      expect(s.taxRate, 7.5);
      expect(s.quoteValidDays, 14);
      expect(s.phone, '077-000000');
      expect(s.cashierName, isNull); // sent as null → cleared
      expect(s.taxId, '0123456789012');
      expect(s.branchNo, '00000');
      expect(s.updatedAt, DateTime.parse('2026-09-27T03:00:00.000Z').toLocal());
    });

    test('a key the reply omits leaves its column alone', () async {
      final before = await SettingsRepository(db).getSettings();
      final repo = repoWith((_) async => _ok({'shopName': 'เฉพาะชื่อร้าน'}));

      expect(await repo.pullFromServer(), isTrue);

      final s = await repo.getSettings();
      expect(s.shopName, 'เฉพาะชื่อร้าน');
      expect(s.shopNameEN, before.shopNameEN);
      expect(s.taxRate, before.taxRate);
      expect(s.quoteValidDays, before.quoteValidDays);
      expect(s.cashierName, before.cashierName);
      expect(s.phone, before.phone);
    });

    test('no network or a server error: false, cache untouched, never throws', () async {
      final before = await SettingsRepository(db).getSettings();

      final offline = repoWith((_) async => throw http.ClientException('down'));
      expect(await offline.pullFromServer(), isFalse);

      final broken = repoWith(
        (_) async => http.Response('{"status":"error","error":{"code":"INTERNAL"}}', 500),
      );
      expect(await broken.pullFromServer(), isFalse);

      expect(await SettingsRepository(db).getSettings(), before);
    });
  });

  group('updateSettings', () {
    test('sends only the set fields to PATCH /settings and caches the reply', () async {
      http.Request? sent;
      final repo = repoWith((req) async {
        sent = req;
        // The server trims and answers with the whole row.
        return _ok({..._serverSettings, 'shopName': 'ร้านใหม่'});
      });

      await repo.updateSettings(
        const SettingsRowCompanion(
          shopName: Value(' ร้านใหม่ '),
          shopNameEN: Value('New Shop'),
          phone: Value(null),
          quoteValidDays: Value(14),
        ),
      );

      expect(sent!.method, 'PATCH');
      expect(sent!.url.path, '/api/v1/settings');
      expect(sent!.headers['Idempotency-Key'], isNotEmpty);
      expect(jsonDecode(sent!.body), {
        'shopName': ' ร้านใหม่ ',
        'shopNameEn': 'New Shop',
        'phone': null,
        'quoteValidDays': 14,
      });
      final s = await repo.getSettings();
      expect(s.shopName, 'ร้านใหม่'); // the server's value, not the typed one
      expect(s.phone, '077-000000');
      expect(s.taxRate, 7.5);
    });

    test('Degraded: refused with the Thai sentence, no request, no local write', () async {
      final before = await SettingsRepository(db).getSettings();
      var requests = 0;
      final repo = repoWith(
        (_) async {
          requests++;
          return _ok(_serverSettings);
        },
        syncFacade: FakeSyncFacade(initialStatus: SyncStatus.degraded),
      );

      await expectLater(
        repo.updateSettings(const SettingsRowCompanion(shopName: Value('x'))),
        throwsA(
          isA<PosException>()
              .having((e) => e.code, 'code', 'OFFLINE_ACTION_NOT_ALLOWED')
              .having((e) => e.toString(), 'message', settingsOfflineRefusal),
        ),
      );
      expect(requests, 0);
      expect(await SettingsRepository(db).getSettings(), before);
    });

    test('a server refusal reaches the screen as a PosException, not an ApiException', () async {
      final before = await SettingsRepository(db).getSettings();
      final repo = repoWith(
        (_) async => http.Response(
          jsonEncode({
            'statusCode': 400,
            'message': "Field 'shopName' must be a non-empty string",
            'error': 'Bad Request',
          }),
          400,
        ),
      );

      await expectLater(
        repo.updateSettings(const SettingsRowCompanion(shopName: Value(''))),
        throwsA(isA<PosException>()),
      );
      expect(await SettingsRepository(db).getSettings(), before);
    });

    test('no network: a Thai PosException and no local write', () async {
      final before = await SettingsRepository(db).getSettings();
      final repo = repoWith((_) async => throw http.ClientException('down'));

      await expectLater(
        repo.updateSettings(const SettingsRowCompanion(shopName: Value('x'))),
        throwsA(
          isA<PosException>().having(
            (e) => e.toString(),
            'message',
            'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
          ),
        ),
      );
      expect(await SettingsRepository(db).getSettings(), before);
    });
  });

  test('app open with a surviving session pulls the settings', () async {
    var pulls = 0;
    final repo = repoWith((_) async {
      pulls++;
      return _ok(_serverSettings);
    });
    final cubit = AuthCubit(authRepository: _SignedIn());
    pullSettingsOnSignIn(cubit, repo);

    await cubit.init();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state, isA<Authenticated>());
    expect(pulls, 1);
    await cubit.close();
  });
}

class _SignedIn extends AuthRepository {
  _SignedIn()
    : super(
        apiClient: ApiClient(httpClient: MockClient((_) async => http.Response('', 500))),
        tokenStorage: SharedPrefsTokenStorage(),
      );

  @override
  Future<String?> getDeviceToken() async => 'dt';
  @override
  Future<String?> getDeviceRole() async => 'backoffice';
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<AuthUser?> getCurrentUser() async =>
      const AuthUser(id: 'u1', username: 'x', role: 'owner');
}
