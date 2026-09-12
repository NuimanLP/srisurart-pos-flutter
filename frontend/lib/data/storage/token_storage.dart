// Persistent storage for authentication tokens and device tokens.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/auth_models.dart';

abstract class TokenStorage {
  Future<String?> getAccessToken();
  Future<void> setAccessToken(String? token);

  Future<String?> getRefreshToken();
  Future<void> setRefreshToken(String? token);

  Future<String?> getDeviceToken();
  Future<void> setDeviceToken(String? token);

  Future<AuthUser?> getUser();
  Future<void> setUser(AuthUser? user);

  /// Clears user credentials (access token, refresh token, user profile).
  ///
  /// CRITICAL (ADR-0004): Device token is PRESERVED upon user logout.
  /// A device enrolment belongs to the physical hardware/browser, not the user session.
  Future<void> clearAuthTokens();

  /// Clears everything, including the device token (unbinding the device).
  Future<void> clearAll();
}

class SharedPrefsTokenStorage implements TokenStorage {
  SharedPrefsTokenStorage({this.prefs});

  SharedPreferences? prefs;

  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';
  static const String _keyDeviceToken = 'auth_device_token';
  static const String _keyUser = 'auth_user_json';

  Future<SharedPreferences> _getPrefs() async {
    return prefs ??= await SharedPreferences.getInstance();
  }

  @override
  Future<String?> getAccessToken() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyAccessToken);
  }

  @override
  Future<void> setAccessToken(String? token) async {
    final prefs = await _getPrefs();
    if (token == null) {
      await prefs.remove(_keyAccessToken);
    } else {
      await prefs.setString(_keyAccessToken, token);
    }
  }

  @override
  Future<String?> getRefreshToken() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyRefreshToken);
  }

  @override
  Future<void> setRefreshToken(String? token) async {
    final prefs = await _getPrefs();
    if (token == null) {
      await prefs.remove(_keyRefreshToken);
    } else {
      await prefs.setString(_keyRefreshToken, token);
    }
  }

  @override
  Future<String?> getDeviceToken() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyDeviceToken);
  }

  @override
  Future<void> setDeviceToken(String? token) async {
    final prefs = await _getPrefs();
    if (token == null) {
      await prefs.remove(_keyDeviceToken);
    } else {
      await prefs.setString(_keyDeviceToken, token);
    }
  }

  @override
  Future<AuthUser?> getUser() async {
    final prefs = await _getPrefs();
    final jsonStr = prefs.getString(_keyUser);
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AuthUser.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setUser(AuthUser? user) async {
    final prefs = await _getPrefs();
    if (user == null) {
      await prefs.remove(_keyUser);
    } else {
      await prefs.setString(_keyUser, jsonEncode(user.toJson()));
    }
  }

  @override
  Future<void> clearAuthTokens() async {
    final prefs = await _getPrefs();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
    await prefs.remove(_keyUser);
    // Note: _keyDeviceToken is intentionally NOT removed.
  }

  @override
  Future<void> clearAll() async {
    final prefs = await _getPrefs();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
    await prefs.remove(_keyUser);
    await prefs.remove(_keyDeviceToken);
  }
}
