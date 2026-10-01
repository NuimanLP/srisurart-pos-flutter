// AuthRepository — Handles user login, device enrolment (ADR-0004),
// token refresh (ADR-0009), and credential lifecycle.

import 'dart:async';

import '../../core/network/api_client.dart';
import '../../domain/models/auth_models.dart';
import '../services/tenant_cache_guard.dart';
import '../storage/token_storage.dart';
import 'offline_pin_repository.dart';

class AuthRepository {
  AuthRepository({
    required this.apiClient,
    required this.tokenStorage,
    this.offlinePinRepository,
    this.tenantGuard,
    this.onTenantCacheReset,
  });

  final ApiClient apiClient;
  final TokenStorage tokenStorage;
  final OfflinePinRepository? offlinePinRepository;

  /// API build only: keeps another shop's cached data off screen (see
  /// [TenantCacheGuard]). Null on the Drift-only build.
  final TenantCacheGuard? tenantGuard;

  /// Fired (not awaited) after a session is stored on an emptied cache, to
  /// pull the new shop's data from zero cursors.
  final Future<void> Function()? onTenantCacheReset;

  /// Logs in with username and password.
  ///
  /// Automatically binds the deviceToken if the device was previously enrolled (ADR-0004).
  ///
  /// #443 PR3: a temporary owner password yields [LoginPasswordChangeRequired]
  /// — the response then carries no `accessToken`/`refreshToken` at all, so
  /// this branches before reading them. That token is never stored and never
  /// recorded as the online login that opens the 3-day offline-PIN window.
  Future<LoginResult> login({
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
    final user = AuthUser.fromJson(map['user'] as Map<String, dynamic>);

    if (map['passwordChangeRequired'] == true) {
      return LoginPasswordChangeRequired(
        user,
        map['passwordChangeToken'] as String,
      );
    }

    await _storeSession(
      accessToken: map['accessToken'] as String,
      refreshToken: map['refreshToken'] as String,
      user: user,
    );
    final changedAt = map['passwordChangedAt'];
    return LoginSucceeded(
      user,
      passwordChangedAt:
          changedAt is String ? DateTime.tryParse(changedAt)?.toLocal() : null,
    );
  }

  /// Replaces the temporary owner password with [newPassword] (#443 PR3),
  /// authorised by the restricted token from [login]. Success is a full
  /// session, stored exactly like a normal login.
  ///
  /// `skipAuth: true` so the client neither attaches a stored access token nor
  /// tries a refresh on a 401 — the pwchange token is the only credential here.
  Future<AuthUser> changePassword({
    required String passwordChangeToken,
    required String newPassword,
  }) async {
    final response = await apiClient.post(
      '/api/v1/auth/change-password',
      body: {'newPassword': newPassword},
      headers: {'Authorization': 'Bearer $passwordChangeToken'},
      skipAuth: true,
    );
    final map = response as Map<String, dynamic>;
    final user = AuthUser.fromJson(map['user'] as Map<String, dynamic>);
    await _storeSession(
      accessToken: map['accessToken'] as String,
      refreshToken: map['refreshToken'] as String,
      user: user,
    );
    return user;
  }

  Future<void> _storeSession({
    required String accessToken,
    required String refreshToken,
    required AuthUser user,
  }) async {
    final claims = JwtClaims.tryParse(accessToken);
    // Before anything is stored: a refused tenant switch (PosException) must
    // leave no session behind, and an emptied cache is emptied before any
    // screen or sign-in pull can read the old shop's rows.
    final cacheReset = await tenantGuard?.admit(
          claims?.tid,
          viaDeviceToken: claims?.did != null,
        ) ??
        false;

    // A new person's tokens: anything still in flight for the last one must
    // not touch them (ApiClient.beginSession).
    apiClient.beginSession();
    // A pull that started between the reset and beginSession captured the
    // reset's generation; void it too.
    if (cacheReset) tenantGuard!.db.fenceCacheWrites();
    await tokenStorage.setAccessToken(accessToken);
    await tokenStorage.setRefreshToken(refreshToken);
    await tokenStorage.setUser(user);

    // Record online login iat for 3-day offline PIN validity window (08 §13 C5)
    if (claims?.iat != null) {
      await offlinePinRepository?.recordOnlineLogin(
        iat: claims!.iat!,
        deviceId: claims.did,
        deviceRole: claims.drole,
      );
    }

    if (cacheReset) {
      unawaited(onTenantCacheReset?.call().catchError((Object _) {}));
    }
  }

  /// Enrols a device with a one-time enrolment code issued by the shop owner (ADR-0004).
  ///
  /// Exchanging the code yields an opaque, permanent deviceToken stored locally.
  Future<String> enrolDevice(String code) async {
    final normalizedCode = code.trim().toUpperCase();

    // #400: touch the token storage BEFORE spending the code. If the web token
    // store (IndexedDB) is unreachable — on an enrolled till or a fresh
    // browser alike, there is no localStorage fallback — this throws
    // TokenStoreUnavailableException, rather than minting a new device_no on
    // the server that could then not even be saved (ADR-0004 F8).
    await tokenStorage.getDeviceToken();
    // The new enrolment may be another shop's; then the old shop's local work
    // could never be sent or discarded (login is scoped to the device's shop).
    await tenantGuard?.checkEnrolment();

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
    apiClient.beginSession();
    await tokenStorage.clearAuthTokens();
  }

  /// Unbinds this device by deleting its stored device token.
  Future<void> clearDeviceEnrolment() async {
    apiClient.beginSession();
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
  ///
  /// With no access token it falls back to the role recorded at the last
  /// online login. Needed on web right after a reload, where the access token
  /// is memory-only (#400, ADR-0009); on any platform it also applies after
  /// logout, which is what AuthCubit already did by hand.
  Future<String?> getDeviceRole() async {
    final token = await tokenStorage.getAccessToken();
    if (token == null) return offlinePinRepository?.getDeviceRole();
    final claims = JwtClaims.tryParse(token);
    return claims?.drole;
  }

  /// Inspects the server-assigned deviceId from the current access token claims.
  ///
  /// Same no-access-token fallback as [getDeviceRole] (#400).
  Future<String?> getDeviceId() async {
    final token = await tokenStorage.getAccessToken();
    if (token == null) return offlinePinRepository?.getStoredDeviceId();
    final claims = JwtClaims.tryParse(token);
    return claims?.did;
  }

  /// Checks whether a valid session (or refresh token) is present.
  Future<bool> isAuthenticated() async {
    final refreshToken = await tokenStorage.getRefreshToken();
    return refreshToken != null && refreshToken.isNotEmpty;
  }
}
