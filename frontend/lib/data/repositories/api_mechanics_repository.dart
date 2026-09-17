// ApiMechanicsRepository — write-through cache implementation of MechanicsRepository.
//
// Complies with ADR-0010:
//  • Server is the authority on mechanic credit balances and payment receipts (CP###).
//  • Patches rows directly in Drift without dual-bookkeeping locally.
//  • total_credit is struck (#11, ADR-0010 §6) — legacy alias of total_discount, never written.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'mechanics_repository.dart';

class ApiMechanicsRepository extends MechanicsRepository {
  final ApiClient apiClient;

  ApiMechanicsRepository(
    super.db,
    this.apiClient, {
    this.writesToServer = true,
  });

  /// Whether a credit payment is a server write — the `USE_API_WRITES` switch
  /// (`useApi`), the same one that moves sales, returns and shifts.
  final bool writesToServer;

  MechanicsCompanion _mechanicToCompanion(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final code = (json['code'] ?? '') as String;
    final name = (json['name'] ?? '') as String;
    final nameTH = (json['nameTH'] ?? json['name_t_h']) as String?;
    final nickname = json['nickname'] as String?;
    final shopName = (json['shopName'] ?? json['shop_name']) as String?;
    final phone = json['phone'] as String?;
    final note = json['note'] as String?;

    final creditLimit = money(json['creditLimit'] ?? json['credit_limit']);
    final creditBalance = money(json['creditBalance'] ?? json['credit_balance']);
    final totalSales = money(json['totalSales'] ?? json['total_sales']);
    final totalDiscount = money(json['totalDiscount'] ?? json['total_discount']);
    final totalMarkup = money(json['totalMarkup'] ?? json['total_markup']);
    final createdAt = (json['createdAt'] ?? json['created_at'] ?? '') as String;

    final updatedAt = stampOrNull(json['updatedAt']);
    final deletedAt = stampOrNull(json['deletedAt']);

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
      totalDiscount: Value(totalDiscount),
      totalMarkup: Value(totalMarkup),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: Value(deletedAt),
    );
  }

  Future<void> syncFromServer() async {
    try {
      String? updatedSince;
      final latestRow = await (db.select(db.mechanics)
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

        final res = await apiClient.getPaginated('/api/v1/mechanics', queryParameters: queryParams);
        final items = res.data;

        if (items.isNotEmpty) {
          await db.batch((batch) {
            for (final item in items) {
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
  Future<List<MechanicRow>> getMechanics() async {
    // Queued payments first, so the balances this read brings back include them.
    await flushPendingCreditPayments();
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
        if (data.creditLimit.present) 'creditLimit': wireMoney(data.creditLimit.value),
      };

      final res = await apiClient.post('/api/v1/mechanics', body: body, headers: idempotencyKey());
      if (res is Map) {
        final comp = _mechanicToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.mechanics).insertOnConflictUpdate(comp);
        return (db.select(db.mechanics)..where((t) => t.id.equals(comp.id.value))).getSingle();
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
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
      if (patch.creditLimit.present) body['creditLimit'] = wireMoney(patch.creditLimit.value);

      final res = await apiClient.patch('/api/v1/mechanics/$id', body: body, headers: idempotencyKey());
      if (res is Map) {
        final comp = _mechanicToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.mechanics).insertOnConflictUpdate(comp);
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

    await super.updateMechanic(id, patch);
  }

  @override
  Future<void> deleteMechanic(String id) async {
    try {
      await apiClient.delete('/api/v1/mechanics/$id', headers: idempotencyKey());
      await (db.update(db.mechanics)..where((t) => t.id.equals(id))).write(
        MechanicsCompanion(
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
      await (db.update(db.mechanics)..where((t) => t.id.equals(id))).write(
        MechanicsCompanion(
          deletedAt: Value(DateTime.now()),
        ),
      );
    }
  }

  @override
  Future<CreditPaymentRow> addCreditPayment({
    required String mechanicId,
    required double amount,
    required String paymentMethod,
    String? note,
    bool allowOverpayment = false,
  }) async {
    if (!writesToServer) {
      return super.addCreditPayment(
        mechanicId: mechanicId,
        amount: amount,
        paymentMethod: paymentMethod,
        note: note,
        allowOverpayment: allowOverpayment,
      );
    }

    if (!await hasOpenShift(db)) {
      throw const PosException('NO_OPEN_SHIFT', noOpenShiftForCreditPayment);
    }

    final mechanic = await (db.select(db.mechanics)..where((t) => t.id.equals(mechanicId))).getSingleOrNull();
    if (mechanic == null) {
      throw const PosException('NOT_FOUND', 'ไม่พบข้อมูลช่าง');
    }

    final queue = await (db.select(db.pendingCreditPayments)
          ..where((t) => t.mechanicId.equals(mechanicId) & t.rejectedCode.isNull()))
        .get();
    final queuedTotal = queue.fold<double>(
      0.0,
      (sum, row) => sum + (double.tryParse(row.amount) ?? 0.0),
    );
    final projectedBalance = mechanic.creditBalance - queuedTotal;

    if (amount > projectedBalance && !allowOverpayment) {
      throw PosException(
        'OVERPAYMENT_NOT_ALLOWED',
        'ยอดชำระเกินยอดหนี้คงเหลือ',
        {
          'creditBalance': projectedBalance,
          'amount': amount,
        },
      );
    }

    final localId = newId('cp');
    final now = DateTime.now();
    final key = newId('idem');
    final wireAmt = wireMoney(amount);

    await db.into(db.pendingCreditPayments).insert(
          PendingCreditPaymentsCompanion(
            id: Value(localId),
            idempotencyKey: Value(key),
            mechanicId: Value(mechanicId),
            amount: Value(wireAmt),
            paymentMethod: Value(paymentMethod),
            note: Value(note),
            allowOverpayment: Value(allowOverpayment),
            createdAt: Value(now),
          ),
        );

    try {
      final body = {
        'id': localId,
        'amount': wireAmt,
        'paymentMethod': paymentMethod,
        if (note != null && note.isNotEmpty) 'note': note,
        if (allowOverpayment) 'allowOverpayment': true,
      };

      final res = await apiClient.post(
        '/api/v1/mechanics/$mechanicId/credit-payments',
        body: body,
        headers: {'Idempotency-Key': key},
      );

      if (res is Map) {
        return await _applyPaymentSuccess(localId, mechanicId, wireAmt, note, res);
      }
    } on ApiException catch (e) {
      if (isVerdict(e)) {
        await (db.delete(db.pendingCreditPayments)..where((t) => t.id.equals(localId))).go();
        if (e.code == 'NO_OPEN_SHIFT') {
          throw PosException(e.code, noOpenShiftForCreditPayment, e.details);
        }
        rethrowServerRefusal(e);
      }
      throw const CreditPaymentQueued();
    } catch (_) {
      throw const CreditPaymentQueued();
    }

    throw const CreditPaymentQueued();
  }

  Future<CreditPaymentRow> _applyPaymentSuccess(
    String id,
    String mechanicId,
    String wireAmount,
    String? note,
    Map res,
  ) async {
    final resMap = Map<String, dynamic>.from(res);
    final serverId = (resMap['id'] ?? id) as String;
    final receiptNo = (resMap['receiptNo'] ?? resMap['receipt_no'] ?? '') as String;
    final paymentDate = stampOrNull(resMap['date']) ?? DateTime.now();
    final creditBalanceAfter = moneyOrNull(resMap['mechanicCreditBalanceAfter'] ?? resMap['mechanic_credit_balance_after']);

    final paymentRow = CreditPaymentRow(
      id: serverId,
      receiptNo: receiptNo,
      mechanicId: mechanicId,
      amount: money(wireAmount),
      date: paymentDate,
      note: note,
    );

    await db.transaction(() async {
      await db.into(db.creditPayments).insertOnConflictUpdate(paymentRow);
      if (creditBalanceAfter != null) {
        await (db.update(db.mechanics)..where((t) => t.id.equals(mechanicId))).write(
          MechanicsCompanion(
            creditBalance: Value(creditBalanceAfter),
          ),
        );
      }
      await (db.delete(db.pendingCreditPayments)..where((t) => t.id.equals(id))).go();
    });

    return paymentRow;
  }

  @override
  Future<void> flushPendingCreditPayments() async {
    if (!writesToServer) return;

    final pendingList = await (db.select(db.pendingCreditPayments)
          ..where((t) => t.rejectedCode.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    for (final item in pendingList) {
      try {
        final body = {
          'id': item.id,
          'amount': item.amount,
          'paymentMethod': item.paymentMethod,
          if (item.note != null && item.note!.isNotEmpty) 'note': item.note,
          if (item.allowOverpayment) 'allowOverpayment': true,
        };

        final res = await apiClient.post(
          '/api/v1/mechanics/${item.mechanicId}/credit-payments',
          body: body,
          headers: {'Idempotency-Key': item.idempotencyKey},
        );

        if (res is Map) {
          await _applyPaymentSuccess(item.id, item.mechanicId, item.amount, item.note, res);
        }
      } on ApiException catch (e) {
        if (e.statusCode == 401) {
          break;
        }
        if (isVerdict(e)) {
          await (db.update(db.pendingCreditPayments)..where((t) => t.id.equals(item.id))).write(
            PendingCreditPaymentsCompanion(
              rejectedCode: Value(e.code),
              rejectedMessage: Value(e.thaiMessage),
            ),
          );
        }
        break;
      } catch (_) {
        break;
      }
    }
  }
}
