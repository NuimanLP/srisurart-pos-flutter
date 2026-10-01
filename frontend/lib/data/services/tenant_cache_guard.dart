// TenantCacheGuard — keeps one shop's cached Drift data away from another's
// (API build only).
//
// The local DB holds one tenant's data, but nothing recorded WHICH. So on a
// browser where shop A signed in and then shop B did, B saw A's products,
// customers, sales and settings, and B's incremental pull resumed from A's
// `sync_cursors` high-water mark — B's older rows never came down.
//
// Now the tenant of the cached data is kept in app_meta [tenantKey], checked at
// every session store (`AuthRepository._storeSession`: login and the #443
// change-password login) against the token's `tid`, BEFORE any token is
// stored — so a refused login leaves the old session-less state untouched and
// no screen ever shows the other shop's rows.
//
// Not checked at app open: a session that survived a reload was admitted when
// it was stored, and a refresh never changes the tenant.
//
// Also: enrolment is refused while there is local work ([checkEnrolment]), and
// a reset bumps `AppDatabase.cacheGeneration` so a pull reply from the old
// session that lands afterwards writes nothing (`writeCacheIfCurrent`).

import '../../core/network/api_exception.dart';
import '../db/database.dart';

class TenantCacheGuard {
  TenantCacheGuard(this.db);

  final AppDatabase db;

  /// app_meta key: the tenant whose data the local DB holds.
  static const String tenantKey = 'tenant_id';

  static const String unsentWorkCode = 'TENANT_SWITCH_UNSENT_WORK';

  /// Ratified by the owner 2026-10-01 — 02_API_SCREENS.md §8.1.1. Trimmed
  /// after ratification ("หรือกะที่ยังไม่ปิด" / "และปิดกะ" dropped when an
  /// open shift stopped blocking a switch); the trimmed text was confirmed by
  /// the owner 2026-10-01.
  static const String unsentWorkMessage =
      'เครื่องนี้ยังมีงานของร้านเดิมค้างอยู่ (รายการค้างส่ง ชำระเครดิตค้างส่ง '
      'หรือบิลพัก) กรุณาเข้าสู่ระบบร้านเดิมเพื่อส่งหรือยกเลิกรายการให้เรียบร้อยก่อน '
      'จึงจะเข้าสู่ระบบร้านอื่นได้';

  static const String enrolUnsentWorkCode = 'ENROL_UNSENT_WORK';

  /// Ratified by the owner 2026-10-01 — 02_API_SCREENS.md §8.1.1.
  static const String enrolUnsentWorkMessage =
      'ผูกเครื่องใหม่ไม่ได้ เพราะเครื่องนี้ยังมีงานค้างอยู่ (รายการค้างส่ง '
      'ชำระเครดิตค้างส่ง หรือบิลพัก) กรุณาส่งหรือยกเลิกรายการให้เรียบร้อยก่อน';

  static const String noTenantCode = 'TOKEN_TENANT_MISSING';

  /// Ratified by the owner 2026-10-01 — 02_API_SCREENS.md §8.1.1.
  static const String noTenantMessage =
      'เข้าสู่ระบบไม่สำเร็จ ข้อมูลร้านจากระบบไม่ครบ กรุณาลองใหม่';

  /// Lets [tenantId] use the local DB. Returns true when the cache was
  /// emptied, wholly or its pulled part (the caller then pulls from zero
  /// cursors), false when kept as it is.
  ///
  /// - same tenant as the marker → kept.
  /// - another tenant → refused with [unsentWorkCode] while there is local
  ///   work a reset would destroy ([hasLocalWork]); otherwise emptied
  ///   ([AppDatabase.resetTenantCache]) and re-marked.
  /// - no marker (every DB from before this guard) — whose data it holds is
  ///   unknown:
  ///   * [viaDeviceToken]: the server resolved this login through the device
  ///     token, i.e. scoped it to the tenant the browser is enrolled to. The
  ///     till's own history (sales, shifts, counters, outbox…) is never pulled
  ///     back, so it is adopted; the pulled part (catalogue, settings,
  ///     cursors) is re-downloaded fresh ([AppDatabase.resetPulledCache]) —
  ///     except products/customers/mechanics while there is unsent work,
  ///     whose rows carry that work's local effects.
  ///   * otherwise emptied if nothing would be lost, else refused: refusing
  ///     is the only option that neither leaks nor destroys.
  /// - a token with no `tid` (the server always sets one) → refused with
  ///   [noTenantCode]: with no tenant there is nothing to compare.
  Future<bool> admit(String? tenantId, {required bool viaDeviceToken}) {
    if (tenantId == null || tenantId.isEmpty) {
      throw const PosException(noTenantCode, noTenantMessage);
    }
    return db.transaction(() async {
      final stored = await (db.select(db.appMeta)
            ..where((t) => t.key.equals(tenantKey)))
          .getSingleOrNull();
      if (stored?.value == tenantId) return false;
      if (stored == null && viaDeviceToken) {
        await db.resetPulledCache(
          keepStockAndLedgers: await db.hasUnsentWork(),
        );
        await _mark(tenantId);
        return true;
      }
      if (await hasLocalWork()) {
        throw const PosException(unsentWorkCode, unsentWorkMessage);
      }
      await db.resetTenantCache();
      await _mark(tenantId);
      return true;
    });
  }

  /// Refuses a device enrolment while there is local work: the new
  /// enrolment may be for another shop, and once it is, login is scoped to
  /// that shop — the old one's work could then never be sent or discarded.
  /// Runs before the code is spent.
  Future<void> checkEnrolment() async {
    if (await hasLocalWork()) {
      throw const PosException(enrolUnsentWorkCode, enrolUnsentWorkMessage);
    }
  }

  Future<void> _mark(String tenantId) => db.into(db.appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(key: tenantKey, value: tenantId),
      );

  /// Local work a reset would destroy: [AppDatabase.hasUnsentWork] (any
  /// outbox op — pending, stuck or rejected — or unconfirmed credit payment)
  /// or a parked bill (local-only). An open shift is not here: on the API
  /// build its sales and drawer entries are outbox ops or already on the
  /// server, and the server keeps the shift itself.
  ///
  /// `PendingWrites` is not here either: it is memory-only, holds no data the
  /// server does not decide, and its cart lives in `CartCubit`.
  Future<bool> hasLocalWork() async =>
      await db.hasUnsentWork() ||
      (await (db.select(db.parkedSales)..limit(1)).get()).isNotEmpty;
}
