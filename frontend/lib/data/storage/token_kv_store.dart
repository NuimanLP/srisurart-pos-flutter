// Where the long-lived tokens (refresh + device) live on a platform that has a
// better place for them than SharedPreferences.
//
// ADR-0009 "ที่เก็บฝั่ง Flutter Web" (#400): on the web the refresh token lives in
// IndexedDB together with the device token (ADR-0004) — never in localStorage,
// which is what SharedPreferences is there. The web build gets an IndexedDB
// store; every other platform gets `null` and keeps SharedPreferences as before
// (ADR-0009 sets no storage rule for mobile).
export 'token_kv_store_io.dart'
    if (dart.library.js_interop) 'token_kv_store_web.dart';

/// A tiny string key/value store. A completed [put]/[delete] future means the
/// write is committed — `SharedPrefsTokenStorage` removes the SharedPreferences
/// copy of a token only after [put] has completed and read back equal.
abstract class TokenKvStore {
  Future<String?> get(String key);
  Future<void> put(String key, String value);
  Future<void> delete(String key);
}
