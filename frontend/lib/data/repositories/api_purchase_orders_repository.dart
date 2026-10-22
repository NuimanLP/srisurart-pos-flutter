// ApiPurchaseOrdersRepository — write-through cache implementation of PurchaseOrdersRepository.
//
// Complies with ADR-0010:
//  • Server is the source of truth for weighted-average cost and PO state.
//  • receivePO writes through server's updated {stockAfter, costAfter} directly to products.
//  • NO client code re-computes weighted average cost.
//  • Server-provided movements are ingested directly; no client clock stamping on updatedAt.
//  • Every write is parked in [PendingWrites] (api_wire.dart): the same action
//    pressed again after a lost reply (5xx, 429, timeout) goes out under the
//    SAME `Idempotency-Key`, so the server replays the first one instead of
//    creating a second PO. Only a 4xx closes an attempt early; otherwise it
//    closes only after the local apply has succeeded.
//  • The server mints the PO id and number. A reply without them is a
//    contract error (the attempt stays parked) — never filled in locally.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'movements_repository.dart';
import 'purchase_orders_repository.dart';

class ApiPurchaseOrdersRepository extends PurchaseOrdersRepository {
  final ApiClient apiClient;

  ApiPurchaseOrdersRepository(super.db, this.apiClient);

  /// Writes sent and never answered with a verdict — see [PendingWrites].
  final PendingWrites _pending = PendingWrites();

  /// POs whose receive was sent and got no verdict (5xx, 429, lost reply).
  /// Unlike [_pending] this has no TTL: receiving one PO twice is never two
  /// real actions, so a `409 PO_ALREADY_RECEIVED` for one of these (the parked
  /// key expired, or the first attempt committed) means OUR receive landed.
  /// In memory only: an app restart forgets it, and the 409 then shows as an
  /// error (the PO list's next pull still shows it received).
  final Set<String> _receiveFateUnknown = {};

  /// Sends one parked write. A 4xx closes the attempt; a 5xx / 429 / transport
  /// failure leaves it parked so the next press replays it under the same key.
  Future<Object?> _send(
    PendingWrite attempt,
    Future<Object?> Function(Map<String, String> headers) call,
  ) async {
    try {
      return await call(attempt.headers);
    } on ApiException catch (e) {
      _pending.closeIfVerdict(attempt, e);
      throw posExceptionFromApi(e);
    }
  }

  Future<void> syncFromServer() async {
    // A reset (tenant switch) while this pull is in flight voids its replies.
    final gen = db.cacheGeneration;
    try {
      bool hasMore = true;
      int page = 1;

      while (hasMore) {
        final res = await apiClient.getPaginated(
          '/api/v1/purchase-orders',
          queryParameters: {'page': page, 'limit': 100},
        );
        final items = res.data;

        if (items.isNotEmpty &&
            !await db.writeCacheIfCurrent(gen, () async {
          for (final item in items) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final poId = map['id'] as String;
              final poNo = (map['poNo'] ?? map['po_no'] ?? '') as String;
              final supplier = (map['supplier'] ?? '') as String;
              final status = (map['status'] ?? 'open') as String;
              final createdAt = stampOrNull(map['createdAt'] ?? map['created_at']) ?? DateTime.now();
              final receivedAt = stampOrNull(map['receivedAt'] ?? map['received_at']);
              final cancelledAt = stampOrNull(map['cancelledAt'] ?? map['cancelled_at']);

              await db.into(db.purchaseOrders).insert(
                    PurchaseOrdersCompanion(
                      id: Value(poId),
                      poNo: Value(poNo),
                      supplier: Value(supplier),
                      status: Value(status),
                      createdAt: Value(createdAt),
                      receivedAt: Value(receivedAt),
                      cancelledAt: Value(cancelledAt),
                    ),
                    onConflict: DoUpdate((old) => PurchaseOrdersCompanion(
                          status: Value(status),
                          receivedAt: Value(receivedAt),
                          cancelledAt: Value(cancelledAt),
                        )),
                  );

              final poLines = item['items'];
              if (poLines is List) {
                await (db.delete(db.poItems)..where((t) => t.poId.equals(poId))).go();
                for (final line in poLines) {
                  if (line is Map) {
                    final lineMap = Map<String, dynamic>.from(line);
                    final partNo = (lineMap['partNo'] ?? lineMap['part_no'] ?? '') as String;
                    final name = (lineMap['name'] ?? '') as String;
                    final qty = (lineMap['qty'] as num?)?.toInt() ?? 0;
                    final cost = money(lineMap['cost']);

                    await db.into(db.poItems).insert(
                          PoItemsCompanion.insert(
                            poId: poId,
                            partNo: partNo,
                            name: name,
                            qty: qty,
                            cost: cost,
                          ),
                        );
                  }
                }
              }
            }
          }
        })) {
          return;
        }

        if (page >= res.totalPages || items.isEmpty) {
          hasMore = false;
        } else {
          page++;
        }
      }
    } catch (_) {
      // Network failure or degraded mode: gracefully ignore and rely on Drift cache
    }
  }

  @override
  Future<List<PurchaseOrderWithItems>> getPOs() async {
    await syncFromServer();
    return super.getPOs();
  }

  @override
  Future<PurchaseOrderRow> savePO(PoInput input) async {
    final body = {
      'supplier': input.supplier,
      'items': input.items
          .map((i) => {
                'partNo': i.partNo,
                'name': i.name,
                'qty': i.qty,
                'cost': wireMoney(i.cost),
              })
          .toList(),
    };

    // The body is the fingerprint: the same PO pressed again is the same bytes.
    final attempt = _pending.of('create|${jsonEncode(body)}');
    final res = await _send(
      attempt,
      (headers) => apiClient.post('/api/v1/purchase-orders', body: body, headers: headers),
    );
    if (res is! Map) throw unreadableResponse();
    final resMap = Map<String, dynamic>.from(res);
    final realId = resMap['id'];
    final realPoNo = resMap['poNo'] ?? resMap['po_no'];
    // Server-owned: a reply without them is a contract error, never filled in.
    if (realId is! String || realId.isEmpty || realPoNo is! String || realPoNo.isEmpty) {
      throw unreadableResponse();
    }
    final status = (resMap['status'] ?? 'open') as String;
    final createdAt = stampOrNull(resMap['createdAt'] ?? resMap['created_at']) ?? DateTime.now();

    final poRow = PurchaseOrderRow(
      id: realId,
      poNo: realPoNo,
      supplier: input.supplier,
      status: status,
      createdAt: createdAt,
      receivedAt: null,
      cancelledAt: null,
    );

    await db.transaction(() async {
      await db.into(db.purchaseOrders).insertOnConflictUpdate(poRow);
      await (db.delete(db.poItems)..where((t) => t.poId.equals(realId))).go();

      for (final item in input.items) {
        await db.into(db.poItems).insert(
              PoItemsCompanion.insert(
                poId: realId,
                partNo: item.partNo,
                name: item.name,
                qty: item.qty,
                cost: item.cost,
              ),
            );
      }
    });
    // Closed only after the local apply: if it throws, the next press replays.
    _pending.close(attempt);
    return poRow;
  }

  @override
  Future<List<String>> receivePO(String id) async {
    final attempt = _pending.of('receive|$id');
    final Object? res;
    try {
      res = await apiClient.post('/api/v1/purchase-orders/$id/receive', headers: attempt.headers);
    } on ApiException catch (e) {
      if (e.code == 'PO_ALREADY_RECEIVED' && _receiveFateUnknown.contains(id)) {
        // Our earlier receive committed and its reply was lost. The stock
        // numbers it carried are gone with it; the products pull brings them.
        await _markReceivedFromServer(id);
        _receiveFateUnknown.remove(id);
        _pending.close(attempt);
        return const [];
      }
      if (isVerdict(e)) {
        _pending.close(attempt);
        _receiveFateUnknown.remove(id);
      } else {
        _receiveFateUnknown.add(id);
      }
      throw posExceptionFromApi(e);
    } catch (_) {
      // Transport failure / timeout: the receive may have committed.
      _receiveFateUnknown.add(id);
      rethrow;
    }
    if (res is! Map) {
      // A 2xx we cannot read: the receive probably committed.
      _receiveFateUnknown.add(id);
      throw unreadableResponse();
    }
    final resMap = Map<String, dynamic>.from(res);
    final unmatched = await db.transaction(() => _applyReceive(id, resMap));
    _receiveFateUnknown.remove(id);
    // Closed only after the local apply: if it throws, the next press replays.
    _pending.close(attempt);
    return unmatched;
  }

  /// A `409 PO_ALREADY_RECEIVED` for a receive of ours whose fate was unknown:
  /// the PO is received on the server. Its status and `receivedAt` come from
  /// `GET /purchase-orders/:id`; if that read fails, only the status (which the
  /// 409 itself states) is written.
  Future<void> _markReceivedFromServer(String id) async {
    DateTime? receivedAt;
    try {
      final po = await apiClient.get('/api/v1/purchase-orders/$id');
      if (po is Map) receivedAt = stampOrNull(po['receivedAt'] ?? po['received_at']);
    } catch (_) {
      // The status alone is still the server's verdict.
    }
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
      PurchaseOrdersCompanion(
        status: const Value('received'),
        receivedAt: receivedAt == null ? const Value.absent() : Value(receivedAt),
      ),
    );
  }

  /// Writes an accepted receive reply into Drift; returns the unmatched part numbers.
  Future<List<String>> _applyReceive(String id, Map<String, dynamic> resMap) async {
    // 1. Mark PO as received in Drift — at the server's time when it says.
    final receivedAt = stampOrNull(resMap['receivedAt'] ?? resMap['received_at']) ?? DateTime.now();
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
      PurchaseOrdersCompanion(
        status: const Value('received'),
        receivedAt: Value(receivedAt),
      ),
    );

    final po = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(id))).getSingleOrNull();
    final supplier = po?.supplier ?? '';
    final poNo = po?.poNo ?? '';

    // 2. Patch updated products directly with server's new stock and cost (ADR-0010: no client clock on updatedAt)
    final updated = resMap['updated'];
    if (updated is List) {
      for (final u in updated) {
        if (u is Map) {
          final uMap = Map<String, dynamic>.from(u);
          final prodId = uMap['productId'] as String?;
          final partNo = (uMap['partNo'] ?? uMap['part_no'] ?? '') as String;
          final stockAfter = (uMap['stockAfter'] ?? uMap['stock_after'] as num?)?.toInt();
          final costAfter = moneyOrNull(uMap['costAfter'] ?? uMap['cost_after']);

          ProductRow? product;
          if (prodId != null && prodId.isNotEmpty) {
            product = await (db.select(db.products)..where((t) => t.id.equals(prodId))).getSingleOrNull();
          }
          product ??= await (db.select(db.products)..where((t) => t.partNo.equals(partNo))).getSingleOrNull();

          if (product != null && stockAfter != null && costAfter != null) {
            await (db.update(db.products)..where((t) => t.id.equals(product!.id))).write(
              ProductsCompanion(
                stock: Value(stockAfter),
                cost: Value(costAfter),
              ),
            );
          }
        }
      }
    }

    // 3. Ingest movements from server if present; fallback to local movement if absent
    final movements = resMap['movements'];
    if (movements is List && movements.isNotEmpty) {
      for (final mv in movements) {
        if (mv is Map<String, dynamic>) {
          await db.into(db.movements).insertOnConflictUpdate(movementRowFromWire(mv));
        }
      }
    } else if (updated is List) {
      for (final u in updated) {
        if (u is Map) {
          final uMap = Map<String, dynamic>.from(u);
          final partNo = (uMap['partNo'] ?? uMap['part_no'] ?? '') as String;
          final stockAfter = (uMap['stockAfter'] ?? uMap['stock_after'] as num?)?.toInt();
          final costAfter = moneyOrNull(uMap['costAfter'] ?? uMap['cost_after']);

          final product = await (db.select(db.products)..where((t) => t.partNo.equals(partNo))).getSingleOrNull();
          if (product != null && stockAfter != null && costAfter != null) {
            final delta = stockAfter - product.stock;
            await MovementsRepository(db).addMovement(
              productId: product.id,
              partNo: product.partNo,
              name: product.name,
              delta: delta,
              type: 'receive',
              note: 'PO $poNo จาก $supplier · ทุนใหม่ ฿${wireMoney(costAfter)}',
              stockAfter: stockAfter,
            );
          }
        }
      }
    }

    final unmatched = resMap['unmatched'];
    if (unmatched is List) {
      return unmatched.map((e) => e.toString()).toList();
    }
    return [];
  }

  @override
  Future<void> cancelPO(String id) async {
    final attempt = _pending.of('cancel|$id');
    final res = await _send(
      attempt,
      (headers) => apiClient.post('/api/v1/purchase-orders/$id/cancel', headers: headers),
    );
    final cancelledAt = res is Map ? stampOrNull(res['cancelledAt'] ?? res['cancelled_at']) : null;
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
      PurchaseOrdersCompanion(
        status: const Value('cancelled'),
        cancelledAt: Value(cancelledAt ?? DateTime.now()),
      ),
    );
    _pending.close(attempt);
  }

  @override
  Future<void> deletePO(String id) async {
    final attempt = _pending.of('delete|$id');
    await _send(
      attempt,
      (headers) => apiClient.delete('/api/v1/purchase-orders/$id', headers: headers),
    );
    await db.transaction(() async {
      await (db.delete(db.poItems)..where((t) => t.poId.equals(id))).go();
      await (db.delete(db.purchaseOrders)..where((t) => t.id.equals(id))).go();
    });
    _pending.close(attempt);
  }
}
