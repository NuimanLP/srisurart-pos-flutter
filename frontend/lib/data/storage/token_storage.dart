// Persistent storage for authentication tokens and device tokens.

import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/auth_models.dart';
import 'token_kv_store.dart';

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
  SharedPrefsTokenStorage({
    this.prefs,
    bool? persistAccessToken,
    TokenKvStore? secureStore,
  })  : persistAccessToken = persistAccessToken ?? !kIsWeb,
        _store = secureStore ?? createPlatformTokenKvStore();

  SharedPreferences? prefs;

  /// ADR-0009 (#400): on Flutter Web SharedPreferences IS localStorage, where
  /// any injected script can read it — so there the access token lives in
  /// [_memoryAccessToken] only, and a reload gets a new one through the refresh
  /// token (`ApiClient`: no Bearer → 401 → `/auth/refresh` → retry).
  /// Mobile keeps persisting it; ADR-0009 sets no rule there.
  final bool persistAccessToken;
  String? _memoryAccessToken;

  /// ADR-0009 + ADR-0004 (#400): the home of the refresh and device tokens when
  /// the platform has somewhere better than SharedPreferences — IndexedDB on
  /// web ([createPlatformTokenKvStore]); `null` on every other platform.
  final TokenKvStore? _store;

  /// False for the rest of a run whose startup could not use [_store]; the run
  /// then keeps the tokens in SharedPreferences (see [_migrateToStore]).
  bool _storeUsable = true;
  Future<void>? _ready;

  TokenKvStore? get _activeStore => _storeUsable ? _store : null;

  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';
  static const String _keyDeviceToken = 'auth_device_token';
  static const String _keyUser = 'auth_user_json';

  /// Every method goes through here, so [_init] runs once, before the first
  /// storage access of a run (AuthCubit.init at startup), and no token read or
  /// write can overtake it.
  Future<SharedPreferences> _getPrefs() async {
    final p = prefs ??= await SharedPreferences.getInstance();
    await (_ready ??= _init(p));
    return p;
  }

  Future<void> _init(SharedPreferences p) async {
    // Builds before #400 wrote the access token to localStorage on web.
    if (!persistAccessToken) await p.remove(_keyAccessToken);
    await _migrateToStore(p);
  }

  /// One-time move of the refresh/device tokens out of SharedPreferences
  /// (localStorage on web) into [_store]. Losing the device token would force
  /// a re-enrolment with a new `device_no` (ADR-0004 F8), so:
  ///  * nothing is removed from SharedPreferences until EVERY token has been
  ///    written to the store and read back equal;
  ///  * a SharedPreferences value overwrites the store's — while the store is
  ///    usable no token is ever written to SharedPreferences, so a token found
  ///    there is as new or newer (a pre-#400 build, or a run that fell back
  ///    below);
  ///  * re-running it after a crash half-way is harmless (idempotent);
  ///  * if the store is unusable (IndexedDB blocked or missing) the run falls
  ///    back to SharedPreferences exactly as before #400 instead of showing an
  ///    enrolled till as un-enrolled; the next run retries the move.
  Future<void> _migrateToStore(SharedPreferences p) async {
    final store = _store;
    if (store == null) return;
    try {
      final legacy = <String, String>{
        for (final key in const [_keyRefreshToken, _keyDeviceToken])
          key: ?p.getString(key),
      };
      // Probe even with nothing to move, so an unusable store is found here
      // rather than on the first token read.
      await store.get(_keyDeviceToken);
      for (final MapEntry(:key, :value) in legacy.entries) {
        await store.put(key, value);
        if (await store.get(key) != value) {
          throw StateError('token store read-back mismatch for $key');
        }
      }
      for (final key in legacy.keys) {
        await p.remove(key);
      }
    } catch (e) {
      debugPrint('TokenStorage: token store unusable, keeping tokens in '
          'SharedPreferences this run: $e');
      _storeUsable = false;
    }
  }

  Future<String?> _getToken(String key) async {
    final p = await _getPrefs();
    final store = _activeStore;
    return store == null ? p.getString(key) : store.get(key);
  }

  Future<void> _setToken(String key, String? token) async {
    final p = await _getPrefs();
    final store = _activeStore;
    if (token == null) return _removeToken(p, key);
    if (store == null) {
      await p.setString(key, token);
    } else {
      await store.put(key, token);
    }
  }

  /// Removes [key] from both homes. On a fallback run the store may still hold
  /// a copy from an earlier run, which must not bring a logout (or an
  /// un-enrolment) back on the next run — so it is deleted best-effort there.
  Future<void> _removeToken(SharedPreferences p, String key) async {
    await p.remove(key);
    final store = _store;
    if (store == null) return;
    try {
      await store.delete(key);
    } catch (_) {
      if (_storeUsable) rethrow;
    }
  }

  @override
  Future<String?> getAccessToken() async {
    final prefs = await _getPrefs();
    if (!persistAccessToken) return _memoryAccessToken;
    return prefs.getString(_keyAccessToken);
  }

  @override
  Future<void> setAccessToken(String? token) async {
    final prefs = await _getPrefs();
    if (!persistAccessToken) {
      _memoryAccessToken = token;
      return;
    }
    if (token == null) {
      await prefs.remove(_keyAccessToken);
    } else {
      await prefs.setString(_keyAccessToken, token);
    }
  }

  @override
  Future<String?> getRefreshToken() => _getToken(_keyRefreshToken);

  @override
  Future<void> setRefreshToken(String? token) =>
      _setToken(_keyRefreshToken, token);

  @override
  Future<String?> getDeviceToken() => _getToken(_keyDeviceToken);

  @override
  Future<void> setDeviceToken(String? token) =>
      _setToken(_keyDeviceToken, token);

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
    _memoryAccessToken = null;
    await prefs.remove(_keyAccessToken);
    await _removeToken(prefs, _keyRefreshToken);
    await prefs.remove(_keyUser);
    // Note: _keyDeviceToken is intentionally NOT removed.
  }

  @override
  Future<void> clearAll() async {
    final prefs = await _getPrefs();
    _memoryAccessToken = null;
    await prefs.remove(_keyAccessToken);
    await _removeToken(prefs, _keyRefreshToken);
    await prefs.remove(_keyUser);
    await _removeToken(prefs, _keyDeviceToken);
  }
}
