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

/// Thrown by [SharedPrefsTokenStorage] token reads/writes when the refresh and
/// device tokens are known to live in the web token store (IndexedDB) but it
/// cannot be opened this run. Reporting "no device token" instead would show an
/// enrolled till as un-enrolled, and re-enrolling mints a new `device_no`
/// (ADR-0004 F8). `toString()` is the Thai sentence alone, like `PosException`.
class TokenStoreUnavailableException implements Exception {
  const TokenStoreUnavailableException();

  // agent draft — not yet ratified by the owner (#400).
  static const String message =
      'เปิดที่เก็บข้อมูลผูกเครื่องในเบราว์เซอร์ไม่ได้ กรุณารีโหลดหน้า — อย่าผูกเครื่องใหม่';

  @override
  String toString() => message;
}

/// Where [SharedPrefsTokenStorage] keeps the refresh and device tokens this run.
enum _StoreMode {
  /// No token store on this platform (mobile/desktop): SharedPreferences.
  none,

  /// The token store (IndexedDB on web).
  store,

  /// Store unusable and no token ever moved there: SharedPreferences, as
  /// before #400.
  fallback,

  /// Store unusable but the tokens are in it: token access throws
  /// [TokenStoreUnavailableException].
  unavailable,
}

class SharedPrefsTokenStorage implements TokenStorage {
  SharedPrefsTokenStorage({
    this.prefs,
    bool? persistAccessToken,
    TokenKvStore? tokenStore,
  })  : persistAccessToken = persistAccessToken ?? !kIsWeb,
        _store = tokenStore ?? createPlatformTokenKvStore();

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

  /// Set by [_init]; see [_StoreMode].
  _StoreMode _mode = _StoreMode.none;
  Future<void>? _ready;

  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';
  static const String _keyDeviceToken = 'auth_device_token';
  static const String _keyUser = 'auth_user_json';

  /// Non-secret marker in SharedPreferences: "the tokens now live in
  /// [_store]". Without it a later run that cannot open the store would read
  /// SharedPreferences, find no device token, and show an enrolled till as
  /// un-enrolled — and a re-enrolment mints a new `device_no` (ADR-0004 F8).
  static const String _keyTokensInStore = 'auth_tokens_in_store';

  /// The tokens that live in [_store] when there is one.
  static const List<String> _storeKeys = [_keyRefreshToken, _keyDeviceToken];

  /// Every method goes through here, so [_init] runs before the first storage
  /// access of a run (AuthCubit.init at startup), and no token read or write
  /// can overtake it.
  Future<SharedPreferences> _getPrefs() async {
    final p = prefs ??= await SharedPreferences.getInstance();
    final ready = _ready ??= _init(p);
    try {
      await ready;
    } catch (_) {
      if (identical(_ready, ready)) _ready = null; // retry on the next call
      rethrow;
    }
    return p;
  }

  Future<void> _init(SharedPreferences p) async {
    // Builds before #400 wrote the access token to localStorage on web.
    if (!persistAccessToken) await p.remove(_keyAccessToken);
    await _migrateToStore(p);
    // The tokens are in a store we cannot reach: try again on the next call
    // instead of settling for an error for the rest of the run.
    if (_mode == _StoreMode.unavailable) _ready = null;
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
  ///  * until [_keyTokensInStore] is set, a store token with no
  ///    SharedPreferences counterpart is deleted (the store mirrors
  ///    SharedPreferences) — else a logout/unbind done in a fallback run
  ///    after a partial migration would come back (#404 review);
  ///  * re-running it after a crash half-way is harmless (idempotent);
  ///  * if the store is unusable (IndexedDB blocked, missing or timing out):
  ///    - before any token ever moved there, the run falls back to
  ///      SharedPreferences exactly as before #400; the next run retries;
  ///    - once [_keyTokensInStore] is set, token reads/writes throw
  ///      [TokenStoreUnavailableException] instead — never a silent
  ///      "not enrolled" that invites a re-enrolment.
  Future<void> _migrateToStore(SharedPreferences p) async {
    final store = _store;
    if (store == null) {
      _mode = _StoreMode.none;
      return;
    }
    try {
      final legacy = <String, String>{
        for (final key in _storeKeys)
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
      // Until the marker is set SharedPreferences is the only truth, so the
      // store must mirror it: a store copy with no SharedPreferences
      // counterpart was left by a partial migration and then logged out or
      // unbound by a fallback run — keeping it would revive that token.
      if (!(p.getBool(_keyTokensInStore) ?? false)) {
        for (final key in _storeKeys) {
          if (!legacy.containsKey(key)) await store.delete(key);
        }
      }
      // Marker before removal: a crash in between leaves both copies, and the
      // next run overwrites the store with the (equal) SharedPreferences ones.
      await p.setBool(_keyTokensInStore, true);
      for (final key in legacy.keys) {
        await p.remove(key);
      }
      _mode = _StoreMode.store;
    } catch (e) {
      final inStore = p.getBool(_keyTokensInStore) ?? false;
      debugPrint('TokenStorage: token store unusable '
          '(${inStore ? 'tokens are there — refusing' : 'falling back to SharedPreferences'}'
          ' this run): $e');
      _mode = inStore ? _StoreMode.unavailable : _StoreMode.fallback;
    }
  }

  /// The store to use for refresh/device tokens, `null` for SharedPreferences.
  TokenKvStore? _tokenHome() => switch (_mode) {
        _StoreMode.store => _store,
        _StoreMode.none || _StoreMode.fallback => null,
        _StoreMode.unavailable => throw const TokenStoreUnavailableException(),
      };

  Future<String?> _getToken(String key) async {
    final p = await _getPrefs();
    final store = _tokenHome();
    return store == null ? p.getString(key) : store.get(key);
  }

  Future<void> _setToken(String key, String? token) async {
    final p = await _getPrefs();
    if (token == null) return _removeToken(p, key);
    final store = _tokenHome();
    if (store == null) {
      await p.setString(key, token);
    } else {
      await store.put(key, token);
    }
  }

  /// Removes [key] from SharedPreferences and, when the tokens live in the
  /// store, from the store. An unreachable store throws: a logout or unbind
  /// that only half-happened must not report success.
  Future<void> _removeToken(SharedPreferences p, String key) async {
    await p.remove(key);
    await _tokenHome()?.delete(key);
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
