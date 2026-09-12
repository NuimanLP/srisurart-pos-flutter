// ApiPurchaseOrdersRepository — write-through cache implementation of PurchaseOrdersRepository.
//
// Complies with ADR-0010:
//  • Server is the source of truth for weighted-average cost and PO state.
//  • receivePO writes through server's updated {stockAfter, costAfter} directly to products.
//  • NO client code re-computes weighted average cost.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';
import 'movements_repository.dart';
import 'purchase_orders_repository.dart';

class ApiPurchaseOrdersRepository extends PurchaseOrdersRepository {
  final ApiClient apiClient;

  ApiPurchaseOrdersRepository(super.db, this.apiClient);

  Future<void> syncFromServer() async {
    try {
      final res = await apiClient.get('/api/v1/purchase-orders');
      if (res is List) {
        for (final item in res) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final poId = map['id'] as String;
            final poNo = (map['poNo'] ?? map['po_no'] ?? '') as String;
            final supplier = (map['supplier'] ?? '') as String;
            final status = (map['status'] ?? 'open') as String;
            final createdAtStr = map['createdAt'] ?? map['created_at'];
            final createdAt = createdAtStr != null
                ? DateTime.tryParse(createdAtStr.toString()) ?? DateTime.now()
                : DateTime.now();
            final receivedAtStr = map['receivedAt'] ?? map['received_at'];
            final receivedAt = receivedAtStr != null
                ? DateTime.tryParse(receivedAtStr.toString())
                : null;
            final cancelledAtStr = map['cancelledAt'] ?? map['cancelled_at'];
            final cancelledAt = cancelledAtStr != null
                ? DateTime.tryParse(cancelledAtStr.toString())
                : null;

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

            final items = item['items'];
            if (items is List) {
              await (db.delete(db.poItems)..where((t) => t.poId.equals(poId))).go();
              for (final line in items) {
                if (line is Map) {
                  final lineMap = Map<String, dynamic>.from(line);
                  final partNo = (lineMap['partNo'] ?? lineMap['part_no'] ?? '') as String;
                  final name = (lineMap['name'] ?? '') as String;
                  final qty = (lineMap['qty'] as num?)?.toInt() ?? 0;
                  final cost = lineMap['cost'] is num
                      ? (lineMap['cost'] as num).toDouble()
                      : double.tryParse('${lineMap['cost']}') ?? 0.0;

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
    } catch (_) {}
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
            .map((item) => {
                  'partNo': item.partNo,
                  'name': item.name,
                  'qty': item.qty,
                  'cost': item.cost.toStringAsFixed(2),
                })
            .toList(),
      };

      final res = await apiClient.post('/api/v1/purchase-orders', body: body);
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final poId = (resMap['id'] ?? newId('po')) as String;
        final poNo = (resMap['poNo'] ?? resMap['po_no'] ?? docNo('PO')) as String;
        final createdAtStr = resMap['createdAt'] ?? resMap['created_at'];
        final createdAt = createdAtStr != null
            ? DateTime.tryParse(createdAtStr.toString()) ?? DateTime.now()
            : DateTime.now();

        final row = PurchaseOrderRow(
          id: poId,
          poNo: poNo,
          supplier: input.supplier,
          createdAt: createdAt,
          status: 'open',
        );

        await db.into(db.purchaseOrders).insertOnConflictUpdate(row);

        for (final item in input.items) {
          await db.into(db.poItems).insert(
                PoItemsCompanion.insert(
                  poId: poId,
                  partNo: item.partNo,
                  name: item.name,
                  qty: item.qty,
                  cost: item.cost,
                ),
              );
        }

        return row;
      }
    } catch (_) {
      // Offline fallback
    }

    return super.savePO(input);
  }

  @override
  Future<List<String>> receivePO(String id) async {
    try {
      final res = await apiClient.post('/api/v1/purchase-orders/$id/receive');
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

        // 2. Patch updated products directly with server's new stock and cost
        final updated = resMap['updated'];
        if (updated is List) {
          for (final u in updated) {
            if (u is Map) {
              final uMap = Map<String, dynamic>.from(u);
              final partNo = (uMap['partNo'] ?? uMap['part_no'] ?? '') as String;
              final stockAfter = (uMap['stockAfter'] ?? uMap['stock_after'] as num?)?.toInt();
              final costAfter = uMap['costAfter'] is num
                  ? (uMap['costAfter'] as num).toDouble()
                  : double.tryParse('${uMap['costAfter'] ?? uMap['cost_after']}');

              final product = await (db.select(db.products)
                    ..where((t) => t.partNo.equals(partNo)))
                  .getSingleOrNull();

              if (product != null && stockAfter != null && costAfter != null) {
                await (db.update(db.products)..where((t) => t.id.equals(product.id))).write(
                  ProductsCompanion(
                    stock: Value(stockAfter),
                    cost: Value(costAfter),
                    updatedAt: Value(now),
                  ),
                );

                final delta = stockAfter - product.stock;
                await MovementsRepository(db).addMovement(
                  productId: product.id,
                  partNo: product.partNo,
                  name: product.name,
                  delta: delta,
                  type: 'receive',
                  note: 'PO $poNo จาก $supplier · ทุนใหม่ ฿${costAfter.toStringAsFixed(2)}',
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
    } catch (_) {
      // Offline fallback
    }

    return super.receivePO(id);
  }

  @override
  Future<void> cancelPO(String id) async {
    try {
      await apiClient.post('/api/v1/purchase-orders/$id/cancel');
    } catch (_) {}

    await super.cancelPO(id);
  }

  @override
  Future<void> deletePO(String id) async {
    try {
      await apiClient.delete('/api/v1/purchase-orders/$id');
    } catch (_) {}

    await super.deletePO(id);
  }
}
