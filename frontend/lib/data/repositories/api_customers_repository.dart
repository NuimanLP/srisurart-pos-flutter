// ApiCustomersRepository — write-through cache implementation of CustomersRepository.
//
// Complies with ADR-0010:
//  • Server is the authority on customer codes (CUS###) and balances.
//  • Writes results through to Drift immediately.
//  • Supports offline read fallback from Drift cache.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'customers_repository.dart';

class ApiCustomersRepository extends CustomersRepository {
  final ApiClient apiClient;

  ApiCustomersRepository(super.db, this.apiClient);

  CustomersCompanion _customerToCompanion(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final code = (json['code'] ?? '') as String;
    final name = (json['name'] ?? '') as String;
    final nameTH = (json['nameTH'] ?? json['name_t_h'] ?? json['nameTh'] ?? '') as String;
    final phone = json['phone'] as String?;
    final address = json['address'] as String?;
    final points = (json['points'] as num?)?.toInt() ?? 0;
    final totalSpend = money(json['totalSpend']);
    final createdAt = (json['createdAt'] ?? json['created_at'] ?? '') as String;

    final updatedAt = stampOrNull(json['updatedAt']);
    final deletedAt = stampOrNull(json['deletedAt']);

    return CustomersCompanion(
      id: Value(id),
      code: Value(code),
      name: Value(name),
      nameTH: Value(nameTH),
      phone: Value(phone),
      address: Value(address),
      points: Value(points),
      totalSpend: Value(totalSpend),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: Value(deletedAt),
    );
  }

  Future<void> syncFromServer() async {
    try {
      String? updatedSince;
      final latestRow = await (db.select(db.customers)
            ..where((t) => t.updatedAt.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

      if (latestRow?.updatedAt != null) {
        updatedSince = latestRow!.updatedAt!.toUtc().toIso8601String();
      }

      bool hasMore = true;
      int page = 1;

      while (hasMore) {
        final queryParams = <String, dynamic>{
          'limit': 100,
          'page': page,
        };
        if (updatedSince != null) {
          queryParams['updatedSince'] = updatedSince;
        }

        final res = await apiClient.getPaginated('/api/v1/customers', queryParameters: queryParams);
        final items = res.data;

        if (items.isNotEmpty) {
          await db.batch((batch) {
            for (final item in items) {
              if (item is Map) {
                final comp = _customerToCompanion(Map<String, dynamic>.from(item));
                batch.insert(
                  db.customers,
                  comp,
                  onConflict: DoUpdate((old) => comp),
                );
              }
            }
          });
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
  Future<List<CustomerRow>> getCustomers() async {
    await syncFromServer();
    return (db.select(db.customers)..where((t) => t.deletedAt.isNull())).get();
  }

  @override
  Future<CustomerRow> addCustomer(CustomersCompanion data) async {
    try {
      final body = {
        'name': data.name.present ? data.name.value : '',
        'nameTH': data.nameTH.present ? data.nameTH.value : '',
        if (data.phone.present && data.phone.value != null) 'phone': data.phone.value,
        if (data.address.present && data.address.value != null) 'address': data.address.value,
      };

      final res = await apiClient.post('/api/v1/customers', body: body, headers: idempotencyKey());
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        return (db.select(db.customers)..where((t) => t.id.equals(comp.id.value))).getSingle();
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    return super.addCustomer(data);
  }

  @override
  Future<void> updateCustomer(String id, CustomersCompanion patch) async {
    try {
      final body = <String, dynamic>{};
      if (patch.name.present) body['name'] = patch.name.value;
      if (patch.nameTH.present) body['nameTH'] = patch.nameTH.value;
      if (patch.phone.present) body['phone'] = patch.phone.value;
      if (patch.address.present) body['address'] = patch.address.value;

      final res = await apiClient.patch('/api/v1/customers/$id', body: body, headers: idempotencyKey());
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        return;
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    await super.updateCustomer(id, patch);
  }

  @override
  Future<void> deleteCustomer(String id) async {
    try {
      await apiClient.delete('/api/v1/customers/$id', headers: idempotencyKey());
      await (db.update(db.customers)..where((t) => t.id.equals(id))).write(
        CustomersCompanion(
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
      await (db.update(db.customers)..where((t) => t.id.equals(id))).write(
        CustomersCompanion(
          deletedAt: Value(DateTime.now()),
        ),
      );
    }
  }
}
