import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
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

      bool hasMore = true;
      String? latestServerCursor;

      while (hasMore) {
        final queryParams = <String, dynamic>{
          'limit': 100,
          'updatedSince': updatedSince,
        };
        if (afterId != null) queryParams['afterId'] = afterId;

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
            entity: const Value('customers'),
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
    final customerId = data.id.present && data.id.value.isNotEmpty
        ? data.id.value
        : newId('c');
    final name = data.name.present ? data.name.value : '';
    final nameTH = data.nameTH.present && data.nameTH.value.isNotEmpty
        ? data.nameTH.value
        : name;
    final phone = data.phone.present ? data.phone.value : null;
    final address = data.address.present ? data.address.value : null;

    final body = {
      'id': customerId,
      'name': name,
      'nameTH': nameTH,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (address != null && address.isNotEmpty) 'address': address,
    };
    final aggregates = ['customer:$customerId'];

    Future<CustomerRow> queueOfflineCustomer() async {
      final opId = newId('op');
      final key = newId('idem');
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
      return await queueOfflineCustomer();
    }

    final key = newId('idem');
    try {
      final res = await apiClient.post(
        '/api/v1/customers',
        body: body,
        headers: {'Idempotency-Key': key},
      );
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
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
        rethrowServerRefusal(e);
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      if (sync != null) {
        return await queueOfflineCustomer();
      }
      rethrow;
    } catch (e) {
      // 🔴 #409/#413: only a TRANSPORT failure (timeout, dropped socket) may
      // become an offline write. Anything else here — a 2xx whose body is not
      // a customer, say — means the server answered and may have committed;
      // queuing it would create a second customer under a fresh offline id.
      if (e is PosException) rethrow;
      if (!isTransportFailure(e)) {
        throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      if (sync != null) {
        return await queueOfflineCustomer();
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

    Future<void> queueOfflineUpdate() async {
      final opId = newId('op');
      final key = newId('idem');
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
      return;
    }

    final key = newId('idem');
    try {
      final res = await apiClient.patch(
        '/api/v1/customers/$id',
        body: body,
        headers: {'Idempotency-Key': key},
      );
      if (res is Map) {
        final comp = _customerToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.customers).insertOnConflictUpdate(comp);
        return;
      }
      // Same as addCustomer: a 2xx that is not a customer is an unknown
      // fate, never a silent success.
      throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
    } on ApiException catch (e) {
      if (isVerdict(e)) {
        rethrowServerRefusal(e);
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      if (sync != null) {
        await queueOfflineUpdate();
        return;
      }
      rethrow;
    } catch (e) {
      // 🔴 #409/#413: only a TRANSPORT failure (timeout, dropped socket) may
      // become an offline write. Anything else here — a 2xx whose body is not
      // a customer, say — means the server answered and may have committed;
      // queuing it would apply the same patch a second time.
      if (e is PosException) rethrow;
      if (!isTransportFailure(e)) {
        throw PosException('UNREADABLE_RESPONSE', ServerErrorResolver.resolve(null));
      }
      final sync = syncService ??
          (syncFacade is SyncService ? syncFacade as SyncService : null);
      sync?.recordNonVerdictWrite();
      if (sync != null) {
        await queueOfflineUpdate();
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

    await apiClient.delete('/api/v1/customers/$id', headers: idempotencyKey());
    await (db.update(db.customers)..where((t) => t.id.equals(id))).write(
      CustomersCompanion(
        deletedAt: Value(DateTime.now()),
      ),
    );
  }
}

