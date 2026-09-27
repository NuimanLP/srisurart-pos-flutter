// SettingsRepository — shop settings singleton (sa_settings in db.js).
//
// The settings live in a single row, id = 0 (seeded in AppDatabase.onCreate with
// _DEFAULT_SETTINGS). db.js methods ported:
//   getSettings()        → the singleton row
//   updateSettings(patch) → merge patch into the row
//
// FULLY IMPLEMENTED (low-risk, other agents depend on it).

import 'package:drift/drift.dart';

import '../db/database.dart';

/// What the counter reads when a settings edit is refused while Degraded —
/// settings are online-only (08 §6.2). Shared by the Settings screen's
/// pre-check and `ApiSettingsRepository` so both say the same words.
const settingsOfflineRefusal =
    'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถบันทึกการตั้งค่าได้';

class SettingsRepository {
  final AppDatabase db;
  SettingsRepository(this.db);

  /// The settings singleton (row id = 0). Seeded on first create, so it always
  /// exists on a normal install.
  Future<SettingsRowData> getSettings() async {
    return (db.select(
      db.settingsRow,
    )..where((t) => t.id.equals(0))).getSingle();
  }

  /// A stream of the settings singleton — for screens that react to changes.
  Stream<SettingsRowData> watchSettings() {
    return (db.select(
      db.settingsRow,
    )..where((t) => t.id.equals(0))).watchSingle();
  }

  /// Merge a patch into the settings row. Pass only the fields to change.
  /// Mirrors db.js updateSettings({ ...current, ...patch }).
  Future<void> updateSettings(SettingsRowCompanion patch) async {
    await (db.update(
      db.settingsRow,
    )..where((t) => t.id.equals(0))).write(
      patch.copyWith(updatedAt: Value(DateTime.now())),
    );
  }
}
