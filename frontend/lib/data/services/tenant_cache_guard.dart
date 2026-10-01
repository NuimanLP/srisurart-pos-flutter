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

import 'package:drift/drift.dart';

import '../../core/network/api_exception.dart';
import '../db/database.dart';

class TenantCacheGuard {
  TenantCacheGuard(this.db);

  final AppDatabase db;

  /// app_meta key: the tenant whose data the local DB holds.
  static const String tenantKey = 'tenant_id';

  static const String unsentWorkCode = 'TENANT_SWITCH_UNSENT_WORK';

  /// agent ร่าง (2026-10-01) — 02_API_SCREENS.md §8.1.1, not yet ratified.
  static const String unsentWorkMessage =
      'เครื่องนี้ยังมีงานของร้านเดิมค้างอยู่ (รายการค้างส่ง ชำระเครดิตค้างส่ง '
      'บิลพัก หรือกะที่ยังไม่ปิด) กรุณาเข้าสู่ระบบร้านเดิมเพื่อส่งหรือยกเลิกรายการ '
      'และปิดกะให้เรียบร้อยก่อน จึงจะเข้าสู่ระบบร้านอื่นได้';

  /// Lets [tenantId] use the local DB. Returns true when the cache was emptied
  /// (the caller then pulls everything again), false when kept.
  ///
  /// - same tenant as the marker → kept.
  /// - another tenant → refused with [unsentWorkCode] while anything local
  ///   would be lost ([_hasUnsentWork]); otherwise emptied and re-marked.
  /// - no marker (every DB from before this guard) — whose data it holds is
  ///   unknown:
  ///   * [viaDeviceToken]: the server resolved this login through the
  ///     device token, i.e. scoped it to the tenant the browser is enrolled
  ///     to, and a `pos` till's local shift/sales history is never pulled
  ///     back from the server — so the data is adopted as this tenant's, not
  ///     wiped (that is the demo till's case).
  ///   * otherwise emptied if nothing would be lost, else refused: refusing
  ///     is the only option that neither leaks nor destroys.
  ///
  /// A null [tenantId] (a token with no `tid` — the server always sets one)
  /// changes nothing.
  Future<bool> admit(String? tenantId, {required bool viaDeviceToken}) {
    if (tenantId == null || tenantId.isEmpty) return Future.value(false);
    return db.transaction(() async {
      final stored = await (db.select(db.appMeta)
            ..where((t) => t.key.equals(tenantKey)))
          .getSingleOrNull();
      if (stored?.value == tenantId) return false;
      if (stored == null && viaDeviceToken) {
        await _mark(tenantId);
        return false;
      }
      if (await _hasUnsentWork()) {
        throw const PosException(unsentWorkCode, unsentWorkMessage);
      }
      await db.resetTenantCache();
      await _mark(tenantId);
      return true;
    });
  }

  Future<void> _mark(String tenantId) => db.into(db.appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(key: tenantKey, value: tenantId),
      );

  /// Local work a reset would destroy: any outbox op (pending, stuck or
  /// rejected — the same rule as closing a shift, 08 §11), an unconfirmed
  /// credit payment, a parked bill (local-only), or a shift still open.
  ///
  /// `PendingWrites` is not here: it is memory-only, holds no data the server
  /// does not decide, and its cart lives in `CartCubit`.
  Future<bool> _hasUnsentWork() async {
    Future<bool> any(TableInfo table, [Expression<bool>? where]) async {
      final q = db.selectOnly(table)..addColumns([const Constant(1)]);
      if (where != null) q.where(where);
      q.limit(1);
      return (await q.get()).isNotEmpty;
    }

    return await any(db.outboxOps) ||
        await any(db.pendingCreditPayments) ||
        await any(db.parkedSales) ||
        await any(
          db.shifts,
          db.shifts.isActive.equals(true) & db.shifts.closedAt.isNull(),
        );
  }
}
