// #400: the real IndexedDB token store, in a browser.
// Run: flutter test --platform chrome test/token_kv_store_web_test.dart
// (skipped by the plain VM `flutter test`).
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/data/storage/token_kv_store.dart';
import 'package:srisurart_pos/data/storage/token_kv_store_web.dart'
    show IndexedDbTokenKvStore;
import 'package:srisurart_pos/data/storage/token_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the web build picks the IndexedDB store', () {
    expect(createPlatformTokenKvStore(), isA<IndexedDbTokenKvStore>());
  });

  test('IndexedDB store put/get/delete round-trips across instances', () async {
    final a = IndexedDbTokenKvStore();
    await a.put('t-key', 'value-1');
    expect(await a.get('t-key'), 'value-1');
    // A fresh instance (= a reload) opens the same database.
    expect(await IndexedDbTokenKvStore().get('t-key'), 'value-1');
    await a.delete('t-key');
    expect(await a.get('t-key'), isNull);
  });

  test('default web storage migrates localStorage tokens into IndexedDB', () async {
    SharedPreferences.setMockInitialValues({
      'auth_refresh_token': 'legacy-refresh',
      'auth_device_token': 'legacy-device',
    });
    final prefs = await SharedPreferences.getInstance();
    final storage = SharedPrefsTokenStorage(prefs: prefs);

    expect(await storage.getDeviceToken(), 'legacy-device');
    expect(prefs.getString('auth_device_token'), isNull);
    expect(prefs.getString('auth_refresh_token'), isNull);
    final idb = IndexedDbTokenKvStore();
    expect(await idb.get('auth_device_token'), 'legacy-device');
    expect(await idb.get('auth_refresh_token'), 'legacy-refresh');

    await storage.clearAll();
    expect(await idb.get('auth_device_token'), isNull);
  });
}
