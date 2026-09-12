// AuthRepository — Handles user login, device enrolment (ADR-0004),
// token refresh (ADR-0009), and credential lifecycle.

import '../../core/network/api_client.dart';
import '../../domain/models/auth_models.dart';
import '../storage/token_storage.dart';

class AuthRepository {
  AuthRepository({
    required this.apiClient,
    required this.tokenStorage,
  });

  final ApiClient apiClient;
  final TokenStorage tokenStorage;

  /// Logs in with username and password.
  ///
  /// Automatically binds the deviceToken if the device was previously enrolled (ADR-0004).
  Future<AuthUser> login({
    required String username,
    required String password,
  }) async {
    final deviceToken = await tokenStorage.getDeviceToken();

    final body = <String, dynamic>{
      'username': username.trim(),
      'password': password,
      if (deviceToken != null && deviceToken.trim().isNotEmpty)
        'deviceToken': deviceToken.trim(),
    };

    final response = await apiClient.post(
      '/api/v1/auth/token',
      body: body,
      skipAuth: true,
    );

    final map = response as Map<String, dynamic>;
    final accessToken = map['accessToken'] as String;
    final refreshToken = map['refreshToken'] as String;
    final userJson = map['user'] as Map<String, dynamic>;

    final user = AuthUser.fromJson(userJson);

    await tokenStorage.setAccessToken(accessToken);
    await tokenStorage.setRefreshToken(refreshToken);
    await tokenStorage.setUser(user);

    return user;
  }

  /// Enrols a device with a one-time enrolment code issued by the shop owner (ADR-0004).
  ///
  /// Exchanging the code yields an opaque, permanent deviceToken stored locally.
  Future<String> enrolDevice(String code) async {
    final normalizedCode = code.trim().toUpperCase();

    final response = await apiClient.post(
      '/api/v1/auth/device',
      body: {'code': normalizedCode},
      skipAuth: true,
    );

    final map = response as Map<String, dynamic>;
    final deviceToken = map['deviceToken'] as String;

    await tokenStorage.setDeviceToken(deviceToken);
    return deviceToken;
  }

  /// Forces a token refresh cycle (ADR-0009).
  Future<AuthTokens?> refresh() async {
    final refreshToken = await tokenStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await tokenStorage.clearAuthTokens();
      return null;
    }

    final response = await apiClient.post(
      '/api/v1/auth/refresh',
      body: {'refreshToken': refreshToken},
      skipAuth: true,
    );

    final map = response as Map<String, dynamic>;
    final tokens = AuthTokens.fromJson(map);

    await tokenStorage.setAccessToken(tokens.accessToken);
    await tokenStorage.setRefreshToken(tokens.refreshToken);
    return tokens;
  }

  /// Logs out the active user.
  ///
  /// CRITICAL (ADR-0004): Preserves the device enrolment token.
  Future<void> logout() async {
    await tokenStorage.clearAuthTokens();
  }

  /// Unbinds this device by deleting its stored device token.
  Future<void> clearDeviceEnrolment() async {
    await tokenStorage.clearAll();
  }

  /// Returns the cached user profile.
  Future<AuthUser?> getCurrentUser() async {
    return tokenStorage.getUser();
  }

  /// Returns the current device token, if enrolled.
  Future<String?> getDeviceToken() async {
    return tokenStorage.getDeviceToken();
  }

  /// Inspects the device role ('pos' or 'backoffice') from the current access token claims.
  Future<String?> getDeviceRole() async {
    final token = await tokenStorage.getAccessToken();
    if (token == null) return null;
    final claims = JwtClaims.tryParse(token);
    return claims?.drole;
  }

  /// Checks whether a valid session (or refresh token) is present.
  Future<bool> isAuthenticated() async {
    final refreshToken = await tokenStorage.getRefreshToken();
    return refreshToken != null && refreshToken.isNotEmpty;
  }
}
