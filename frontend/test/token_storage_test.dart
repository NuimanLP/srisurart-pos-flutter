// Unit tests for TokenStorage and ADR-0004 device token preservation.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
}
