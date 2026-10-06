// SyncService — Phase 2 offline shell & background synchronization engine.
// Implements SyncFacade contract (docs/Backend_design/09_PHASE2_LANES.md §4.2, 08_PHASE2_SPEC.md §5, §7, §8.4).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../repositories/return_plan.dart' show refundedQtyOf;
import '../services/doc_number_service.dart';
import '../storage/token_storage.dart';
import 'applied_effects.dart';
import 'outbox_ledger_refs.dart';
import 'sale_push_patch.dart';
import 'sync_facade.dart';

class SyncService implements SyncFacade {
  SyncService({
    required this.db,
    required this.apiClient,
    required this.tokenStorage,
    this.onPull,
    this.docNumberService,
    http.Client? httpClient,
    this.healthInterval = const Duration(seconds: 5),
    this.healthTimeout = const Duration(seconds: 5),
    bool autoStartHealthProbe = true,
  }) : _httpClient = httpClient ?? http.Client() {
    _init();
    if (autoStartHealthProbe) {
      _healthTimer = Timer.periodic(healthInterval, (_) => checkHealth());
    }
  }

  final AppDatabase db;
  final ApiClient apiClient;
  final TokenStorage tokenStorage;
  final Future<void> Function()? onPull;

  /// Files the server's RC/CN number from an applied push into the local
  /// counter (#489). Null → not recorded (tests that don't number anything).
  final DocNumberService? docNumberService;
  final http.Client _httpClient;
  final Duration healthInterval;
  final Duration healthTimeout;

  Timer? _healthTimer;
  StreamSubscription<List<OutboxOpRow>>? _outboxSubscription;
  bool _isDisposed = false;
  Completer<void>? _activePushCompleter;

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _needsOwnerController = StreamController<List<OutboxOpView>>.broadcast();
  final _outboxRemainingController = StreamController<int>.broadcast();

  SyncStatus _currentStatus = SyncStatus.online;
  List<OutboxOpView> _currentNeedsOwner = const [];
  int _currentOutboxRemaining = 0;

  int _consecutiveHealthFailures = 0;
  bool _isPushing = false;
  bool _pushRequested = false;

  @override
  SyncStatus get currentStatus => _currentStatus;
  List<OutboxOpView> get currentNeedsOwner => _currentNeedsOwner;
  int get currentOutboxRemaining => _currentOutboxRemaining;

  void _init() {
    _outboxSubscription = (db.select(db.outboxOps)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .listen(
      (ops) {
        if (!_isDisposed) {
          _updateOutboxStreams(ops);
        }
      },
      onError: (_) {},
    );
  }

  Future<void> _refreshOutbox() async {
    if (_isDisposed) return;
    try {
      final ops = await (db.select(db.outboxOps)
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();
      if (_isDisposed) return;
      _updateOutboxStreams(ops);
    } catch (_) {}
  }

  /// Refreshes outbox streams. Called when external atomic transactions write to outbox_ops.
  Future<void> refreshOutbox() => _refreshOutbox();

  void _updateOutboxStreams(List<OutboxOpRow> ops) {
    if (_isDisposed) return;
    _currentOutboxRemaining = ops.length;
    if (!_outboxRemainingController.isClosed) {
      _outboxRemainingController.add(_currentOutboxRemaining);
    }

    _currentNeedsOwner = ops
        .where((op) => op.status == 'stuck' || op.status == 'rejected')
        .map(_toOutboxOpView)
        .toList(growable: false);
    if (!_needsOwnerController.isClosed) {
      _needsOwnerController.add(_currentNeedsOwner);
    }
  }


  OutboxOpView _toOutboxOpView(OutboxOpRow row) {
    Map<String, dynamic> payload = {};
    try {
      final decoded = jsonDecode(row.payload);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    } catch (_) {}

    Map<String, dynamic>? lastDetails;
    if (row.lastDetails != null) {
      try {
        final decoded = jsonDecode(row.lastDetails!);
        if (decoded is Map<String, dynamic>) {
          lastDetails = decoded;
        }
      } catch (_) {}
    }

    OutboxOpStatus status;
    switch (row.status) {
      case 'stuck':
        status = OutboxOpStatus.stuck;
        break;
      case 'rejected':
        status = OutboxOpStatus.rejected;
        break;
      default:
        status = OutboxOpStatus.pending;
    }

    String? lastMessage = row.lastMessage;
    if (lastMessage == null && row.lastCode != null) {
      lastMessage = ServerErrorResolver.resolve(row.lastCode!);
    }

    final docNo = payload['receiptNo'] as String? ?? payload['cnNo'] as String?;

    return OutboxOpView(
      opId: row.opId,
      type: row.type,
      status: status,
      attempts: row.attempts,
      lastCode: row.lastCode,
      lastMessage: lastMessage,
      lastDetails: lastDetails,
      payload: payload,
      docNo: docNo,
      createdAt: row.createdAt,
    );
  }

  late final Stream<SyncStatus> _statusStream =
      Stream<SyncStatus>.multi((controller) {
    controller.add(_currentStatus);
    final sub = _statusController.stream.listen(
      (val) {
        if (!controller.isClosed) {
          controller.add(val);
        }
      },
      onError: (err, st) {
        if (!controller.isClosed) controller.addError(err, st);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );
    controller.onCancel = sub.cancel;
  });

  late final Stream<List<OutboxOpView>> _needsOwnerStream =
      Stream<List<OutboxOpView>>.multi((controller) {
    controller.add(_currentNeedsOwner);
    final sub = _needsOwnerController.stream.listen(
      (val) {
        if (!controller.isClosed) {
          controller.add(val);
        }
      },
      onError: (err, st) {
        if (!controller.isClosed) controller.addError(err, st);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );
    controller.onCancel = sub.cancel;
  });

  late final Stream<int> _outboxRemainingStream =
      Stream<int>.multi((controller) {
    controller.add(_currentOutboxRemaining);
    final sub = _outboxRemainingController.stream.listen(
      (val) {
        if (!controller.isClosed) {
          controller.add(val);
        }
      },
      onError: (err, st) {
        if (!controller.isClosed) controller.addError(err, st);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );
    controller.onCancel = sub.cancel;
  });

  @override
  Stream<SyncStatus> get status => _statusStream;

  @override
  Stream<List<OutboxOpView>> get needsOwner => _needsOwnerStream;

  @override
  Stream<int> get outboxRemaining => _outboxRemainingStream;

  void _setStatus(SyncStatus newStatus) {
    if (_isDisposed) return;
    if (_currentStatus == newStatus) return;
    _currentStatus = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(_currentStatus);
    }
  }

  // ── State Machine Triggers (§5) ───────────────────────────────────────────

  /// Triggered on network timeout, socket drop, 5xx, 429, or 503 during a write.
  void recordNonVerdictWrite() {
    _setStatus(SyncStatus.degraded);
  }

  /// Triggered on a server verdict (e.g. 409 conflict, 400 bad request).
  /// 4xx is a verdict and does NOT transition to Degraded.
  void recordVerdictWrite() {
    // Intentionally does nothing: 4xx is a final verdict.
  }

  /// Probes `GET /health/ready` to evaluate connectivity and latency.
  Future<void> checkHealth() async {
    if (_isDisposed) return;
    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse('${apiClient.baseUrl}/health/ready');
      final response = await _httpClient.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(healthTimeout);
      stopwatch.stop();

      if (_isDisposed) return;

      final elapsed = stopwatch.elapsed;
      if (elapsed >= const Duration(seconds: 5)) {
        _handleHealthSlow();
      } else if (response.statusCode >= 200 && response.statusCode < 300) {
        _handleHealthSuccess();
      } else {
        _handleHealthFailure();
      }
    } catch (_) {
      stopwatch.stop();
      if (_isDisposed) return;
      if (stopwatch.elapsed >= const Duration(seconds: 5)) {
        _handleHealthSlow();
      } else {
        _handleHealthFailure();
      }
    }
  }

  void _handleHealthSuccess() {
    _consecutiveHealthFailures = 0;
    if (_currentStatus == SyncStatus.degraded) {
      _setStatus(SyncStatus.syncing);
      unawaited(push());
    }
  }

  void _handleHealthSlow() {
    // Spec §5: response time > 5 seconds once triggers Degraded immediately.
    _setStatus(SyncStatus.degraded);
  }

  void _handleHealthFailure() {
    // Spec §5: 3 consecutive health probe failures trigger Degraded.
    _consecutiveHealthFailures++;
    if (_consecutiveHealthFailures >= 3) {
      _setStatus(SyncStatus.degraded);
    }
  }

  // ── Push Loop & Head-of-Line Blocking (§8.4) ──────────────────────────────

  /// Single-flight push loop sending pending operations up to 50 at a time.
  Future<void> push() async {
    if (_isDisposed) return;
    if (_isPushing) {
      _pushRequested = true;
      return _activePushCompleter?.future;
    }
    _isPushing = true;
    final completer = Completer<void>();
    _activePushCompleter = completer;

    try {
      while (!_isDisposed) {
        _pushRequested = false;

        final allOps = await (db.select(db.outboxOps)
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

        if (_isDisposed) break;

        final sendable = findSendableOps(allOps);
        if (sendable.isEmpty) {
          if (_currentStatus == SyncStatus.syncing) {
            _setStatus(SyncStatus.online);
          }
          break;
        }

        final batchOps = sendable.take(50).toList();
        final remainingAfterBatch = max(0, allOps.length - batchOps.length);

        final deviceToken = await tokenStorage.getDeviceToken();
        if (_isDisposed) break;

        final body = {
          'outboxRemaining': remainingAfterBatch,
          'ops': [
            for (final op in batchOps)
              {
                'opId': op.opId,
                'idempotencyKey': op.idempotencyKey,
                'type': op.type,
                'payload': jsonDecode(op.payload),
              }
          ],
        };

        final headers = <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (deviceToken != null && deviceToken.isNotEmpty)
            'X-Device-Token': deviceToken,
        };

        final uri = Uri.parse('${apiClient.baseUrl}/api/v1/sync/push');
        http.Response response;
        try {
          response = await _httpClient.post(
            uri,
            headers: headers,
            body: jsonEncode(body),
          );
        } catch (_) {
          recordNonVerdictWrite();
          await _handleHeadFailure(batchOps.first);
          _pushRequested = false;
          break;
        }

        if (_isDisposed) break;

        if (response.statusCode >= 500 ||
            response.statusCode == 429 ||
            response.statusCode == 503) {
          recordNonVerdictWrite();
          await _handleHeadFailure(batchOps.first);
          _pushRequested = false;
          break;
        }

        if (response.statusCode >= 400 && response.statusCode < 500) {
          // Spec §8.1: Request-level 4xx (e.g. 403) does not alter op statuses.
          _pushRequested = false;
          break;
        }

        Map<String, dynamic> decoded;
        try {
          decoded = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          recordNonVerdictWrite();
          await _handleHeadFailure(batchOps.first);
          _pushRequested = false;
          break;
        }

        final data = decoded['data'] as Map<String, dynamic>?;
        final results = (data?['results'] as List?) ??
            (decoded['results'] as List?) ??
            const [];

        bool stoppedAtRetry = false;
        for (final r in results) {
          if (_isDisposed) break;
          if (r is! Map) continue;
          final opId = r['opId'] as String?;
          final status = r['status'] as String?;
          if (opId == null || status == null) continue;

          if (status == 'applied') {
            final resp = r['response'] as Map<String, dynamic>?;
            final currentAll = await (db.select(db.outboxOps)).get();
            final remainingOps =
                currentAll.where((o) => o.opId != opId).toList();
            final appliedOp =
                batchOps.where((o) => o.opId == opId).firstOrNull;
            await db.transaction(() async {
              await _patchAppliedEntity(resp, remainingOps);
              if (appliedOp != null) {
                await _patchDocNo(appliedOp, resp);
                await _patchShiftOpen(appliedOp, resp);
                await patchSaleFromPushReply(db, appliedOp, resp, remainingOps);
              }
              await (db.delete(db.outboxOps)
                    ..where((t) => t.opId.equals(opId)))
                  .go();
              await AppliedEffects.forget(db, opId);
            });
          } else if (status == 'rejected') {
            final code = r['code'] as String?;
            final msg = r['message'] as String?;
            final details =
                r['details'] != null ? jsonEncode(r['details']) : null;
            await (db.update(db.outboxOps)..where((t) => t.opId.equals(opId)))
                .write(
              OutboxOpsCompanion(
                status: const Value('rejected'),
                attempts: const Value(0),
                lastCode: Value(code),
                lastMessage: Value(msg),
                lastDetails: Value(details),
              ),
            );
          } else if (status == 'retry') {
            // B3 / §8.4: op N got retry -> attempts += 1. Subsequent ops are skipped.
            final op = batchOps.firstWhere(
              (o) => o.opId == opId,
              orElse: () => batchOps.first,
            );
            final currentOp = await (db.select(db.outboxOps)
                  ..where((t) => t.opId.equals(op.opId)))
                .getSingleOrNull();
            if (currentOp != null) {
              final newAttempts = currentOp.attempts + 1;
              final newStatus = newAttempts >= 3 ? 'stuck' : 'pending';
              await (db.update(db.outboxOps)
                    ..where((t) => t.opId.equals(op.opId)))
                  .write(
                OutboxOpsCompanion(
                  attempts: Value(newAttempts),
                  status: Value(newStatus),
                ),
              );
            }
            stoppedAtRetry = true;
            break;
          }
        }

        await _refreshOutbox();

        if (stoppedAtRetry) {
          _pushRequested = false;
          break;
        }
      }
    } finally {
      _isPushing = false;
      _activePushCompleter = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (_pushRequested && !_isDisposed) {
        unawaited(push());
      } else if (_currentStatus == SyncStatus.online && !_isDisposed) {
        // 08 §15: Push then pull
        unawaited(pull());
      }
    }
  }

  /// Coordinates pull sync across entities after push completion (08 §15).
  Future<void> pull() async {
    if (_isDisposed || _currentStatus == SyncStatus.degraded) return;
    try {
      if (onPull != null) {
        await onPull!();
      }
    } catch (_) {}
  }

  Future<void> _handleHeadFailure(OutboxOpRow headOp) async {
    if (_isDisposed) return;
    final current = await (db.select(db.outboxOps)
          ..where((t) => t.opId.equals(headOp.opId)))
        .getSingleOrNull();
    if (current != null) {
      final newAttempts = current.attempts + 1;
      final newStatus = newAttempts >= 3 ? 'stuck' : 'pending';
      await (db.update(db.outboxOps)
            ..where((t) => t.opId.equals(headOp.opId)))
          .write(
        OutboxOpsCompanion(
          attempts: Value(newAttempts),
          status: Value(newStatus),
        ),
      );
      await _refreshOutbox();
    }
  }

  /// Owner decision 2026-09-25: the server is the source of truth for RC/CN
  /// numbers. When an `applied` (incl. replayed) `sale.create`/`return.create`
  /// comes back with a number that differs from the local row's offline one,
  /// the local row takes the server's (a sale's local returns follow, since
  /// they carry a copy of its `receiptNo`). A missing field leaves rows alone.
  ///
  /// The offline number printed on the paper receipt is not kept anywhere
  /// locally after this (no column for it; the outbox op is deleted in the
  /// same transaction) — the server records both in an owner review item.
  Future<void> _patchDocNo(
    OutboxOpRow op,
    Map<String, dynamic>? response,
  ) async {
    if (response == null) return;
    String? clientId;
    try {
      final payload = jsonDecode(op.payload);
      if (payload is Map) clientId = payload['id'] as String?;
    } catch (_) {}
    if (clientId == null) return;

    if (op.type == 'sale.create') {
      final serverNo = response['receiptNo'];
      if (serverNo is! String || serverNo.isEmpty) return;
      // #489: a replay may answer with the number an online attempt already
      // got (not the offline one) — the counter must reach it too.
      await docNumberService?.commitServerIssued(serverNo);
      await (db.update(db.sales)
            ..where((t) =>
                t.id.equals(clientId!) & t.receiptNo.equals(serverNo).not()))
          .write(SalesCompanion(receiptNo: Value(serverNo)));
      // Local returns carry a copy of the parent sale's number.
      await (db.update(db.returns)
            ..where((t) =>
                t.saleId.equals(clientId!) &
                t.receiptNo.equals(serverNo).not()))
          .write(ReturnsCompanion(receiptNo: Value(serverNo)));
    } else if (op.type == 'return.create') {
      final serverNo = response['cnNo'];
      if (serverNo is! String || serverNo.isEmpty) return;
      await docNumberService?.commitServerIssued(serverNo);
      await (db.update(db.returns)
            ..where((t) =>
                t.id.equals(clientId!) & t.cnNo.equals(serverNo).not()))
          .write(ReturnsCompanion(cnNo: Value(serverNo)));
    }
  }

  /// An applied `shift.open` (#452): the local shift takes the server's
  /// `openedAt` — it may have clamped a future device time to `now()` (08 §10).
  /// The response carries no `dateStr`, so that column is left as it is; a
  /// missing field never means "work it out here" (ADR-0010 §3).
  Future<void> _patchShiftOpen(
    OutboxOpRow op,
    Map<String, dynamic>? response,
  ) async {
    if (op.type != 'shift.open' || response == null) return;
    final id = response['id'];
    final openedAt = response['openedAt'];
    if (id is! String || openedAt is! String) return;
    final parsed = DateTime.tryParse(openedAt);
    if (parsed == null) return;
    await (db.update(db.shifts)..where((t) => t.id.equals(id))).write(
      ShiftsCompanion(openedAt: Value(parsed.toLocal())),
    );
  }

  Future<void> _patchAppliedEntity(
    Map<String, dynamic>? response,
    List<OutboxOpRow> remainingOps,
  ) async {
    if (response == null) return;

    final activeProductIds = <String>{};
    for (final op in remainingOps) {
      try {
        final payload = jsonDecode(op.payload);
        if (payload is Map<String, dynamic>) {
          final items = payload['items'];
          if (items is List) {
            for (final item in items) {
              if (item is Map && item['productId'] != null) {
                activeProductIds.add(item['productId'].toString());
              }
            }
          }
        }
      } catch (_) {}
    }

    final products = response['products'];
    if (products is List) {
      for (final p in products) {
        if (p is Map) {
          final id = p['id']?.toString();
          final stock = p['stock'];
          if (id != null && stock is int && !activeProductIds.contains(id)) {
            await (db.update(db.products)..where((t) => t.id.equals(id))).write(
              ProductsCompanion(stock: Value(stock)),
            );
          }
        }
      }
    }

    final stockRestored = response['stockRestored'];
    if (stockRestored is List) {
      for (final p in stockRestored) {
        if (p is Map) {
          final id = (p['id'] ?? p['productId'])?.toString();
          final stock = p['stock'];
          if (id != null && stock is int && !activeProductIds.contains(id)) {
            await (db.update(db.products)..where((t) => t.id.equals(id))).write(
              ProductsCompanion(stock: Value(stock)),
            );
          }
        }
      }
    }

    // Mechanic credit payment applied (#275)
    final mechanicId = response['mechanicId'] as String?;
    final balanceAfterRaw = response['balanceAfter'] ??
        response['mechanicCreditBalanceAfter'] ??
        response['mechanic_credit_balance_after'];
    if (mechanicId != null) {
      // Another unsent op still moves this mechanic: keep the local balance
      // (it already includes that op; the server's does not yet).
      if (balanceAfterRaw != null &&
          !(await ledgerIdsIn(db, remainingOps)).mechanics.contains(mechanicId)) {
        final balance = double.tryParse(balanceAfterRaw.toString());
        if (balance != null) {
          await (db.update(db.mechanics)..where((t) => t.id.equals(mechanicId)))
              .write(
            MechanicsCompanion(creditBalance: Value(balance)),
          );
        }
      }

      final paymentId = response['id'] as String?;
      final amountRaw = response['amount'];
      if (paymentId != null && amountRaw != null) {
        final amount = double.tryParse(amountRaw.toString()) ?? 0.0;
        final receiptNo =
            (response['receiptNo'] ?? response['receipt_no'] ?? '') as String;
        final dateRaw = response['date'];
        DateTime paymentDate = DateTime.now();
        if (dateRaw != null) {
          try {
            paymentDate = DateTime.parse(dateRaw.toString()).toLocal();
          } catch (_) {}
        }
        final note = response['note'] as String?;

        await db.into(db.creditPayments).insertOnConflictUpdate(
              CreditPaymentRow(
                id: paymentId,
                receiptNo: receiptNo,
                mechanicId: mechanicId,
                amount: amount,
                date: paymentDate,
                note: note,
              ),
            );
      }
    }

    // Customer applied (customer.create / customer.update) (#229)
    final customerId = response['id'] as String?;
    if (customerId != null &&
        (response.containsKey('name') ||
            response.containsKey('phone') ||
            response.containsKey('points') ||
            response.containsKey('totalSpend') ||
            response.containsKey('code'))) {
      final existing = await (db.select(db.customers)
            ..where((t) => t.id.equals(customerId)))
          .getSingleOrNull();

      final customerCode = response['code'] as String?;
      final name = response['name'] as String?;
      final nameTH = (response['nameTH'] ??
          response['name_t_h'] ??
          response['nameTh']) as String?;
      final phone = response.containsKey('phone')
          ? response['phone'] as String?
          : null;
      final address = response.containsKey('address')
          ? response['address'] as String?
          : null;
      final points = (response['points'] as num?)?.toInt();
      final totalSpend = response.containsKey('totalSpend')
          ? double.tryParse(response['totalSpend']?.toString() ?? '')
          : null;

      if (existing != null) {
        await (db.update(db.customers)..where((t) => t.id.equals(customerId)))
            .write(
          CustomersCompanion(
            code: customerCode != null
                ? Value(customerCode)
                : const Value.absent(),
            name: name != null ? Value(name) : const Value.absent(),
            nameTH: nameTH != null
                ? Value(nameTH)
                : (name != null ? Value(name) : const Value.absent()),
            phone: response.containsKey('phone')
                ? Value(phone)
                : const Value.absent(),
            address: response.containsKey('address')
                ? Value(address)
                : const Value.absent(),
            points: points != null ? Value(points) : const Value.absent(),
            totalSpend:
                totalSpend != null ? Value(totalSpend) : const Value.absent(),
          ),
        );
      } else {
        await db.into(db.customers).insertOnConflictUpdate(
              CustomersCompanion(
                id: Value(customerId),
                code: Value(customerCode ?? ''),
                name: Value(name ?? ''),
                nameTH: Value(nameTH ?? name ?? ''),
                phone: Value(phone),
                address: Value(address),
                points: Value(points ?? 0),
                totalSpend: Value(totalSpend ?? 0.0),
                createdAt: Value(
                  (response['createdAt'] ??
                          response['created_at'] ??
                          DateTime.now().toUtc().toIso8601String())
                      as String,
                ),
              ),
            );
      }
    }
  }

  // ── Aggregate Chain Filtering (§8.4) ──────────────────────────────────────

  static List<String> parseAggregates(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Calculates which pending operations are sendable according to the
  /// aggregate dependency chain.
  ///
  /// Stuck and rejected operations block their own aggregate. Any pending
  /// operation referencing that aggregate is transitively blocked and will
  /// block its own aggregate as well. Operations with independent aggregates
  /// remain sendable.
  static List<OutboxOpRow> findSendableOps(List<OutboxOpRow> allOps) {
    final blockedAggregates = <String>{};

    for (final op in allOps) {
      if (op.status == 'stuck' || op.status == 'rejected') {
        final aggs = parseAggregates(op.aggregates);
        if (aggs.isNotEmpty) {
          blockedAggregates.add(aggs.first);
        }
      }
    }

    final sendable = <OutboxOpRow>[];

    for (final op in allOps) {
      if (op.status != 'pending') continue;

      final aggs = parseAggregates(op.aggregates);
      final isBlocked = aggs.any(blockedAggregates.contains);

      if (isBlocked) {
        if (aggs.isNotEmpty) {
          blockedAggregates.add(aggs.first);
        }
      } else {
        sendable.add(op);
      }
    }

    return sendable;
  }

  // ── SyncFacade Contract Methods ───────────────────────────────────────────

  @override
  Future<void> resend(String opId) async {
    if (_isDisposed) return;
    await (db.update(db.outboxOps)..where((t) => t.opId.equals(opId))).write(
      const OutboxOpsCompanion(
        attempts: Value(0),
        status: Value('pending'),
      ),
    );
    await _refreshOutbox();
    if (_currentStatus != SyncStatus.degraded) {
      unawaited(push());
    }
  }

  @override
  Future<DiscardResult> discard(String opId, String note) async {
    final op = await (db.select(db.outboxOps)
          ..where((t) => t.opId.equals(opId)))
        .getSingleOrNull();
    if (op == null) {
      throw ArgumentError('ไม่พบรายการ opId: $opId ใน outbox');
    }

    final payload = _payloadOf(op);
    final clientId = payload['id'] as String?;

    // #473: a bill that later local writes (a credit note) already moved has
    // no single effect left to undo — refused before the server records the
    // discard (owner kept "refuse", 2026-09-28). #488: a bill voided offline
    // whose void is still queued is the exception — both ops go together.
    var voidOps = const <OutboxOpRow>[];
    if (op.type == 'sale.create' && clientId != null) {
      voidOps = await _queuedVoidsOf(clientId);
      await _refuseIfSaleHasLocalDependents(
        clientId,
        voidQueued: voidOps.isNotEmpty,
      );
    }
    // #488 (owner 2026-09-28): an undo that takes stock off the shelf is
    // refused when those units were sold again meanwhile — never negative,
    // never silently clamped. Checked again inside the tx.
    await _refuseIfStockAlreadySold(op, payload);

    final serverHasRow = await _postDiscard(op, payload, clientId, note);
    // The void rides along with its bill; recorded on the server too.
    if (!serverHasRow) {
      for (final v in voidOps) {
        await _postDiscard(v, _payloadOf(v), null, note);
      }
    }

    await db.transaction(() async {
      await (db.delete(db.outboxOps)..where((t) => t.opId.equals(opId))).go();

      if (!serverHasRow && clientId != null) {
        if (op.type == 'sale.create') {
          // Again inside the tx: a credit note may have landed during the POST.
          final voids = await _queuedVoidsOf(clientId);
          await _refuseIfSaleHasLocalDependents(
            clientId,
            voidQueued: voids.isNotEmpty,
          );
          if (voids.isEmpty) {
            await _undoOrLegacy(
              opId,
              () => _legacyReverseOfflineSale(clientId),
            );
          } else {
            await _discardSaleWithVoids(opId, voids);
          }
          await (db.delete(db.sales)..where((t) => t.id.equals(clientId))).go();
          await (db.delete(db.saleItems)
                ..where((t) => t.saleId.equals(clientId)))
              .go();
        } else if (op.type == 'return.create') {
          await _refuseIfStockAlreadySold(op, payload);
          final ret = await (db.select(db.returns)
                ..where((t) => t.id.equals(clientId)))
              .getSingleOrNull();
          await _undoOrLegacy(
            opId,
            () => _legacyReverseOfflineReturn(clientId),
          );
          await (db.delete(db.returns)..where((t) => t.id.equals(clientId)))
              .go();
          await (db.delete(db.returnItems)
                ..where((t) => t.returnId.equals(clientId)))
              .go();
          if (ret != null) await _unvoidIfNoLongerFullyReturned(ret.saleId);
        }
      }

      // #488: the void never reached the server (serverHasRow = the server's
      // bill is not voided), so the bill stands again — stock off the shelf,
      // ledger re-applied, `voided` cleared. When the server already voided
      // it, the till's void is the truth: only the op and its record go.
      final voidedSaleId = payload['saleId'] as String?;
      if (op.type == 'sale.void_offline' &&
          voidedSaleId != null &&
          !serverHasRow) {
        await _refuseIfStockAlreadySold(op, payload);
        await _undoOrLegacy(
          opId,
          () => _legacyReapplyVoidedSale(voidedSaleId),
        );
      }
      await AppliedEffects.forget(db, opId);
    });

    await _refreshOutbox();

    return DiscardResult(serverHasRow: serverHasRow);
  }

  Map<String, dynamic> _payloadOf(OutboxOpRow op) {
    try {
      final decoded = jsonDecode(op.payload);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  /// `POST /sync/discards` for [op]; returns the server's `serverHasRow`.
  Future<bool> _postDiscard(
    OutboxOpRow op,
    Map<String, dynamic> payload,
    String? clientId,
    String note,
  ) async {
    final discardBody = <String, dynamic>{
      'opId': op.opId,
      'type': op.type,
      'payload': payload,
      'note': note,
    };
    if (clientId != null) {
      discardBody['clientId'] = clientId;
    }
    if (op.lastCode != null) {
      discardBody['lastCode'] = op.lastCode;
    }

    final res = await apiClient.post(
      '/api/v1/sync/discards',
      body: discardBody,
      headers: {'Idempotency-Key': newIdempotencyKey('idem')},
    );

    if (res is Map) {
      final data = res['data'];
      if (data is Map && data['serverHasRow'] != null) {
        return data['serverHasRow'] as bool;
      } else if (res['serverHasRow'] != null) {
        return res['serverHasRow'] as bool;
      }
    }
    return false;
  }

  Future<List<OutboxOpRow>> _queuedVoidsOf(String saleId) async {
    final ops = await (db.select(db.outboxOps)
          ..where((t) => t.type.equals('sale.void_offline')))
        .get();
    return [
      for (final o in ops)
        if (_payloadOf(o)['saleId'] == saleId) o,
    ];
  }

  Future<void> _refuseIfSaleHasLocalDependents(
    String saleId, {
    required bool voidQueued,
  }) async {
    final sale = await (db.select(db.sales)..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
    final hasReturns = await (db.select(db.returns)
              ..where((t) => t.saleId.equals(saleId))
              ..limit(1))
            .getSingleOrNull() !=
        null;
    if (((sale?.voided ?? false) && !voidQueued) || hasReturns) {
      throw const PosException(
        'DISCARD_HAS_LOCAL_DEPENDENTS',
        'บิลนี้มีการคืนสินค้าหรือยกเลิกในเครื่องแล้ว ไม่สามารถทิ้งได้',
      );
    }
  }

  /// #488: refuses the discard of a `return.create` / `sale.void_offline`
  /// whose undo would take off the shelf units that were sold again — from
  /// the recorded deltas, or (legacy) the note's / bill's lines.
  Future<void> _refuseIfStockAlreadySold(
    OutboxOpRow op,
    Map<String, dynamic> payload,
  ) async {
    if (op.type != 'return.create' && op.type != 'sale.void_offline') return;
    final take = <String, int>{};
    final effects = await AppliedEffects.load(db, op.opId);
    if (effects != null) {
      effects.stock.forEach((id, d) {
        if (d > 0) take[id] = d;
      });
    } else if (op.type == 'return.create' && payload['id'] is String) {
      final items = await (db.select(db.returnItems)
            ..where((t) => t.returnId.equals(payload['id'] as String)))
          .get();
      for (final i in items) {
        take[i.productId] = (take[i.productId] ?? 0) + i.qty;
      }
    } else if (op.type == 'sale.void_offline' && payload['saleId'] is String) {
      final items = await (db.select(db.saleItems)
            ..where((t) => t.saleId.equals(payload['saleId'] as String)))
          .get();
      for (final i in items) {
        take[i.productId] = (take[i.productId] ?? 0) + i.qty;
      }
    }
    for (final entry in take.entries) {
      final p = await (db.select(db.products)
            ..where((t) => t.id.equals(entry.key)))
          .getSingleOrNull();
      if (p != null && p.stock - entry.value < 0) {
        // Thai copy ratified by the owner 2026-09-28 (#488).
        throw const PosException(
          'DISCARD_STOCK_ALREADY_SOLD',
          'สินค้าที่คืนถูกขายออกไปแล้ว ไม่สามารถทิ้งรายการนี้ได้ กรุณาปรับสต็อกก่อน',
        );
      }
    }
  }

  /// #488: after a credit note goes, the bill is voided only if its remaining
  /// notes still bring back every unit — re-derived from the notes left, not
  /// from which note happened to auto-void it.
  Future<void> _unvoidIfNoLongerFullyReturned(String saleId) async {
    final sale = await (db.select(db.sales)..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
    if (sale == null || !sale.voided) return;
    final sold = (await (db.select(db.saleItems)
              ..where((t) => t.saleId.equals(saleId)))
            .get())
        .fold<int>(0, (s, i) => s + i.qty);
    final refunded = (await refundedQtyOf(db, saleId))
        .values
        .fold<int>(0, (s, q) => s + q);
    // A bill with a credit note is voided only by a full return's auto-void
    // (every void path refuses SALE_HAS_RETURNS), so short of full = not void.
    if (refunded < sold) {
      await (db.update(db.sales)..where((t) => t.id.equals(saleId))).write(
        const SalesCompanion(voided: Value(false), voidedAt: Value(null)),
      );
    }
  }

  /// #488: reverses [opId] from its recorded deltas, exactly. An op queued
  /// before schema v13 has no record and falls back to [legacy].
  Future<void> _undoOrLegacy(
    String opId,
    Future<void> Function() legacy,
  ) async {
    final effects = await AppliedEffects.load(db, opId);
    if (effects != null) {
      await effects.undo(db);
    } else {
      await legacy();
    }
  }

  /// #488: a bill and its queued offline void(s) go together. The void
  /// already undid the bill, so with every record present undoing both nets
  /// to the pre-sale ledger exactly (clamps included); with any record missing
  /// (queued before v13) the ledger is left as the void left it.
  Future<void> _discardSaleWithVoids(
    String saleOpId,
    List<OutboxOpRow> voids,
  ) async {
    final records = [
      await AppliedEffects.load(db, saleOpId),
      for (final v in voids) await AppliedEffects.load(db, v.opId),
    ];
    if (records.every((r) => r != null)) {
      for (final r in records) {
        await r!.undo(db);
      }
    }
    for (final v in voids) {
      await (db.delete(db.outboxOps)..where((t) => t.opId.equals(v.opId)))
          .go();
      await AppliedEffects.forget(db, v.opId);
    }
  }

  /// LEGACY (ops queued before schema v13, no `op_effects` record): #473's
  /// recompute of what `ApiSalesRepository._saveOffline` applied — stock back,
  /// customer spend/points and mechanic stats out, credit only for
  /// 'เครดิตช่าง'. Not exact when the forward write clamped (#488).
  Future<void> _legacyReverseOfflineSale(String saleId) async {
    final sale = await (db.select(db.sales)..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
    if (sale == null) return;
    final items = await (db.select(db.saleItems)
          ..where((t) => t.saleId.equals(saleId)))
        .get();
    for (final item in items) {
      final p = await (db.select(db.products)
            ..where((t) => t.id.equals(item.productId)))
          .getSingleOrNull();
      if (p != null) {
        await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(
          ProductsCompanion(stock: Value(p.stock + item.qty)),
        );
      }
    }

    if (sale.customerId != null) {
      final c = await (db.select(db.customers)
            ..where((t) => t.id.equals(sale.customerId!)))
          .getSingleOrNull();
      if (c != null) {
        await (db.update(db.customers)..where((t) => t.id.equals(c.id))).write(
          CustomersCompanion(
            totalSpend: Value(max(0.0, c.totalSpend - sale.total)),
            points: Value(max(0, c.points - sale.pointsGranted)),
          ),
        );
      }
    }

    if (sale.mechanicId != null) {
      final m = await (db.select(db.mechanics)
            ..where((t) => t.id.equals(sale.mechanicId!)))
          .getSingleOrNull();
      if (m != null) {
        final delta = sale.mechanicDelta ?? 0;
        final isCredit = sale.paymentMethod == 'เครดิตช่าง';
        await (db.update(db.mechanics)..where((t) => t.id.equals(m.id))).write(
          MechanicsCompanion(
            totalSales: Value(max(0.0, m.totalSales - sale.total)),
            totalDiscount:
                Value(max(0.0, m.totalDiscount - (delta < 0 ? -delta : 0))),
            totalMarkup:
                Value(max(0.0, m.totalMarkup - (delta > 0 ? delta : 0))),
            creditBalance: Value(
              max(0.0, m.creditBalance - (isCredit ? sale.total : 0)),
            ),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    }
  }

  /// LEGACY (no `op_effects` record): #473's recompute of what
  /// `ApiReturnsRepository._createOffline` applied, from the same proportions
  /// `planReturn` used — stock off the shelf again, customer and mechanic
  /// reversal added back, credit only for 'หักจากเครดิต', and the parent bill
  /// un-voided. Not exact when the forward write clamped (#488).
  Future<void> _legacyReverseOfflineReturn(String returnId) async {
    final ret = await (db.select(db.returns)
          ..where((t) => t.id.equals(returnId)))
        .getSingleOrNull();
    if (ret == null) return;
    final items = await (db.select(db.returnItems)
          ..where((t) => t.returnId.equals(returnId)))
        .get();
    for (final item in items) {
      final p = await (db.select(db.products)
            ..where((t) => t.id.equals(item.productId)))
          .getSingleOrNull();
      if (p != null) {
        await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(
          ProductsCompanion(stock: Value(p.stock - item.qty)),
        );
      }
    }

    final sale = await (db.select(db.sales)
          ..where((t) => t.id.equals(ret.saleId)))
        .getSingleOrNull();
    if (sale == null) return;
    final ratio = sale.total > 0 ? ret.refundTotal / sale.total : 0.0;

    if (ret.customerId != null) {
      final c = await (db.select(db.customers)
            ..where((t) => t.id.equals(ret.customerId!)))
          .getSingleOrNull();
      if (c != null) {
        final basePoints = sale.pointsGranted > 0
            ? sale.pointsGranted
            : (sale.total / 10).floor();
        await (db.update(db.customers)..where((t) => t.id.equals(c.id))).write(
          CustomersCompanion(
            totalSpend: Value(c.totalSpend + ret.refundTotal),
            points: Value(c.points + (basePoints * ratio).floor()),
          ),
        );
      }
    }

    if (ret.mechanicId != null) {
      final m = await (db.select(db.mechanics)
            ..where((t) => t.id.equals(ret.mechanicId!)))
          .getSingleOrNull();
      if (m != null) {
        final delta = sale.mechanicDelta ?? 0;
        final reverseCredit = delta < 0 ? -delta * ratio : 0.0;
        // planReturn's db.js base is (totalDiscount || totalCredit): when the
        // note found totalDiscount at 0 it wrote max(0, totalCredit − credit),
        // so the value before it was 0. totalCredit is never written locally,
        // so the same expression recognises that case here.
        final usedCreditBase = m.totalCredit != 0 &&
            m.totalDiscount == max(0.0, m.totalCredit - reverseCredit);
        await (db.update(db.mechanics)..where((t) => t.id.equals(m.id))).write(
          MechanicsCompanion(
            totalSales: Value(m.totalSales + ret.refundTotal),
            totalDiscount: Value(
              usedCreditBase ? 0.0 : m.totalDiscount + reverseCredit,
            ),
            totalMarkup:
                Value(m.totalMarkup + (delta > 0 ? delta * ratio : 0.0)),
            creditBalance: Value(
              m.creditBalance +
                  (ret.refundMethod == 'หักจากเครดิต' ? ret.refundTotal : 0.0),
            ),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    }

    // A bill with a credit note can only be voided by a full return's
    // auto-void (every void path refuses with SALE_HAS_RETURNS), and with this
    // note gone the bill is no longer fully returned.
    if (sale.voided) {
      await (db.update(db.sales)..where((t) => t.id.equals(sale.id))).write(
        const SalesCompanion(voided: Value(false), voidedAt: Value(null)),
      );
    }
  }

  /// LEGACY (no `op_effects` record): re-applies what
  /// `ApiSalesRepository.voidSaleOffline` reversed, recomputed from the bill
  /// the way `_saveOffline` first applied it, and clears the void.
  Future<void> _legacyReapplyVoidedSale(String saleId) async {
    final sale = await (db.select(db.sales)..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
    if (sale == null) return;
    final items = await (db.select(db.saleItems)
          ..where((t) => t.saleId.equals(saleId)))
        .get();
    for (final item in items) {
      final p = await (db.select(db.products)
            ..where((t) => t.id.equals(item.productId)))
          .getSingleOrNull();
      if (p != null) {
        await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(
          ProductsCompanion(stock: Value(p.stock - item.qty)),
        );
      }
    }
    if (sale.customerId != null) {
      final c = await (db.select(db.customers)
            ..where((t) => t.id.equals(sale.customerId!)))
          .getSingleOrNull();
      if (c != null) {
        await (db.update(db.customers)..where((t) => t.id.equals(c.id))).write(
          CustomersCompanion(
            totalSpend: Value(c.totalSpend + sale.total),
            points: Value(c.points + sale.pointsGranted),
          ),
        );
      }
    }
    if (sale.mechanicId != null) {
      final m = await (db.select(db.mechanics)
            ..where((t) => t.id.equals(sale.mechanicId!)))
          .getSingleOrNull();
      if (m != null) {
        final delta = sale.mechanicDelta ?? 0;
        final isCredit = sale.paymentMethod == 'เครดิตช่าง';
        await (db.update(db.mechanics)..where((t) => t.id.equals(m.id))).write(
          MechanicsCompanion(
            totalSales: Value(m.totalSales + sale.total),
            totalDiscount: Value(m.totalDiscount + (delta < 0 ? -delta : 0)),
            totalMarkup: Value(m.totalMarkup + (delta > 0 ? delta : 0)),
            creditBalance: Value(
              m.creditBalance + (isCredit ? sale.total : 0),
            ),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    }
    await (db.update(db.sales)..where((t) => t.id.equals(saleId))).write(
      const SalesCompanion(
        voided: Value(false),
        voidedAt: Value(null),
        voidReason: Value(null),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Atomic write rule: encapsulates local entity writes and outbox insertion
  /// inside a single transaction (ADR-0010 / #84).
  Future<T> writeAtomic<T>(Future<T> Function() action) =>
    db.transaction(action);

  /// Enqueues an op into `outbox_ops`.
  Future<void> enqueueOp({
    required String opId,
    required String idempotencyKey,
    required String type,
    required Map<String, dynamic> payload,
    required List<String> aggregates,
    DateTime? createdAt,
    String status = 'pending',
  }) async {
    await db.into(db.outboxOps).insert(
          OutboxOpsCompanion.insert(
            opId: opId,
            idempotencyKey: idempotencyKey,
            type: type,
            payload: jsonEncode(payload),
            aggregates: jsonEncode(aggregates),
            createdAt: createdAt ?? DateTime.now().toUtc(),
            status: status,
          ),
        );
    await _refreshOutbox();
    if (_currentStatus != SyncStatus.degraded) {
      unawaited(push());
    }
  }

  void dispose() {
    _isDisposed = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    _outboxSubscription?.cancel();
    _outboxSubscription = null;
    _statusController.close();
    _needsOwnerController.close();
    _outboxRemainingController.close();
  }
}
