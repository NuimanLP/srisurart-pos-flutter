// ApiSuppliersRepository — per-product suppliers on the API build (ADR-0010).
//
// The server's `suppliers` table is the truth (an owner backup import writes
// it, 2026-10-08). The Drift `suppliers` table is the cache the screens keep
// reading, so reads stay on the Drift parent and:
//
//  • [pullFromServer] — `GET /suppliers` replaces the cache with the server's
//    whole set. Suppliers are hard-deleted and carry no `updated_at`, so there
//    is no cursor; the table is small. Runs from `getSuppliers` (screen open)
//    and from `triggerEntityPull` (reconnect, tenant reset, owner import).
//  • add / update / delete — `POST/PATCH/DELETE /suppliers` with an
//    `Idempotency-Key`; Drift is written only from the server's accepted
//    reply, never local-first and never on a failure (as ApiSettingsRepository).

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../db/database.dart';
import '../storage/token_storage.dart' show TokenStoreUnavailableException;
import 'api/api_wire.dart';
import 'suppliers_repository.dart';

class ApiSuppliersRepository extends SuppliersRepository {
  ApiSuppliersRepository(super.db, this.apiClient);

  final ApiClient apiClient;

  /// A create whose fate is unknown (5xx, 429, lost reply): the server mints
  /// the id, so the same supplier pressed again must reuse the key or it is
  /// created twice (08 §5).
  final PendingWrites _pendingAdds = PendingWrites();

  /// Bumped with every applied write reply. A pull that started before one
  /// carries an older snapshot; replacing the cache with it would drop the row
  /// just written, so it is discarded instead (as ApiSettingsRepository).
  int _writeGen = 0;

  /// Replaces the Drift cache with the server's suppliers. Never throws;
  /// `false` = the cache was left as it was.
  Future<bool> pullFromServer() async {
    final startWrite = _writeGen;
    final startCache = db.cacheGeneration;
    try {
      final res = await apiClient.get('/api/v1/suppliers');
      if (res is! List) return false;
      final rows = [
        for (final s in res)
          if (s is Map) _rowFromWire(s),
      ];
      var applied = false;
      await db.writeCacheIfCurrent(startCache, () async {
        if (_writeGen != startWrite) return;
        await db.delete(db.suppliers).go();
        await db.batch((b) => b.insertAll(db.suppliers, rows));
        applied = true;
      });
      return applied;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<SupplierRow>> getSuppliers() async {
    await pullFromServer();
    return super.getSuppliers();
  }

  @override
  Future<SupplierRow> addSupplier({
    required String productId,
    required String name,
    required double unitCost,
    double freight = 0,
  }) async {
    final body = {
      'productId': productId,
      'name': name,
      'unitCost': wireMoney(unitCost),
      'freight': wireMoney(freight),
    };
    final attempt = _pendingAdds.of(jsonEncode(body));
    final startCache = db.cacheGeneration;
    final Object? res;
    try {
      res = await apiClient.post(
        '/api/v1/suppliers',
        body: body,
        headers: attempt.headers,
      );
    } on ApiException catch (e) {
      _pendingAdds.closeIfVerdict(attempt, e);
      throw posExceptionFromApi(e);
    } catch (e) {
      throw _notSent(e);
    }
    if (res is! Map) throw unreadableResponse();
    final row = _rowFromWire(res);
    await _apply(startCache, () => db.into(db.suppliers).insertOnConflictUpdate(row));
    // Closed only after the local apply: if it throws, the next press replays.
    _pendingAdds.close(attempt);
    return row;
  }

  @override
  Future<void> updateSupplier(
    String id, {
    Value<String> productId = const Value.absent(),
    Value<String> name = const Value.absent(),
    Value<double> unitCost = const Value.absent(),
    Value<double> freight = const Value.absent(),
  }) async {
    final body = {
      if (productId.present) 'productId': productId.value,
      if (name.present) 'name': name.value,
      if (unitCost.present) 'unitCost': wireMoney(unitCost.value),
      if (freight.present) 'freight': wireMoney(freight.value),
    };
    final startCache = db.cacheGeneration;
    final Object? res;
    try {
      res = await apiClient.patch(
        '/api/v1/suppliers/$id',
        body: body,
        headers: idempotencyKey(),
      );
    } on ApiException catch (e) {
      throw posExceptionFromApi(e);
    } catch (e) {
      throw _notSent(e);
    }
    if (res is! Map) throw unreadableResponse();
    final row = _rowFromWire(res);
    await _apply(startCache, () => db.into(db.suppliers).insertOnConflictUpdate(row));
  }

  @override
  Future<void> deleteSupplier(String id) async {
    final startCache = db.cacheGeneration;
    try {
      await apiClient.delete('/api/v1/suppliers/$id', headers: idempotencyKey());
    } on ApiException catch (e) {
      throw posExceptionFromApi(e);
    } catch (e) {
      throw _notSent(e);
    }
    await _apply(
      startCache,
      () => (db.delete(db.suppliers)..where((t) => t.id.equals(id))).go(),
    );
  }

  /// Writes a reply into the cache unless a tenant switch emptied it since the
  /// request left (the reply is then the old shop's row).
  Future<void> _apply(int startCache, Future<void> Function() write) =>
      db.writeCacheIfCurrent(startCache, () async {
        await write();
        _writeGen++;
      });

  /// A failure with no server answer. No local write either way; a timed-out
  /// write may still have committed, and the next pull shows what the server kept.
  Object _notSent(Object e) {
    // Its `toString()` is already the Thai sentence (#400).
    if (e is TokenStoreUnavailableException) return e;
    return PosException(
      isTransportFailure(e) ? 'NETWORK_ERROR' : 'UNREADABLE_RESPONSE',
      ServerErrorResolver.resolve(null),
    );
  }

  /// A server `Supplier` (`suppliers.service.ts`) → the Drift row.
  static SupplierRow _rowFromWire(Map<dynamic, dynamic> s) => SupplierRow(
        id: s['id'] as String,
        productId: s['productId'] as String,
        name: s['name'] as String,
        unitCost: money(s['unitCost']),
        freight: money(s['freight'] ?? '0'),
      );
}
