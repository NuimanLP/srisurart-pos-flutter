// Unit tests for SettingsRepository.
//
// Invariants under test (db.js sa_settings parity):
//  • The settings singleton (id = 0) is seeded by AppDatabase.onCreate with
//    _DEFAULT_SETTINGS, so getSettings always succeeds on a fresh install.
//  • updateSettings merges a patch into the row (untouched fields keep their
//    values — db.js `{ ...current, ...patch }`).
//  • watchSettings emits the current row and re-emits after updateSettings.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/settings_repository.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('getSettings returns the seeded singleton (id = 0)', () async {
    final s = await repo.getSettings();
    expect(s.id, 0);
    expect(s.shopName, 'ศรีสุราษฎร์เจริญยนต์');
    expect(s.shopNameEN, 'Srisuras Charoen Yon');
    expect(s.taxRate, 7);
    expect(s.quoteValidDays, 30);
    expect(s.cashierName, 'แคชเชียร์');
  });

  test('updateSettings merges the patch, untouched fields survive', () async {
    await repo.updateSettings(const SettingsRowCompanion(
      shopName: Value('ร้านใหม่'),
      phone: Value('099-999-9999'),
    ));

    final s = await repo.getSettings();
    expect(s.shopName, 'ร้านใหม่');
    expect(s.phone, '099-999-9999');
    // Untouched fields keep their seeded values.
    expect(s.shopNameEN, 'Srisuras Charoen Yon');
    expect(s.taxRate, 7);
    expect(s.quoteValidDays, 30);
    expect(s.cashierName, 'แคชเชียร์');
  });

  test('watchSettings emits the seeded row, then re-emits on update',
      () async {
    final emissions = repo.watchSettings().take(2).toList();

    // Let the first emission land before patching.
    final first = await repo.watchSettings().first;
    expect(first.shopName, 'ศรีสุราษฎร์เจริญยนต์');

    await repo.updateSettings(
      const SettingsRowCompanion(shopName: Value('เปลี่ยนชื่อ')),
    );

    final rows = await emissions;
    expect(rows.last.shopName, 'เปลี่ยนชื่อ');
  });
}
