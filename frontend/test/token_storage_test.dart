// Unit tests for TokenStorage and ADR-0004 device token preservation.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/data/storage/token_kv_store.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TokenStorage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = SharedPrefsTokenStorage();
  });

  test('saves and retrieves access token, refresh token, and device token', () async {
    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
    expect(await storage.getDeviceToken(), isNull);

    await storage.setAccessToken('access-123');
    await storage.setRefreshToken('refresh-456');
    await storage.setDeviceToken('device-789');

    expect(await storage.getAccessToken(), 'access-123');
    expect(await storage.getRefreshToken(), 'refresh-456');
    expect(await storage.getDeviceToken(), 'device-789');
  });

  test('saves and retrieves AuthUser profile', () async {
    expect(await storage.getUser(), isNull);

    const user = AuthUser(
      id: 'u-1',
      username: 'cashier1',
      role: 'cashier',
      displayName: 'สมศรี มีทรัพย์',
    );

    await storage.setUser(user);
    final retrieved = await storage.getUser();

    expect(retrieved, equals(user));
    expect(retrieved?.displayName, 'สมศรี มีทรัพย์');
  });

  test('clearAuthTokens preserves deviceToken (ADR-0004 device binding invariant)', () async {
    await storage.setAccessToken('access-123');
    await storage.setRefreshToken('refresh-456');
    await storage.setDeviceToken('device-permanent-token');
    await storage.setUser(const AuthUser(id: 'u-1', username: 'pos', role: 'cashier'));

    // User logs out
    await storage.clearAuthTokens();

    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
    expect(await storage.getUser(), isNull);
    // Device token MUST still be present
    expect(await storage.getDeviceToken(), 'device-permanent-token');
  });

  test('clearAll wipes everything including deviceToken', () async {
    await storage.setAccessToken('access-123');
    await storage.setDeviceToken('device-token');
    await storage.setUser(const AuthUser(id: 'u-1', username: 'admin', role: 'owner'));

    await storage.clearAll();

    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getDeviceToken(), isNull);
    expect(await storage.getUser(), isNull);
  });

  // #400 / ADR-0009 "ที่เก็บฝั่ง Flutter Web": the access token lives in memory
  // only — never in localStorage, which is what SharedPreferences is on web.
  group('#400 access token in memory only (web)', () {
    test('setAccessToken does not write the access token to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final web = SharedPrefsTokenStorage(prefs: prefs, persistAccessToken: false);

      await web.setAccessToken('access-in-memory');
      await web.setRefreshToken('refresh-456');

      expect(await web.getAccessToken(), 'access-in-memory');
      expect(prefs.getString('auth_access_token'), isNull);
      expect(
        prefs.getKeys().map(prefs.get).contains('access-in-memory'),
        isFalse,
      );
    });

    test('a reload (new storage instance) starts with no access token', () async {
      final prefs = await SharedPreferences.getInstance();
      await SharedPrefsTokenStorage(prefs: prefs, persistAccessToken: false)
          .setAccessToken('access-in-memory');

      final afterReload =
          SharedPrefsTokenStorage(prefs: prefs, persistAccessToken: false);
      expect(await afterReload.getAccessToken(), isNull);
    });

    test('startup removes an access token a previous build left in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'auth_access_token': 'legacy-leaked-access',
        'auth_refresh_token': 'refresh-456',
        'auth_device_token': 'device-789',
      });
      final prefs = await SharedPreferences.getInstance();
      final web = SharedPrefsTokenStorage(prefs: prefs, persistAccessToken: false);

      // Any first read triggers it (AuthCubit.init reads the device token first).
      expect(await web.getDeviceToken(), 'device-789');

      expect(prefs.getString('auth_access_token'), isNull);
      expect(await web.getAccessToken(), isNull);
      // Refresh token untouched — a reload re-obtains the access token with it.
      expect(await web.getRefreshToken(), 'refresh-456');
    });

    test('clearAuthTokens and clearAll drop the in-memory access token', () async {
      final web = SharedPrefsTokenStorage(persistAccessToken: false);
      await web.setAccessToken('a');
      await web.clearAuthTokens();
      expect(await web.getAccessToken(), isNull);

      await web.setAccessToken('b');
      await web.clearAll();
      expect(await web.getAccessToken(), isNull);
    });

    test('persistAccessToken: true (mobile) keeps persisting as before', () async {
      final prefs = await SharedPreferences.getInstance();
      final mobile = SharedPrefsTokenStorage(prefs: prefs, persistAccessToken: true);
      await mobile.setAccessToken('access-123');
      expect(prefs.getString('auth_access_token'), 'access-123');
    });
  });

  // #400 / ADR-0009 + ADR-0004: on web the refresh and device tokens live in
  // IndexedDB (a TokenKvStore), never localStorage. The real IndexedDB store
  // cannot run on the VM; these drive the same logic through a fake store.
  group('#400 refresh + device tokens in the secure store (web)', () {
    late FakeKvStore store;
    late SharedPreferences prefs;

    SharedPrefsTokenStorage webStorage() => SharedPrefsTokenStorage(
        prefs: prefs, persistAccessToken: false, tokenStore: store);

    setUp(() async {
      store = FakeKvStore();
      prefs = await SharedPreferences.getInstance();
    });

    test('new tokens are written to the store and never to SharedPreferences', () async {
      final web = webStorage();
      await web.setRefreshToken('refresh-1');
      await web.setDeviceToken('device-1');

      expect(await web.getRefreshToken(), 'refresh-1');
      expect(await web.getDeviceToken(), 'device-1');
      expect(store.data, {'auth_refresh_token': 'refresh-1', 'auth_device_token': 'device-1'});
      expect(prefs.getString('auth_refresh_token'), isNull);
      expect(prefs.getString('auth_device_token'), isNull);
    });

    test('migration moves existing localStorage tokens so an enrolled till stays enrolled and logged in', () async {
      SharedPreferences.setMockInitialValues({
        'auth_refresh_token': 'legacy-refresh',
        'auth_device_token': 'legacy-device',
        'auth_access_token': 'legacy-access',
      });
      prefs = await SharedPreferences.getInstance();
      final web = webStorage();

      expect(await web.getDeviceToken(), 'legacy-device');
      expect(await web.getRefreshToken(), 'legacy-refresh');
      expect(store.data, {'auth_refresh_token': 'legacy-refresh', 'auth_device_token': 'legacy-device'});
      expect(prefs.getString('auth_refresh_token'), isNull);
      expect(prefs.getString('auth_device_token'), isNull);
      expect(prefs.getString('auth_access_token'), isNull);
    });

    test('migration is idempotent: a second run (reload) changes nothing', () async {
      SharedPreferences.setMockInitialValues({'auth_device_token': 'legacy-device'});
      prefs = await SharedPreferences.getInstance();
      await webStorage().getDeviceToken();
      final afterReload = webStorage();

      expect(await afterReload.getDeviceToken(), 'legacy-device');
      expect(store.data, {'auth_device_token': 'legacy-device'});
    });

    test('a localStorage token overwrites a stale store copy (store written by an earlier run, localStorage by a later fallback run)', () async {
      store.data['auth_device_token'] = 'old-device';
      SharedPreferences.setMockInitialValues({'auth_device_token': 'newer-device'});
      prefs = await SharedPreferences.getInstance();

      expect(await webStorage().getDeviceToken(), 'newer-device');
      expect(prefs.getString('auth_device_token'), isNull);
    });

    test('a failed store write deletes nothing from localStorage and the run falls back to it', () async {
      SharedPreferences.setMockInitialValues({
        'auth_refresh_token': 'legacy-refresh',
        'auth_device_token': 'legacy-device',
      });
      prefs = await SharedPreferences.getInstance();
      store.failPutOn = 'auth_device_token'; // refresh succeeds, device fails
      final web = webStorage();

      expect(await web.getDeviceToken(), 'legacy-device');
      expect(await web.getRefreshToken(), 'legacy-refresh');
      expect(prefs.getString('auth_refresh_token'), 'legacy-refresh');
      expect(prefs.getString('auth_device_token'), 'legacy-device');

      // Next run, store healthy: the move completes.
      store.failPutOn = null;
      final nextRun = webStorage();
      expect(await nextRun.getDeviceToken(), 'legacy-device');
      expect(prefs.getString('auth_device_token'), isNull);
      expect(prefs.getString('auth_refresh_token'), isNull);
    });

    test('a read-back mismatch deletes nothing from localStorage', () async {
      SharedPreferences.setMockInitialValues({'auth_device_token': 'legacy-device'});
      prefs = await SharedPreferences.getInstance();
      store.dropWrites = true;

      expect(await webStorage().getDeviceToken(), 'legacy-device');
      expect(prefs.getString('auth_device_token'), 'legacy-device');
    });

    test('an unusable store (open fails) falls back to localStorage for the whole run', () async {
      store.failAll = true;
      final web = webStorage();
      await web.setDeviceToken('device-1');

      expect(await web.getDeviceToken(), 'device-1');
      expect(prefs.getString('auth_device_token'), 'device-1');
    });

    test('clearAuthTokens drops the refresh token from the store but keeps the device token (ADR-0004)', () async {
      final web = webStorage();
      await web.setRefreshToken('refresh-1');
      await web.setDeviceToken('device-1');

      await web.clearAuthTokens();

      expect(await web.getRefreshToken(), isNull);
      expect(await web.getDeviceToken(), 'device-1');
      expect(store.data, {'auth_device_token': 'device-1'});
    });

    test('clearAll removes both tokens from the store', () async {
      final web = webStorage();
      await web.setRefreshToken('refresh-1');
      await web.setDeviceToken('device-1');

      await web.clearAll();

      expect(store.data, isEmpty);
      expect(await web.getDeviceToken(), isNull);
    });

    // Review finding: once the tokens moved to the store, a run that cannot
    // open it must NOT fall back to (now empty) localStorage — that shows an
    // enrolled till as un-enrolled and invites a re-enrolment (new device_no,
    // ADR-0004 F8), whose token would later overwrite the real one.
    test('store unreachable after the tokens moved there: token access throws, nothing reads as un-enrolled', () async {
      SharedPreferences.setMockInitialValues({'auth_device_token': 'enrolled-device'});
      prefs = await SharedPreferences.getInstance();
      expect(await webStorage().getDeviceToken(), 'enrolled-device'); // migrates
      expect(prefs.getBool('auth_tokens_in_store'), isTrue);

      store.failAll = true; // a later run: IndexedDB will not open
      final laterRun = webStorage();
      await expectLater(laterRun.getDeviceToken(), throwsA(isA<TokenStoreUnavailableException>()));
      await expectLater(laterRun.setDeviceToken('re-enrolled'), throwsA(isA<TokenStoreUnavailableException>()));
      await expectLater(laterRun.getRefreshToken(), throwsA(isA<TokenStoreUnavailableException>()));
      expect(prefs.getString('auth_device_token'), isNull);

      // The store comes back mid-run: the next access retries and recovers.
      store.failAll = false;
      expect(await laterRun.getDeviceToken(), 'enrolled-device');
    });

    test('a fresh install marks the store as the token home even with nothing to migrate', () async {
      await webStorage().getDeviceToken();
      expect(prefs.getBool('auth_tokens_in_store'), isTrue);
    });

    // Review finding (#404): a partial migration leaves a store copy without
    // the marker; a fallback run then logs out / unbinds in localStorage only.
    // The next healthy run must not revive the store copy.
    test('logout in a fallback run after a partial migration: the next run does not revive the refresh token', () async {
      SharedPreferences.setMockInitialValues({
        'auth_refresh_token': 'legacy-refresh',
        'auth_device_token': 'legacy-device',
      });
      prefs = await SharedPreferences.getInstance();

      // 1. Partial migration: refresh reaches the store, device write fails.
      store.failPutOn = 'auth_device_token';
      expect(await webStorage().getRefreshToken(), 'legacy-refresh');
      expect(store.data['auth_refresh_token'], 'legacy-refresh');
      expect(prefs.getBool('auth_tokens_in_store'), isNull);

      // 2. A fallback run logs out (localStorage only).
      store.failPutOn = null;
      store.failAll = true;
      await webStorage().clearAuthTokens();
      expect(prefs.getString('auth_refresh_token'), isNull);

      // 3. A healthy run: the logged-out token stays gone.
      store.failAll = false;
      final nextRun = webStorage();
      expect(await nextRun.getRefreshToken(), isNull);
      expect(await nextRun.getDeviceToken(), 'legacy-device');
      expect(store.data, {'auth_device_token': 'legacy-device'});
    });

    test('unbind in a fallback run after a partial migration: the next run does not revive the device token', () async {
      // 1. A partial migration left a store copy of the device token, no marker.
      store.data['auth_device_token'] = 'old-device';
      SharedPreferences.setMockInitialValues({'auth_device_token': 'old-device'});
      prefs = await SharedPreferences.getInstance();

      // 2. A fallback run unbinds (localStorage only).
      store.failAll = true;
      await webStorage().clearAll();
      expect(prefs.getString('auth_device_token'), isNull);

      // 3. A healthy run: the till reads as un-enrolled, as it was left.
      store.failAll = false;
      expect(await webStorage().getDeviceToken(), isNull);
      expect(store.data, isEmpty);
      expect(prefs.getBool('auth_tokens_in_store'), isTrue);
    });

    test('a failed migration does not set the marker (fallback stays a plain pre-#400 run)', () async {
      SharedPreferences.setMockInitialValues({'auth_device_token': 'legacy-device'});
      prefs = await SharedPreferences.getInstance();
      store.failAll = true;

      expect(await webStorage().getDeviceToken(), 'legacy-device');
      expect(prefs.getBool('auth_tokens_in_store'), isNull);
    });
  });
}

class FakeKvStore implements TokenKvStore {
  final Map<String, String> data = {};
  bool failAll = false;
  bool failGet = false;
  bool dropWrites = false;
  String? failPutOn;

  @override
  Future<String?> get(String key) async {
    if (failAll || failGet) throw StateError('idb unavailable');
    return data[key];
  }

  @override
  Future<void> put(String key, String value) async {
    if (failAll || failPutOn == key) throw StateError('idb put failed');
    if (!dropWrites) data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failAll) throw StateError('idb unavailable');
    data.remove(key);
  }
}
