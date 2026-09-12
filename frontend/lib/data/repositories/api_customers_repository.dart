// ApiCustomersRepository — write-through cache implementation of CustomersRepository.
//
// Complies with ADR-0010:
//  • Server is the authority on customer codes (CUS###) and balances.
//  • Writes results through to Drift immediately.
//  • Supports offline read fallback from Drift cache.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../db/database.dart';
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
    final totalSpend = json['totalSpend'] is num
        ? (json['totalSpend'] as num).toDouble()
        : double.tryParse('${json['totalSpend']}') ?? 0.0;
    final createdAt = (json['createdAt'] ?? json['created_at'] ?? '') as String;

    DateTime? updatedAt;
    if (json['updatedAt'] != null) {
      updatedAt = DateTime.tryParse(json['updatedAt'].toString());
    }
    DateTime? deletedAt;
    if (json['deletedAt'] != null) {
      deletedAt = DateTime.tryParse(json['deletedAt'].toString());
    }

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
      final res = await apiClient.get('/api/v1/customers');
      if (res is List) {
        await db.batch((batch) {
          for (final item in res) {
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
    } catch (_) {}
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

      final res = await apiClient.post('/api/v1/customers', body: body);
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        return (db.select(db.customers)..where((t) => t.id.equals(comp.id.value))).getSingle();
      }
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

      final res = await apiClient.patch('/api/v1/customers/$id', body: body);
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        return;
      }
    } catch (_) {}

    await super.updateCustomer(id, patch);
  }

  @override
  Future<void> deleteCustomer(String id) async {
    try {
      await apiClient.delete('/api/v1/customers/$id');
    } catch (_) {}

    await (db.update(db.customers)..where((t) => t.id.equals(id))).write(
      CustomersCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
