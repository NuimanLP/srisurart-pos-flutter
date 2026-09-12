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
}
