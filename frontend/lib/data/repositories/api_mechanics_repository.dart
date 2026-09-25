// ApiMechanicsRepository — write-through cache implementation of MechanicsRepository.
//
// Complies with ADR-0010:
//  • Server is the authority on mechanic credit balances and payment receipts (CP###).
//  • Patches rows directly in Drift without dual-bookkeeping locally.
//  • total_credit is struck (#11, ADR-0010 §6) — legacy alias of total_discount, never written.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../storage/token_storage.dart' show TokenStoreUnavailableException;
import '../sync/sync_facade.dart';
import '../sync/sync_service.dart';
import 'api/api_wire.dart';
import 'mechanics_repository.dart';

class ApiMechanicsRepository extends MechanicsRepository {
  final ApiClient apiClient;
  final SyncService? syncService;
  final SyncFacade? syncFacade;

  ApiMechanicsRepository(
    super.db,
    this.apiClient, {
    this.writesToServer = true,
    this.syncService,
    this.syncFacade,
  });

  /// Whether a credit payment is a server write — the `USE_API_WRITES` switch
  /// (`useApi`), the same one that moves sales, returns and shifts.
  final bool writesToServer;

  bool get _isDegraded {
    final sync = syncService ??
        (syncFacade is SyncService ? syncFacade as SyncService : null);
    if (sync != null) {
      return sync.currentStatus == SyncStatus.degraded ||
          sync.currentStatus == SyncStatus.syncing ||
          sync.currentOutboxRemaining > 0;
    }
    if (syncFacade != null) {
      try {
        final dynamic facade = syncFacade;
        final status = facade.currentStatus;
        if (status == SyncStatus.degraded || status == SyncStatus.syncing) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

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

  Future<void> syncFromServer({bool forceFull = false}) async {
    try {
      String? updatedSince;
      String? afterId;

      if (!forceFull) {
        final cursorRow = await (db.select(db.syncCursors)
              ..where((t) => t.entity.equals('mechanics')))
            .getSingleOrNull();

        if (cursorRow?.cursor != null && cursorRow!.cursor!.isNotEmpty) {
          final dt = DateTime.parse(cursorRow.cursor!).toUtc();
          // 08 §15: หน้าแรกของรอบ: updatedSince = cursor − 30 วินาที และไม่ส่ง afterId
          updatedSince = dt.subtract(const Duration(seconds: 30)).toIso8601String();
          afterId = null;
        } else {
          updatedSince = '1970-01-01T00:00:00.000Z';
          afterId = null;
        }
      } else {
        updatedSince = '1970-01-01T00:00:00.000Z';
        afterId = null;
      }

      bool hasMore = true;
      String? latestServerCursor;

      while (hasMore) {
        final queryParams = <String, dynamic>{
          'limit': 100,
          'updatedSince': updatedSince,
        };
        if (afterId != null) queryParams['afterId'] = afterId;

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

        if (items.isEmpty) {
          hasMore = false;
        } else {
          final next = res.nextCursor;
          if (next != null && next['updatedSince'] != null) {
            latestServerCursor = next['updatedSince'] as String;
            updatedSince = latestServerCursor;
            afterId = next['afterId'] as String?;
          } else {
            hasMore = false;
          }
        }
      }

      if (latestServerCursor != null) {
        await db.into(db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion(
            entity: const Value('mechanics'),
            cursor: Value(latestServerCursor),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
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
    return (db.select(db.mechanics)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.code.isNull() | t.code.like('import-tombstone%').not())))
        .get();
  }

  @override
  Future<MechanicRow> addMechanic(MechanicsCompanion data) async {
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
      return await (db.select(db.mechanics)..where((t) => t.id.equals(comp.id.value))).getSingle();
    }
    throw ApiException(
      statusCode: 500,
      code: 'SERVER_ERROR',
      serverMessage: 'ไม่สามารถบันทึกข้อมูลช่าง',
    );
  }

  @override
  Future<void> updateMechanic(String id, MechanicsCompanion patch) async {
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
  }

  @override
  Future<void> deleteMechanic(String id) async {
    await apiClient.delete('/api/v1/mechanics/$id', headers: idempotencyKey());
    await (db.update(db.mechanics)..where((t) => t.id.equals(id))).write(
      MechanicsCompanion(
        deletedAt: Value(DateTime.now()),
      ),
    );
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

    await migratePendingCreditPayments(db);

    final pendingOps = await (db.select(db.outboxOps)
          ..where((t) =>
              t.type.equals('credit_payment.create') &
              t.status.isNotValue('rejected')))
        .get();
    double queuedTotal = 0.0;
    for (final op in pendingOps) {
      try {
        final payload = jsonDecode(op.payload);
        if (payload is Map<String, dynamic> &&
            payload['mechanicId'] == mechanicId) {
          queuedTotal +=
              double.tryParse(payload['amount']?.toString() ?? '') ?? 0.0;
        }
      } catch (_) {}
    }
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
    final opId = newId('op');
    final wireAmt = wireMoney(amount);

    final activeShift = await (db.select(db.shifts)
          ..where((t) => t.isActive.equals(true) & t.closedAt.isNull())
          ..limit(1))
        .getSingleOrNull();

    final body = {
      'id': localId,
      'mechanicId': mechanicId,
      'amount': wireAmt,
      'paymentMethod': paymentMethod,
      if (note != null && note.isNotEmpty) 'note': note,
      if (allowOverpayment) 'allowOverpayment': true,
      'date': now.toUtc().toIso8601String(),
    };

    final aggregates = [
      'cp:$localId',
      if (activeShift != null) 'shift:${activeShift.id}' else 'shift',
      'mechanic:$mechanicId',
    ];

    Future<void> queueToOutbox() async {
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion(
              opId: Value(opId),
              idempotencyKey: Value(key),
              type: const Value('credit_payment.create'),
              payload: Value(jsonEncode(body)),
              aggregates: Value(jsonEncode(aggregates)),
              createdAt: Value(now),
              status: const Value('pending'),
              attempts: const Value(0),
            ),
          );
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      await sync?.refreshOutbox();
    }

    if (_isDegraded) {
      await queueToOutbox();
      throw const CreditPaymentQueued();
    }

    try {
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
        if (e.code == 'NO_OPEN_SHIFT') {
          throw PosException(e.code, noOpenShiftForCreditPayment, e.details);
        }
        rethrowServerRefusal(e);
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      await queueToOutbox();
      throw const CreditPaymentQueued();
    } catch (e) {
      // 🔴 #409/#413: only a TRANSPORT failure (timeout, dropped socket) may
      // become an offline write. Anything else here — a 2xx whose body is not
      // a payment, say — means the server answered and may have committed;
      // queuing it would create a second credit-payment receipt.
      if (e is PosException) rethrow;
      // 🔴 #token-store-unavailable: the web token store could not be opened on
      // the 401→refresh path (`ApiClient._executeRefresh` reads the refresh
      // token before sending anything, so this throws before any refresh
      // request goes out). The triggering 401 already refused THIS write, so
      // nothing was committed — never queue offline, never mark
      // UNREADABLE_RESPONSE. Rethrow as-is so the screen shows its own Thai
      // sentence.
      if (e is TokenStoreUnavailableException) rethrow;
      if (!isTransportFailure(e)) {
        throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      await queueToOutbox();
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
    final creditBalanceAfter = moneyOrNull(resMap['mechanicCreditBalanceAfter'] ??
        resMap['mechanic_credit_balance_after'] ??
        resMap['balanceAfter']);

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
      final ops = await (db.select(db.outboxOps)
            ..where((t) => t.type.equals('credit_payment.create')))
          .get();
      for (final op in ops) {
        try {
          final p = jsonDecode(op.payload);
          if (op.opId == id || (p is Map && p['id'] == id)) {
            await (db.delete(db.outboxOps)..where((t) => t.opId.equals(op.opId))).go();
          }
        } catch (_) {}
      }
      await (db.delete(db.pendingCreditPayments)..where((t) => t.id.equals(id))).go();
    });

    final sync = syncService ??
        (syncFacade is SyncService ? syncFacade as SyncService : null);
    await sync?.refreshOutbox();

    return paymentRow;
  }

  @override
  Future<void> flushPendingCreditPayments() async {
    if (!writesToServer) return;

    await migratePendingCreditPayments(db);

    final sync = syncService ??
        (syncFacade is SyncService ? syncFacade as SyncService : null);
    if (sync != null) {
      await sync.push();
      return;
    }

    final pendingOps = await (db.select(db.outboxOps)
          ..where((t) =>
              t.type.equals('credit_payment.create') &
              t.status.equals('pending'))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    for (final op in pendingOps) {
      try {
        final payload = jsonDecode(op.payload) as Map<String, dynamic>;
        final mechanicId = payload['mechanicId'] as String;

        final res = await apiClient.post(
          '/api/v1/mechanics/$mechanicId/credit-payments',
          body: payload,
          headers: {'Idempotency-Key': op.idempotencyKey},
        );

        if (res is Map) {
          await _applyPaymentSuccess(
            payload['id'] as String? ?? op.opId,
            mechanicId,
            payload['amount'].toString(),
            payload['note'] as String?,
            res,
          );
        }
      } on ApiException catch (e) {
        if (e.statusCode == 401) {
          break;
        }
        if (isVerdict(e)) {
          await (db.update(db.outboxOps)..where((t) => t.opId.equals(op.opId)))
              .write(
            OutboxOpsCompanion(
              status: const Value('rejected'),
              attempts: const Value(0),
              lastCode: Value(e.code),
              lastMessage: Value(e.thaiMessage),
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
