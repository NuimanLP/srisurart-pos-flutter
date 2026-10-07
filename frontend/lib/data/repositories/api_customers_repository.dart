import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../storage/token_storage.dart' show TokenStoreUnavailableException;
import '../sync/outbox_ledger_refs.dart';
import '../sync/sync_facade.dart';
import '../sync/sync_service.dart';
import 'api/api_wire.dart';
import 'customers_repository.dart';

class ApiCustomersRepository extends CustomersRepository {
  final ApiClient apiClient;
  final SyncService? syncService;
  final SyncFacade? syncFacade;

  ApiCustomersRepository(
    super.db,
    this.apiClient, {
    this.syncService,
    this.syncFacade,
  });

  /// Adds / edits that never got a verdict — see [PendingWrites].
  final PendingWrites _pendingAdds = PendingWrites();
  final PendingWrites _pendingUpdates = PendingWrites();

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

  Future<void> syncFromServer({bool forceFull = false}) async {
    // A reset (tenant switch) while this pull is in flight voids its replies.
    final gen = db.cacheGeneration;
    try {
      String? updatedSince;
      String? afterId;

      if (!forceFull) {
        final cursorRow = await (db.select(db.syncCursors)
              ..where((t) => t.entity.equals('customers')))
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

      // Ledger guard (twin of the 08 §15 stock guard): a customer with unsent
      // money-moving work keeps its local spend/points — the server has not
      // seen it. The set and the local values are read per page inside the
      // write transaction, so an op queued mid-pull is still protected.
      bool hasMore = true;
      String? latestServerCursor;
      // updatedAt of the earliest protected row served: the saved cursor never
      // passes it, so the row is re-served once its work has been sent.
      String? protectedFloor;

      while (hasMore) {
        final queryParams = <String, dynamic>{
          'limit': 100,
          'updatedSince': updatedSince,
        };
        if (afterId != null) queryParams['afterId'] = afterId;

        final res = await apiClient.getPaginated('/api/v1/customers', queryParameters: queryParams);
        final items = res.data;

        if (items.isNotEmpty) {
          if (!await db.writeCacheIfCurrent(gen, () async {
            final guarded = (await ledgerIdsInOutbox(db)).customers;
            final companions = <CustomersCompanion>[];
            for (final item in items) {
              if (item is! Map) continue;
              var comp = _customerToCompanion(Map<String, dynamic>.from(item));
              if (guarded.contains(comp.id.value)) {
                protectedFloor = earlierStamp(protectedFloor, item['updatedAt']);
                final local = await (db.select(db.customers)
                      ..where((t) => t.id.equals(comp.id.value)))
                    .getSingleOrNull();
                if (local != null) {
                  comp = comp.copyWith(
                    points: Value(local.points),
                    totalSpend: Value(local.totalSpend),
                  );
                }
              }
              companions.add(comp);
            }
            await db.batch((batch) {
              for (final comp in companions) {
                batch.insert(
                  db.customers,
                  comp,
                  onConflict: DoUpdate((old) => comp),
                );
              }
            });
          })) {
            return;
          }
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
        await db.writeCacheIfCurrent(gen, () => db.into(db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion(
            entity: const Value('customers'),
            cursor: Value(earlierStamp(latestServerCursor, protectedFloor)),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        ));
      }
    } catch (_) {
      // Network failure or degraded mode: gracefully ignore and rely on Drift cache
    }
  }

  @override
  Future<List<CustomerRow>> getCustomers() async {
    await syncFromServer();
    return (db.select(db.customers)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.code.isNull() | t.code.like('import-tombstone%').not())))
        .get();
  }

  @override
  Future<CustomerRow> addCustomer(CustomersCompanion data) async {
    final name = data.name.present ? data.name.value : '';
    final nameTH = data.nameTH.present && data.nameTH.value.isNotEmpty
        ? data.nameTH.value
        : name;
    final phone = data.phone.present ? data.phone.value : null;
    final address = data.address.present ? data.address.value : null;
    final explicitId = data.id.present && data.id.value.isNotEmpty
        ? data.id.value
        : null;
    // The same customer pressed again while the first attempt's fate is
    // unknown (5xx, 429, lost reply) → the SAME id + Idempotency-Key, so the
    // server replays the first customer instead of creating a second (08 §5).
    final attempt = _pendingAdds.of(jsonEncode({
      'id': explicitId,
      'code': data.code.present ? data.code.value : '',
      'name': name,
      'nameTH': nameTH,
      'phone': phone,
      'address': address,
    }));
    final customerId = explicitId ?? attempt.id;
    final key = attempt.headers['Idempotency-Key']!;

    final body = {
      'id': customerId,
      'name': name,
      'nameTH': nameTH,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (address != null && address.isNotEmpty) 'address': address,
    };
    final aggregates = ['customer:$customerId'];

    Future<CustomerRow> queueOfflineCustomer() async {
      final opId = newUuid();
      final now = DateTime.now();
      final code = data.code.present ? data.code.value : '';

      final comp = CustomersCompanion(
        id: Value(customerId),
        code: Value(code),
        name: Value(name),
        nameTH: Value(nameTH),
        phone: Value(phone),
        address: Value(address),
        points: const Value(0),
        totalSpend: const Value(0.0),
        createdAt: Value(now.toUtc().toIso8601String()),
      );

      await db.transaction(() async {
        await db.into(db.customers).insertOnConflictUpdate(comp);
        await db.into(db.outboxOps).insert(
          OutboxOpsCompanion(
            opId: Value(opId),
            idempotencyKey: Value(key),
            type: const Value('customer.create'),
            payload: Value(jsonEncode(body)),
            aggregates: Value(jsonEncode(aggregates)),
            createdAt: Value(now.toUtc()),
            status: const Value('pending'),
            attempts: const Value(0),
          ),
        );
      });

      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      await sync?.refreshOutbox();
      return await (db.select(db.customers)
            ..where((t) => t.id.equals(customerId)))
          .getSingle();
    }

    if (_isDegraded) {
      final row = await queueOfflineCustomer();
      _pendingAdds.close(attempt);
      return row;
    }

    try {
      final res = await apiClient.post(
        '/api/v1/customers',
        body: body,
        headers: attempt.headers,
      );
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        // Closed only after the local apply: if it throws, the attempt stays
        // parked and the next press replays it under the same id + key.
        _pendingAdds.close(attempt);
        return await (db.select(db.customers)
              ..where((t) => t.id.equals(comp.id.value)))
            .getSingle();
      }
      // A 2xx that is not a customer: the server answered and may have
      // committed. PosException, not ApiException — an ApiException here
      // landed in the non-verdict branch below and was queued offline.
      throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
    } on ApiException catch (e) {
      if (isVerdict(e)) {
        _pendingAdds.close(attempt);
        rethrowServerRefusal(e);
      }
      // 🔴 08 §5 (owner, 2026-09-27, #452): a 5xx / 429 / 503 IN_FLIGHT is
      // not a verdict — the customer may already be committed — but it is
      // not a transport failure either, so it is never queued. Same as
      // ApiSalesRepository: the link is NOT marked Degraded (that would send
      // the next press to the outbox), the attempt stays parked (same id +
      // key), and the counter reads the converted sentence; the next press
      // re-sends online and the server replays.
      throw posExceptionFromApi(e);
    } catch (e) {
      // 🔴 #409/#413: only a TRANSPORT failure (timeout, dropped socket) may
      // become an offline write. Anything else here — a 2xx whose body is not
      // a customer, say — means the server answered and may have committed;
      // queuing it would create a second customer under a fresh offline id.
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
      // A transport failure: queued under the SAME id + key (08 §5), so if
      // the lost request had committed, the push replays it.
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      if (sync != null) {
        final row = await queueOfflineCustomer();
        _pendingAdds.close(attempt);
        return row;
      }
      rethrow;
    }
  }

  @override
  Future<void> updateCustomer(String id, CustomersCompanion patch) async {
    final body = <String, dynamic>{};
    if (patch.name.present) body['name'] = patch.name.value;
    if (patch.nameTH.present) body['nameTH'] = patch.nameTH.value;
    if (patch.phone.present) body['phone'] = patch.phone.value;
    if (patch.address.present) body['address'] = patch.address.value;

    final aggregates = ['customer:$id'];
    // Same rule as addCustomer: one Idempotency-Key per logical edit.
    final attempt = _pendingUpdates.of('$id|${jsonEncode(body)}');
    final key = attempt.headers['Idempotency-Key']!;
    // Once this edit is settled (success, verdict, or queued), every OTHER
    // edit of the same customer still parked is stale: re-sending one under
    // its old key would only replay the server's stored reply — the record as
    // it was then — without applying it. A PATCH is absolute, so a new key for
    // it is always safe.
    void closeEditsOfThisCustomer() =>
        _pendingUpdates.closeWhere((fp) => fp.startsWith('$id|'));

    Future<void> queueOfflineUpdate() async {
      final opId = newUuid();
      final now = DateTime.now();

      await db.transaction(() async {
        await (db.update(db.customers)..where((t) => t.id.equals(id))).write(patch);
        await db.into(db.outboxOps).insert(
          OutboxOpsCompanion(
            opId: Value(opId),
            idempotencyKey: Value(key),
            type: const Value('customer.update'),
            payload: Value(jsonEncode({'id': id, ...body})),
            aggregates: Value(jsonEncode(aggregates)),
            createdAt: Value(now.toUtc()),
            status: const Value('pending'),
            attempts: const Value(0),
          ),
        );
      });

      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      await sync?.refreshOutbox();
    }

    if (_isDegraded) {
      await queueOfflineUpdate();
      closeEditsOfThisCustomer();
      return;
    }

    try {
      final res = await apiClient.patch(
        '/api/v1/customers/$id',
        body: body,
        headers: attempt.headers,
      );
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        closeEditsOfThisCustomer();
        return;
      }
      // Same as addCustomer: a 2xx that is not a customer is an unknown
      // fate, never a silent success.
      throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
    } on ApiException catch (e) {
      if (isVerdict(e)) {
        closeEditsOfThisCustomer();
        rethrowServerRefusal(e);
      }
      // 08 §5: a 5xx / 429 / IN_FLIGHT is never queued, never Degraded —
      // see addCustomer.
      throw posExceptionFromApi(e);
    } catch (e) {
      // 🔴 #409/#413: only a TRANSPORT failure (timeout, dropped socket) may
      // become an offline write. Anything else here — a 2xx whose body is not
      // a customer, say — means the server answered and may have committed;
      // queuing it would apply the same patch a second time.
      if (e is PosException) rethrow;
      // 🔴 #token-store-unavailable: see addCustomer's catch above — the
      // triggering 401 already refused THIS write, so nothing was committed.
      if (e is TokenStoreUnavailableException) rethrow;
      if (!isTransportFailure(e)) {
        throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      if (sync != null) {
        await queueOfflineUpdate();
        closeEditsOfThisCustomer();
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteCustomer(String id) async {
    if (_isDegraded) {
      throw const PosException(
        'OFFLINE_ACTION_NOT_ALLOWED',
        'ไม่สามารถลบลูกค้าได้ขณะออฟไลน์',
      );
    }

    await rethrowCounterError(() => apiClient.delete('/api/v1/customers/$id', headers: idempotencyKey()));
    await (db.update(db.customers)..where((t) => t.id.equals(id))).write(
      CustomersCompanion(
        deletedAt: Value(DateTime.now()),
      ),
    );
  }
}

