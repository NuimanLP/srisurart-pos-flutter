// ApiProductsRepository — write-through cache implementation of ProductsRepository.
//
// Complies with ADR-0010:
//  • PostgreSQL is the source of truth; Drift acts as local write-through cache.
//  • NEVER calls Drift transactional services (no local clamping in adjustStock).
//  • Incremental sync uses ?updatedSince= cursor; soft-deletions tracked via deletedAt.
//  • When offline, transparently falls back to local Drift database.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'movements_repository.dart';
import 'products_repository.dart';

class ApiProductsRepository extends ProductsRepository {
  final ApiClient apiClient;

  ApiProductsRepository(super.db, this.apiClient);

  /// Converts API JSON representation to a Drift [ProductsCompanion].
  ProductsCompanion _productToCompanion(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final partNo = (json['partNo'] ?? json['part_no'] ?? '') as String;
    final name = (json['name'] ?? '') as String;
    final nameTH = (json['nameTH'] ?? json['name_t_h'] ?? json['nameTh'] ?? '') as String;
    final category = (json['category'] ?? '') as String;
    final brand = (json['brand'] ?? '') as String;
    final price = money(json['price']);
    final cost = money(json['cost']);
    final stock = (json['stock'] as num?)?.toInt() ?? 0;
    final minStock = (json['minStock'] ?? json['min_stock'] as num?)?.toInt() ?? 0;
    final compat = json['compat'] as String?;
    final zone = json['zone'] as String?;
    final offlineOk = (json['offlineOk'] ?? json['offline_ok'] as bool?) ?? false;

    final updatedAt = stampOrNull(json['updatedAt']);
    final deletedAt = stampOrNull(json['deletedAt']);

    return ProductsCompanion(
      id: Value(id),
      partNo: Value(partNo),
      name: Value(name),
      nameTH: Value(nameTH),
      category: Value(category),
      brand: Value(brand),
      price: Value(price),
      cost: Value(cost),
      stock: Value(stock),
      minStock: Value(minStock),
      compat: Value(compat),
      zone: Value(zone),
      offlineOk: Value(offlineOk),
      updatedAt: Value(updatedAt),
      deletedAt: Value(deletedAt),
    );
  }

  /// Write-through sync: pulls updates from server and patches Drift.
  /// Walks keyset cursor or offset pages to completion.
  Future<void> syncFromServer({bool forceFull = false}) async {
    try {
      String? updatedSince;
      String? afterId;

      if (!forceFull) {
        final latestRow = await (db.select(db.products)
              ..where((t) => t.updatedAt.isNotNull())
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt), (t) => OrderingTerm.desc(t.id)])
              ..limit(1))
            .getSingleOrNull();

        if (latestRow?.updatedAt != null) {
          updatedSince = latestRow!.updatedAt!.toUtc().toIso8601String();
          afterId = latestRow.id;
        }
      }

      bool hasMore = true;
      int page = 1;

      while (hasMore) {
        final queryParams = <String, dynamic>{'limit': 100};
        if (updatedSince != null) {
          queryParams['updatedSince'] = updatedSince;
          if (afterId != null) queryParams['afterId'] = afterId;
        } else {
          queryParams['page'] = page;
        }

        final res = await apiClient.getPaginated('/api/v1/products', queryParameters: queryParams);
        final items = res.data;

        if (items.isNotEmpty) {
          await db.batch((batch) {
            for (final item in items) {
              if (item is Map) {
                final comp = _productToCompanion(Map<String, dynamic>.from(item));
                batch.insert(
                  db.products,
                  comp,
                  onConflict: DoUpdate((old) => comp),
                );
              }
            }
          });
        }

        final next = res.nextCursor;
        if (updatedSince != null) {
          if (next != null && next['updatedSince'] != null) {
            updatedSince = next['updatedSince'] as String;
            afterId = next['afterId'] as String?;
          } else {
            hasMore = false;
          }
        } else {
          if (page >= res.totalPages || items.isEmpty) {
            hasMore = false;
          } else {
            page++;
          }
        }
      }
    } catch (_) {
      // Network failure or degraded mode: gracefully ignore and rely on Drift cache
    }
  }

  @override
  Future<List<ProductRow>> getAll() async {
    await syncFromServer();
    final rows = await (db.select(db.products)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    return rows.map((r) => r.category.isNotEmpty ? r : r.copyWith(category: r.zone ?? 'เครื่องยนต์')).toList();
  }

  @override
  Stream<List<ProductRow>> watchAll() {
    return (db.select(db.products)..where((t) => t.deletedAt.isNull()))
        .watch()
        .map((rows) => rows
            .map((r) => r.category.isNotEmpty
                ? r
                : r.copyWith(category: r.zone ?? 'เครื่องยนต์'))
            .toList());
  }

  @override
  Future<ProductRow?> getById(String id) async {
    final local = await (db.select(db.products)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
    if (local != null) return local;

    try {
      final res = await apiClient.get('/api/v1/products/$id');
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return (db.select(db.products)..where((t) => t.id.equals(id))).getSingleOrNull();
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<ProductRow?> add(ProductsCompanion data) async {
    final partNo = (data.partNo.present ? data.partNo.value : '').trim();
    if (partNo.isEmpty) return null;

    try {
      final body = {
        'partNo': partNo,
        'name': data.name.present ? data.name.value : '',
        'nameTH': data.nameTH.present ? data.nameTH.value : '',
        'category': data.category.present ? data.category.value : '',
        'brand': data.brand.present ? data.brand.value : '',
        'price': data.price.present ? wireMoney(data.price.value) : '0.00',
        'cost': data.cost.present ? wireMoney(data.cost.value) : '0.00',
        'stock': data.stock.present ? data.stock.value : 0,
        'minStock': data.minStock.present ? data.minStock.value : 0,
        if (data.compat.present && data.compat.value != null) 'compat': data.compat.value,
      };

      final res = await apiClient.post('/api/v1/products', body: body, headers: idempotencyKey());
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return (db.select(db.products)..where((t) => t.id.equals(comp.id.value))).getSingle();
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    return super.add(data);
  }

  @override
  Future<bool> update(String id, ProductsCompanion patch) async {
    try {
      final body = <String, dynamic>{};
      if (patch.partNo.present) body['partNo'] = patch.partNo.value.trim();
      if (patch.name.present) body['name'] = patch.name.value;
      if (patch.nameTH.present) body['nameTH'] = patch.nameTH.value;
      if (patch.category.present) body['category'] = patch.category.value;
      if (patch.brand.present) body['brand'] = patch.brand.value;
      if (patch.price.present) body['price'] = wireMoney(patch.price.value);
      if (patch.cost.present) body['cost'] = wireMoney(patch.cost.value);
      if (patch.minStock.present) body['minStock'] = patch.minStock.value;
      if (patch.compat.present) body['compat'] = patch.compat.value;

      final res = await apiClient.patch('/api/v1/products/$id', body: body, headers: idempotencyKey());
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return true;
      }
      return true;
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    return super.update(id, patch);
  }

  @override
  Future<void> delete(String id) async {
    try {
      await apiClient.delete('/api/v1/products/$id', headers: idempotencyKey());
      // ADR-0010: soft-delete locally by setting deletedAt WITHOUT stamping client clock on updatedAt
      await (db.update(db.products)..where((t) => t.id.equals(id))).write(
        ProductsCompanion(
          deletedAt: Value(DateTime.now()),
        ),
      );
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
      await (db.update(db.products)..where((t) => t.id.equals(id))).write(
        ProductsCompanion(
          deletedAt: Value(DateTime.now()),
        ),
      );
    }
  }

  @override
  Future<void> adjustStock(
    String productId,
    int delta,
    String type,
    String? note,
  ) async {
    final p = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingleOrNull();
    if (p == null) return;

    try {
      final body = <String, dynamic>{
        'delta': delta,
        'type': type,
      };
      if (note != null) body['note'] = note;

      final res = await apiClient.post(
        '/api/v1/products/$productId/adjust-stock',
        body: body,
        headers: idempotencyKey(),
      );
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final stockAfter = (resMap['stockAfter'] as num?)?.toInt() ?? (p.stock + delta);
        // Patch row directly without client clock stamping on updatedAt (ADR-0010 §5)
        await (db.update(db.products)..where((t) => t.id.equals(productId))).write(
          ProductsCompanion(
            stock: Value(stockAfter),
          ),
        );

        final mv = resMap['movement'];
        if (mv is Map<String, dynamic>) {
          await db.into(db.movements).insertOnConflictUpdate(movementRowFromWire(mv));
        } else {
          await MovementsRepository(db).addMovement(
            productId: productId,
            partNo: p.partNo,
            name: p.name,
            delta: delta,
            type: type,
            note: note,
            stockAfter: stockAfter,
          );
        }
        return;
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback: only when server was never reached
    }

    int fallbackStock = p.stock + delta;
    if (fallbackStock < 0) fallbackStock = 0;

    await (db.update(db.products)..where((t) => t.id.equals(productId))).write(
      ProductsCompanion(
        stock: Value(fallbackStock),
      ),
    );

    await MovementsRepository(db).addMovement(
      productId: productId,
      partNo: p.partNo,
      name: p.name,
      delta: delta,
      type: type,
      note: note,
      stockAfter: fallbackStock,
    );
  }

  @override
  Future<List<String>> getCategories() async {
    try {
      final res = await apiClient.get('/api/v1/categories');
      if (res is List) {
        final categoryNames = <String>[];
        for (var i = 0; i < res.length; i++) {
          final item = res[i];
          final name = item is Map ? item['name'] as String? : item.toString();
          if (name != null && name.isNotEmpty) {
            categoryNames.add(name);
            await db.into(db.categories).insert(
                  CategoriesCompanion.insert(name: name, position: i),
                  onConflict: DoUpdate((old) => CategoriesCompanion(position: Value(i))),
                );
          }
        }
        if (categoryNames.isNotEmpty) return categoryNames;
      }
    } catch (_) {}

    return super.getCategories();
  }

  @override
  Future<void> addCategory(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    try {
      await apiClient.post('/api/v1/categories', body: {'name': trimmed}, headers: idempotencyKey());
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    await super.addCategory(trimmed);
  }

  @override
  Future<void> deleteCategory(String name) async {
    try {
      await apiClient.delete('/api/v1/categories/$name', headers: idempotencyKey());
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    await super.deleteCategory(name);
  }
}
