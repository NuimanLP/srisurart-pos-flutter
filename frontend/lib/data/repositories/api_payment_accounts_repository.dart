// ApiPaymentAccountsRepository — the QR payment accounts on the API build
// (owner request 2026-10-10, contract §2/§5).
//
// The server's `payment_accounts` table is the truth. The Drift
// `payment_accounts` table is the cache checkout and the closing report read,
// so reads stay on the Drift parent and:
//
//  • [pullFromServer] — `GET /payment-accounts` (active rows only) REPLACES
//    the cache with the server's whole set: there are at most 5 rows and no
//    cursor. A deleted account therefore leaves the cache; a bill that names it
//    reads `บัญชีที่ลบแล้ว` in the closing report (contract §5, the
//    implementer's choice between removing and marking — removing). Runs on
//    app open / login (`pullOnSignIn`, main.dart), from `triggerEntityPull`
//    (reconnect, tenant reset, owner import) and from [getLatestAccounts] (the Settings
//    section opening, skipped while Degraded).
//  • add / update / setDefault / delete — `POST/PATCH/DELETE
//    /payment-accounts` with an `Idempotency-Key`, online only like
//    `ApiSettingsRepository`: refused while Degraded, Drift written only from
//    the server's accepted reply, never local-first and never on a failure.
//    The client id and key are minted once per attempt ([PendingWrites]): a
//    5xx / 429 / lost reply leaves the attempt parked, so pressing บันทึก again
//    replays it instead of creating a second account (08 §5).

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../db/database.dart';
import '../storage/token_storage.dart' show TokenStoreUnavailableException;
import '../sync/sync_facade.dart';
import 'api/api_wire.dart';
import 'payment_accounts_repository.dart';

class ApiPaymentAccountsRepository extends PaymentAccountsRepository {
  ApiPaymentAccountsRepository(super.db, this.apiClient, {this.syncFacade});

  final ApiClient apiClient;
  final SyncFacade? syncFacade;

  final PendingWrites _pending = PendingWrites();

  /// Bumped with every applied write reply. A pull that started before one
  /// carries an older snapshot; replacing the cache with it would undo the
  /// write just made, so it is dropped (as ApiSuppliersRepository).
  int _writeGen = 0;

  @override
  bool get ownerOnly => true;

  bool get _degraded => syncFacade?.currentStatus == SyncStatus.degraded;

  /// The server's set, except while Degraded: then the cache answers at once
  /// instead of waiting out a request that is expected to fail.
  @override
  Future<List<PaymentAccountRow>> getLatestAccounts() async {
    if (!_degraded) await pullFromServer();
    return getAccounts();
  }

  /// Replaces the Drift cache with the server's accounts. Never throws;
  /// `false` = the cache was left as it was (the reason is logged). A
  /// malformed row fails the whole pull rather than dropping a real account.
  Future<bool> pullFromServer() async {
    final startWrite = _writeGen;
    final startCache = db.cacheGeneration;
    try {
      final res = await apiClient.get('/api/v1/payment-accounts');
      if (res is! List) throw FormatException('not a list: ${res.runtimeType}');
      final rows = [for (final a in res) _rowFromWire(a as Map)];
      var applied = false;
      await db.writeCacheIfCurrent(startCache, () async {
        if (_writeGen != startWrite) return;
        await db.delete(db.paymentAccounts).go();
        await db.batch((b) => b.insertAll(db.paymentAccounts, rows));
        applied = true;
      });
      return applied;
    } catch (e) {
      debugPrint('ApiPaymentAccountsRepository.pullFromServer: not applied — $e');
      return false;
    }
  }

  @override
  Future<PaymentAccountRow> addAccount(PaymentAccountInput input) async {
    _refuseIfDegraded();
    checkPaymentAccountInput(input);
    final fields = <String, Object?>{
      'nickname': input.nickname.trim(),
      'bankCode': input.bankCode,
      'kind': input.kind,
      'promptpayId': input.kind == 'promptpay' ? input.promptpayId : null,
      'imageBase64': input.kind == 'image' ? base64Encode(input.image!) : null,
      'imageMime': input.kind == 'image' ? input.imageMime : null,
      'isDefault': input.isDefault,
    };
    final attempt = _pending.of('create|${jsonEncode(fields)}');
    final startCache = db.cacheGeneration;
    final row = await _send(
      attempt,
      () => apiClient.post(
        '/api/v1/payment-accounts',
        body: {'id': attempt.id, ...fields},
        headers: attempt.headers,
      ),
    );
    await _applyRow(startCache, row);
    // Closed only after the local apply: if it throws, the next press replays.
    _pending.close(attempt);
    return row;
  }

  @override
  Future<void> updateAccount(String id, PaymentAccountsCompanion patch) async {
    _refuseIfDegraded();
    final body = <String, Object?>{
      if (patch.nickname.present) 'nickname': patch.nickname.value.trim(),
      if (patch.bankCode.present) 'bankCode': patch.bankCode.value,
      if (patch.promptpayId.present) 'promptpayId': patch.promptpayId.value,
      if (patch.image.present)
        'imageBase64':
            patch.image.value == null ? null : base64Encode(patch.image.value!),
      if (patch.imageMime.present) 'imageMime': patch.imageMime.value,
      if (patch.isDefault.present) 'isDefault': patch.isDefault.value,
      if (patch.sortOrder.present) 'sortOrder': patch.sortOrder.value,
    };
    final fingerprint = 'patch|$id|${jsonEncode(body)}';
    // A newer, different edit of this account supersedes its older parked
    // ones: a PATCH replaces whole values, so the older edit pressed again
    // must go out under a fresh key, not replay a stale reply (08 §5).
    _pending.closeWhere((f) => f.startsWith('patch|$id|') && f != fingerprint);
    final attempt = _pending.of(fingerprint);
    final startCache = db.cacheGeneration;
    final row = await _send(
      attempt,
      () => apiClient.patch(
        '/api/v1/payment-accounts/$id',
        body: body,
        headers: attempt.headers,
      ),
    );
    await _applyRow(startCache, row);
    _pending.close(attempt);
  }

  @override
  Future<void> deleteAccount(String id) async {
    _refuseIfDegraded();
    final attempt = _pending.of('delete|$id');
    final startCache = db.cacheGeneration;
    try {
      await apiClient.delete(
        '/api/v1/payment-accounts/$id',
        headers: attempt.headers,
      );
    } on ApiException catch (e) {
      _pending.closeIfVerdict(attempt, e);
      rethrowServerRefusal(e);
    } catch (e) {
      throw _notSent(e);
    }
    await db.writeCacheIfCurrent(startCache, () async {
      await (db.delete(db.paymentAccounts)..where((t) => t.id.equals(id))).go();
      _writeGen++;
    });
    _pending.close(attempt);
  }

  void _refuseIfDegraded() {
    if (_degraded) {
      throw const PosException(
        'OFFLINE_ACTION_NOT_ALLOWED',
        paymentAccountsOfflineRefusal,
      );
    }
  }

  /// Sends one write and returns the server's account. A verdict (4xx)
  /// closes the attempt; a 5xx / 429 / transport failure leaves it parked.
  Future<PaymentAccountRow> _send(
    PendingWrite attempt,
    Future<Object?> Function() request,
  ) async {
    final Object? res;
    try {
      res = await request();
    } on ApiException catch (e) {
      _pending.closeIfVerdict(attempt, e);
      rethrowServerRefusal(e);
    } catch (e) {
      throw _notSent(e);
    }
    if (res is! Map) throw unreadableResponse();
    try {
      return _rowFromWire(res);
    } catch (_) {
      throw unreadableResponse();
    }
  }

  /// Writes a reply into the cache unless a tenant switch emptied it since the
  /// request left. `isDefault: true` cleared every other default server-side
  /// in the same transaction (contract §2), so the cache mirrors that.
  Future<void> _applyRow(int startCache, PaymentAccountRow row) async {
    await db.writeCacheIfCurrent(startCache, () async {
      if (row.isDefault) {
        await (db.update(db.paymentAccounts)
              ..where((t) => t.isDefault.equals(true) & t.id.equals(row.id).not()))
            .write(const PaymentAccountsCompanion(isDefault: Value(false)));
      }
      await db.into(db.paymentAccounts).insertOnConflictUpdate(row);
      _writeGen++;
    });
  }

  /// A failure with no server answer. No local write; the attempt stays
  /// parked, and the next pull shows whatever the server kept.
  Object _notSent(Object e) {
    // Its `toString()` is already the Thai sentence (#400).
    if (e is TokenStoreUnavailableException) return e;
    return PosException(
      isTransportFailure(e) ? 'NETWORK_ERROR' : 'UNREADABLE_RESPONSE',
      ServerErrorResolver.resolve(null),
    );
  }

  /// A server account (contract §2 wire shape) → the Drift row.
  static PaymentAccountRow _rowFromWire(Map<dynamic, dynamic> a) {
    final image = a['imageBase64'];
    final updatedAt = a['updatedAt'];
    return PaymentAccountRow(
      id: a['id'] as String,
      nickname: a['nickname'] as String,
      bankCode: a['bankCode'] as String,
      kind: a['kind'] as String,
      promptpayId: a['promptpayId'] as String?,
      image: image is String && image.isNotEmpty ? base64Decode(image) : null,
      imageMime: a['imageMime'] as String?,
      isDefault: a['isDefault'] as bool? ?? false,
      sortOrder: (a['sortOrder'] as num?)?.toInt() ?? 0,
      updatedAt:
          updatedAt is String ? DateTime.tryParse(updatedAt)?.toLocal() : null,
    );
  }
}
