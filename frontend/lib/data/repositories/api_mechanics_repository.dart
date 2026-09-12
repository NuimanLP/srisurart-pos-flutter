// ApiMechanicsRepository — write-through cache implementation of MechanicsRepository.
//
// Complies with ADR-0010:
//  • Server is the authority on mechanic credit balances and payment receipts (CP###).
//  • Patches rows directly in Drift without dual-bookkeeping locally.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import 'mechanics_repository.dart';

class ApiMechanicsRepository extends MechanicsRepository {
  final ApiClient apiClient;

  ApiMechanicsRepository(super.db, this.apiClient);

  MechanicsCompanion _mechanicToCompanion(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final code = (json['code'] ?? '') as String;
    final name = (json['name'] ?? '') as String;
    final nameTH = (json['nameTH'] ?? json['name_t_h']) as String?;
    final nickname = json['nickname'] as String?;
    final shopName = (json['shopName'] ?? json['shop_name']) as String?;
    final phone = json['phone'] as String?;
    final note = json['note'] as String?;

    double parseNum(dynamic val) {
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    final creditLimit = parseNum(json['creditLimit'] ?? json['credit_limit']);
    final creditBalance = parseNum(json['creditBalance'] ?? json['credit_balance']);
    final totalSales = parseNum(json['totalSales'] ?? json['total_sales']);
    final totalCredit = parseNum(json['totalCredit'] ?? json['total_credit']);
    final totalDiscount = parseNum(json['totalDiscount'] ?? json['total_discount']);
    final totalMarkup = parseNum(json['totalMarkup'] ?? json['total_markup']);
    final createdAt = (json['createdAt'] ?? json['created_at'] ?? '') as String;

    DateTime? updatedAt;
    if (json['updatedAt'] != null) {
      updatedAt = DateTime.tryParse(json['updatedAt'].toString());
    }
    DateTime? deletedAt;
    if (json['deletedAt'] != null) {
      deletedAt = DateTime.tryParse(json['deletedAt'].toString());
    }

    return MechanicsCompanion(
      id: Value(id),
      code: Value(code),
      name: Value(name),
      nameTH: Value(nameTH),
      nickname: Value(nickname),
      shopName: Value(shopName),
      phone: Value(phone),
      note: Value(note),
      creditLimit: Value(creditLimit),
      creditBalance: Value(creditBalance),
      totalSales: Value(totalSales),
      totalCredit: Value(totalCredit),
      totalDiscount: Value(totalDiscount),
      totalMarkup: Value(totalMarkup),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: Value(deletedAt),
    );
  }

  Future<void> syncFromServer() async {
    try {
      final res = await apiClient.get('/api/v1/mechanics');
      if (res is List) {
        await db.batch((batch) {
          for (final item in res) {
            if (item is Map) {
              final comp = _mechanicToCompanion(Map<String, dynamic>.from(item));
              batch.insert(
                db.mechanics,
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
  Future<List<MechanicRow>> getMechanics() async {
    await syncFromServer();
    return (db.select(db.mechanics)..where((t) => t.deletedAt.isNull())).get();
  }

  @override
  Future<MechanicRow> addMechanic(MechanicsCompanion data) async {
    try {
      final body = {
        'name': data.name.present ? data.name.value : '',
        if (data.nameTH.present && data.nameTH.value != null) 'nameTH': data.nameTH.value,
        if (data.nickname.present && data.nickname.value != null) 'nickname': data.nickname.value,
        if (data.shopName.present && data.shopName.value != null) 'shopName': data.shopName.value,
        if (data.phone.present && data.phone.value != null) 'phone': data.phone.value,
        if (data.note.present && data.note.value != null) 'note': data.note.value,
        if (data.creditLimit.present) 'creditLimit': data.creditLimit.value.toStringAsFixed(2),
      };

      final res = await apiClient.post('/api/v1/mechanics', body: body);
      if (res is Map) {
        final comp = _mechanicToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.mechanics).insertOnConflictUpdate(comp);
        return (db.select(db.mechanics)..where((t) => t.id.equals(comp.id.value))).getSingle();
      }
    } catch (_) {
      // Offline fallback
    }

    return super.addMechanic(data);
  }

  @override
  Future<void> updateMechanic(String id, MechanicsCompanion patch) async {
    try {
      final body = <String, dynamic>{};
      if (patch.name.present) body['name'] = patch.name.value;
      if (patch.nameTH.present) body['nameTH'] = patch.nameTH.value;
      if (patch.nickname.present) body['nickname'] = patch.nickname.value;
      if (patch.shopName.present) body['shopName'] = patch.shopName.value;
      if (patch.phone.present) body['phone'] = patch.phone.value;
      if (patch.note.present) body['note'] = patch.note.value;
      if (patch.creditLimit.present) body['creditLimit'] = patch.creditLimit.value.toStringAsFixed(2);

      final res = await apiClient.patch('/api/v1/mechanics/$id', body: body);
      if (res is Map) {
        final comp = _mechanicToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.mechanics).insertOnConflictUpdate(comp);
        return;
      }
    } catch (_) {}

    await super.updateMechanic(id, patch);
  }

  @override
  Future<void> deleteMechanic(String id) async {
    try {
      await apiClient.delete('/api/v1/mechanics/$id');
    } catch (_) {}

    await (db.update(db.mechanics)..where((t) => t.id.equals(id))).write(
      MechanicsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<CreditPaymentRow> addCreditPayment({
    required String mechanicId,
    required double amount,
    String? note,
  }) async {
    try {
      final body = <String, dynamic>{
        'amount': amount.toStringAsFixed(2),
      };
      if (note != null) body['note'] = note;

      final res = await apiClient.post(
        '/api/v1/mechanics/$mechanicId/credit-payments',
        body: body,
      );

      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final paymentData = (resMap['payment'] is Map
            ? Map<String, dynamic>.from(resMap['payment'] as Map)
            : resMap);
        final id = (paymentData['id'] ?? newId('cp')) as String;
        final receiptNo = (paymentData['receiptNo'] ?? docNo('CP')) as String;
        final dateStr = paymentData['date'] as String?;
        final date = dateStr != null ? DateTime.tryParse(dateStr) ?? DateTime.now() : DateTime.now();

        final row = CreditPaymentRow(
          id: id,
          receiptNo: receiptNo,
          mechanicId: mechanicId,
          amount: amount,
          date: date,
          note: note,
        );
        await db.into(db.creditPayments).insertOnConflictUpdate(row);

        // Update mechanic's balance directly from server response
        if (resMap['mechanicCreditBalanceAfter'] != null) {
          final balanceAfter = (resMap['mechanicCreditBalanceAfter'] as num).toDouble();
          await (db.update(db.mechanics)..where((t) => t.id.equals(mechanicId))).write(
            MechanicsCompanion(
              creditBalance: Value(balanceAfter),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }

        return row;
      }
    } catch (_) {
      // Offline fallback
    }

    return super.addCreditPayment(mechanicId: mechanicId, amount: amount, note: note);
  }
}
