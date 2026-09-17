// ApiPurchaseOrdersRepository — write-through cache implementation of PurchaseOrdersRepository.
//
// Complies with ADR-0010:
//  • Server is the source of truth for weighted-average cost and PO state.
//  • receivePO writes through server's updated {stockAfter, costAfter} directly to products.
//  • NO client code re-computes weighted average cost.
//  • Server-provided movements are ingested directly; no client clock stamping on updatedAt.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'movements_repository.dart';
import 'purchase_orders_repository.dart';

class ApiPurchaseOrdersRepository extends PurchaseOrdersRepository {
  final ApiClient apiClient;

  ApiPurchaseOrdersRepository(super.db, this.apiClient);

  Future<void> syncFromServer() async {
    try {
      bool hasMore = true;
      int page = 1;

      while (hasMore) {
        final res = await apiClient.getPaginated(
          '/api/v1/purchase-orders',
          queryParameters: {'page': page, 'limit': 100},
        );
        final items = res.data;

        if (items.isNotEmpty) {
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
    try {
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

      final res = await apiClient.post('/api/v1/purchase-orders', body: body, headers: idempotencyKey());
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final realId = (resMap['id'] ?? newId('po')) as String;
        final realPoNo = (resMap['poNo'] ?? resMap['po_no'] ?? docNo('PO')) as String;
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

        return poRow;
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    return super.savePO(input);
  }

  @override
  Future<List<String>> receivePO(String id) async {
    try {
      final res = await apiClient.post('/api/v1/purchase-orders/$id/receive', headers: idempotencyKey());
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final now = DateTime.now();

        // 1. Mark PO as received in Drift
        await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
          PurchaseOrdersCompanion(
            status: const Value('received'),
            receivedAt: Value(now),
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
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    return super.receivePO(id);
  }

  @override
  Future<void> cancelPO(String id) async {
    try {
      await apiClient.post('/api/v1/purchase-orders/$id/cancel', headers: idempotencyKey());
      await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
        PurchaseOrdersCompanion(
          status: const Value('cancelled'),
          cancelledAt: Value(DateTime.now()),
        ),
      );
      return;
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    await super.cancelPO(id);
  }

  @override
  Future<void> deletePO(String id) async {
    try {
      await apiClient.delete('/api/v1/purchase-orders/$id', headers: idempotencyKey());
      await (db.delete(db.poItems)..where((t) => t.poId.equals(id))).go();
      await (db.delete(db.purchaseOrders)..where((t) => t.id.equals(id))).go();
      return;
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    await super.deletePO(id);
  }
}
