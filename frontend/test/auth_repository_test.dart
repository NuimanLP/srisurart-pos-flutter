// Unit tests for AuthRepository: login, enrolment, logout, and device binding rules.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class FakeTokenStorage implements TokenStorage {
  String? accessToken;
  String? refreshToken;
  String? deviceToken;
  AuthUser? user;

  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<void> setAccessToken(String? token) async => accessToken = token;

  @override
  Future<String?> getRefreshToken() async => refreshToken;
  @override
  Future<void> setRefreshToken(String? token) async => refreshToken = token;

  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<void> setDeviceToken(String? token) async => deviceToken = token;

  @override
  Future<AuthUser?> getUser() async => user;
  @override
  Future<void> setUser(AuthUser? u) async => user = u;

  @override
  Future<void> clearAuthTokens() async {
    accessToken = null;
    refreshToken = null;
    user = null;
  }

  @override
  Future<void> clearAll() async {
    accessToken = null;
    refreshToken = null;
    deviceToken = null;
    user = null;
  }
}

void main() {
  late FakeTokenStorage storage;

  setUp(() {
    storage = FakeTokenStorage();
  });

  test('enrolDevice sends normalized code and saves deviceToken in storage', () async {
    final mockClient = MockClient((req) async {
      expect(req.url.path, '/api/v1/auth/device');
      final body = jsonDecode(req.body);
      expect(body['code'], 'ENROL-1234'); // normalized to uppercase

      return http.Response(
        jsonEncode({'deviceToken': 'dev-token-uuid-123'}),
        200,
      );
    });

    final apiClient = ApiClient(baseUrl: 'http://test', httpClient: mockClient, tokenStorage: storage);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: storage);

    final token = await repo.enrolDevice('  enrol-1234  ');
    expect(token, 'dev-token-uuid-123');
    expect(storage.deviceToken, 'dev-token-uuid-123');
  });

  test('login automatically passes deviceToken if device is already enrolled', () async {
    storage.deviceToken = 'enrolled-hardware-token';

    final mockClient = MockClient((req) async {
      expect(req.url.path, '/api/v1/auth/token');
      final body = jsonDecode(req.body);
      expect(body['username'], 'cashier1');
      expect(body['password'], 'secret123');
      expect(body['deviceToken'], 'enrolled-hardware-token');

      final bodyStr = jsonEncode({
        'accessToken': 'header.payload.signature',
        'refreshToken': 'refresh-token-xyz',
        'user': {
          'id': 'u100',
          'username': 'cashier1',
          'role': 'cashier',
          'displayName': 'คุณสมชาย',
        },
      });

      return http.Response.bytes(
        utf8.encode(bodyStr),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final apiClient = ApiClient(baseUrl: 'http://test', httpClient: mockClient, tokenStorage: storage);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: storage);

    final user = await repo.login(username: 'cashier1', password: 'secret123');
    expect(user.id, 'u100');
    expect(user.displayName, 'คุณสมชาย');
    expect(storage.accessToken, 'header.payload.signature');
    expect(storage.refreshToken, 'refresh-token-xyz');
    expect(storage.user, equals(user));
  });

  test('logout preserves device token while wiping user credentials', () async {
    storage.deviceToken = 'hardware-device-token';
    storage.accessToken = 'jwt';
    storage.refreshToken = 'refresh';
    storage.user = const AuthUser(id: 'u1', username: 'pos', role: 'cashier');

    final apiClient = ApiClient(baseUrl: 'http://test', tokenStorage: storage);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: storage);

    await repo.logout();

    expect(storage.accessToken, isNull);
    expect(storage.refreshToken, isNull);
    expect(storage.user, isNull);
    expect(storage.deviceToken, 'hardware-device-token');
  });
}
