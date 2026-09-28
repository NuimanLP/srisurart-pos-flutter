// ApiSettingsRepository — the shop settings on the API build (#460, ADR-0010).
//
// The server's `settings` row is the truth. The Drift singleton (id = 0) is
// the cache every screen already reads — receipts, quotes, the shell header —
// so reads stay on the Drift parent and only two things change here:
//
//  • [pullFromServer] — `GET /settings` after sign-in patches the cache, so
//    the till stops showing the Drift seed's shop name. Also fired from
//    `SyncService.onPull` (`triggerEntityPull`, #474) so a session that
//    survived a restart while offline still gets fresh settings once the
//    link comes back, instead of waiting for the next login.
//  • [updateSettings] — a settings edit is `PATCH /settings`. Settings are
//    online-only (08 §6.2): when the server cannot take the edit it is
//    refused, never written locally.
//
// Not `GET /bootstrap`: its payload also upserts every product, and that path
// (`BootstrapService._applyBootstrapPayload`) skips the pending-outbox stock
// guard `ApiProductsRepository.syncFromServer` has (08 §15). Products,
// customers and mechanics already arrive through `SyncService.onPull`.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../db/database.dart';
import '../storage/token_storage.dart' show TokenStoreUnavailableException;
import '../sync/sync_facade.dart';
import 'api/api_wire.dart';
import 'settings_repository.dart';

class ApiSettingsRepository extends SettingsRepository {
  ApiSettingsRepository(super.db, this.apiClient, {this.syncFacade});

  final ApiClient apiClient;
  final SyncFacade? syncFacade;

  /// Pulls the tenant's settings into the Drift row. Never throws — sign-in
  /// fires it unawaited (must not block the first screen), and
  /// `triggerEntityPull` fires it inside its own `Future.wait` (#474) since
  /// it never rejects that batch either way; `false` means the cache was
  /// left as it was.
  Future<bool> pullFromServer() async {
    try {
      final res = await apiClient.get('/api/v1/settings');
      if (res is! Map) return false;
      await _patchFromWire(res);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> updateSettings(SettingsRowCompanion patch) async {
    // Degraded only — the Settings screen's own pre-check (`context.isDegraded`).
    // Unlike a queued customer write, a settings edit does not wait behind the
    // outbox, so `syncing` / a non-empty outbox do not refuse it.
    if (syncFacade?.currentStatus == SyncStatus.degraded) {
      throw const PosException(
        'OFFLINE_ACTION_NOT_ALLOWED',
        settingsOfflineRefusal,
      );
    }

    final dynamic res;
    try {
      res = await apiClient.patch(
        '/api/v1/settings',
        body: _patchBody(patch),
        headers: idempotencyKey(),
      );
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (e) {
      // Its `toString()` is already the Thai sentence (#400).
      if (e is TokenStoreUnavailableException) rethrow;
      // No local write either way. A timed-out PATCH may still have committed;
      // the next pull shows whatever the server kept.
      throw PosException(
        isTransportFailure(e) ? 'NETWORK_ERROR' : 'UNREADABLE_RESPONSE',
        ServerErrorResolver.resolve(null),
      );
    }
    if (res is! Map) {
      throw PosException(
        'UNREADABLE_RESPONSE',
        ServerErrorResolver.resolve(null),
      );
    }
    await _patchFromWire(res);
  }

  /// Only the fields the edit actually set — `PATCH /settings` leaves every
  /// key it is not sent alone (`parseSettingsPatch`).
  static Map<String, dynamic> _patchBody(SettingsRowCompanion p) => {
    if (p.shopName.present) 'shopName': p.shopName.value,
    if (p.shopNameEN.present) 'shopNameEn': p.shopNameEN.value,
    if (p.taxRate.present) 'taxRate': p.taxRate.value,
    if (p.quoteValidDays.present) 'quoteValidDays': p.quoteValidDays.value,
    if (p.address.present) 'address': p.address.value,
    if (p.phone.present) 'phone': p.phone.value,
    if (p.cashierName.present) 'cashierName': p.cashierName.value,
    if (p.taxId.present) 'taxId': p.taxId.value,
    if (p.branchNo.present) 'branchNo': p.branchNo.value,
  };

  /// A server `Settings` object → the Drift row. 🔴 A key the reply omits
  /// leaves its column alone (ADR-0010); a key sent as `null` clears it.
  Future<void> _patchFromWire(Map<dynamic, dynamic> s) async {
    Value<String?> nullable(String key) {
      if (!s.containsKey(key)) return const Value.absent();
      final v = s[key];
      if (v == null || v is String) return Value(v as String?);
      return const Value.absent();
    }

    final shopName = s['shopName'];
    final shopNameEn = s['shopNameEn'];
    final taxRate = s['taxRate'];
    final quoteValidDays = s['quoteValidDays'];
    // tryParse, not `stamp`: after a committed PATCH an unreadable stamp must
    // not surface as an error for an edit the server already kept.
    final updatedAt =
        s['updatedAt'] is String ? DateTime.tryParse(s['updatedAt'] as String) : null;
    final companion = SettingsRowCompanion(
      shopName: shopName is String ? Value(shopName) : const Value.absent(),
      shopNameEN: shopNameEn is String ? Value(shopNameEn) : const Value.absent(),
      taxRate: taxRate is num ? Value(taxRate.toDouble()) : const Value.absent(),
      quoteValidDays: quoteValidDays is num
          ? Value(quoteValidDays.toInt())
          : const Value.absent(),
      address: nullable('address'),
      phone: nullable('phone'),
      cashierName: nullable('cashierName'),
      taxId: nullable('taxId'),
      branchNo: nullable('branchNo'),
      updatedAt: updatedAt != null ? Value(updatedAt.toLocal()) : const Value.absent(),
    );
    if (companion == const SettingsRowCompanion()) return;
    await (db.update(db.settingsRow)..where((t) => t.id.equals(0)))
        .write(companion);
  }
}
