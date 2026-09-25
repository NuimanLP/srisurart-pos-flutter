// Web (IndexedDB) implementation of [TokenKvStore] — see token_kv_store.dart.
//
// One database `srisurart_auth`, one object store `tokens`, out-of-line string
// keys. Deliberately separate from Drift's own web database, so a Drift schema
// bump or a Drift storage reset never touches the device enrolment.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'token_kv_store.dart';

TokenKvStore? createPlatformTokenKvStore() => IndexedDbTokenKvStore();

class IndexedDbTokenKvStore implements TokenKvStore {
  static const String _dbName = 'srisurart_auth';
  static const String _store = 'tokens';

  /// An open that never answers (a `blocked` that never clears, a wedged
  /// browser) must fail rather than hang app startup, so the caller can fall
  /// back — see `SharedPrefsTokenStorage._migrateToStore`.
  static const Duration openTimeout = Duration(seconds: 5);

  Future<web.IDBDatabase>? _db;

  Future<web.IDBDatabase> _open() {
    final cached = _db;
    if (cached != null) return cached;
    final completer = Completer<web.IDBDatabase>();
    void fail(String why) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('IndexedDB open failed: $why'));
      }
    }

    final req = web.window.indexedDB.open(_dbName, 1);
    req.onupgradeneeded = ((web.Event _) {
      final db = req.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
    }).toJS;
    req.onsuccess = ((web.Event _) {
      final db = req.result as web.IDBDatabase;
      // The browser can close the connection under us (storage cleared,
      // another tab upgrading); drop it so the next call reopens.
      db.onclose = ((web.Event _) => _db = null).toJS;
      db.onversionchange = ((web.Event _) {
        db.close();
        _db = null;
      }).toJS;
      if (completer.isCompleted) {
        db.close(); // answered after the timeout — nobody is waiting
      } else {
        completer.complete(db);
      }
    }).toJS;
    req.onerror = ((web.Event _) => fail('${req.error?.message}')).toJS;
    req.onblocked = ((web.Event _) => fail('blocked')).toJS;
    Timer(openTimeout, () => fail('timed out after $openTimeout'));
    final opened = completer.future;
    // Never cache a failed open — the next call retries.
    opened.then<void>((_) {}, onError: (Object _) {
      if (identical(_db, opened)) _db = null;
    });
    return _db = opened;
  }

  /// Runs [op] in one transaction and resolves only on the transaction's
  /// `complete` event — for a readwrite transaction that is the commit.
  Future<JSAny?> _run(
    String mode,
    web.IDBRequest Function(web.IDBObjectStore store) op,
  ) async {
    final db = await _open();
    final tx = db.transaction(
      _store.toJS,
      mode,
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final req = op(tx.objectStore(_store));
    final completer = Completer<JSAny?>();
    tx.oncomplete = ((web.Event _) {
      if (!completer.isCompleted) completer.complete(req.result);
    }).toJS;
    void fail(web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'IndexedDB $mode failed: ${(tx.error ?? req.error)?.message}'));
      }
    }

    tx.onerror = fail.toJS;
    tx.onabort = fail.toJS;
    return completer.future;
  }

  @override
  Future<String?> get(String key) async {
    final v = (await _run('readonly', (s) => s.get(key.toJS))).dartify();
    return v is String ? v : null;
  }

  @override
  Future<void> put(String key, String value) =>
      _run('readwrite', (s) => s.put(value.toJS, key.toJS));

  @override
  Future<void> delete(String key) =>
      _run('readwrite', (s) => s.delete(key.toJS));
}
