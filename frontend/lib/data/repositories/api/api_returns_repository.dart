// ApiReturnsRepository — `POST /api/v1/returns`, then patch the Drift cache
// (#56, ADR-0010).
//
// Same rule as `api_sales_repository.dart`: the Drift `createReturn` is a
// transaction that restores stock, reverses the customer's points and spend,
// reverses the mechanic's tab and auto-voids the parent bill. All of that is now
// `server/src/returns/returns.service.ts`, so the Drift service is never called —
// a credit note applied twice puts the goods back on the shelf twice.
//
// 🔴 The price is the server's verdict, not ours. `returns.service.ts` reads what
// each product-and-price actually sold for on the parent bill and answers
// `409 RETURN_PRICE_MISMATCH` when the client's line disagrees — the bug #22's
// review found was a client that could name any refund amount it liked. So the
// screen's price is sent AS GIVEN and never "corrected" on the way out: a
// mismatch must be refused loudly, not silently fixed into a different credit
// note than the one the counter is about to print.
//
// 🔴 Naming: the "did this void the bill" flag is **`saleVoided`**. Issue #56 and
// ADR-0010 both call it `parentSaleVoided`; no such field exists on
// `CreateReturnResult`. Reading the docs instead of the server would have left
// `sales.voided` permanently false here. Flagged in the #56 report.
//
// #82 added `movements[]` and `mechanicAfter` to `CreateReturnResult`, so the two
// gaps #56 had to leave stale are patched below. Both are read DEFENSIVELY — a
// server that predates #82 answers without them and a missing field must not
// crash the counter — and absent means the local table is left as it was, never
// that the value is worked out here (ADR-0010 §3).
//
// Phase 2 (#452, 08 §6.1/§7): `return.create` is a queued op. The online body
// carries the client's `id`, minted ONCE per attempt with its `Idempotency-Key`
// ([PendingWrites]). Degraded, or a lost connection with the sync engine wired
// → the credit note is written locally in ONE transaction with its CN number and
// its `outbox_ops` row, under that same id + key ([_createOffline]). The local
// arithmetic comes from the pure [planReturn], never from the Drift service. A
// 5xx does NOT queue (owner 2026-09-27, parity with sales): the attempt stays
// parked for the retry.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_error_resolver.dart';
import '../../../core/network/transport_failure.dart';
import '../../../core/utils/ids.dart';
import '../../../domain/models/aggregates.dart';
import '../../db/database.dart';
import '../../services/doc_number_service.dart';
import '../../storage/token_storage.dart' show TokenStoreUnavailableException;
import '../../sync/sync_facade.dart';
import '../../sync/sync_service.dart';
import '../return_plan.dart';
import '../returns_repository.dart';
import 'api_wire.dart';

class ApiReturnsRepository implements ReturnsRepository {
  ApiReturnsRepository({
    required this.api,
    required this.db,
    required this.drift,
    this.syncService,
    this.docNumberService,
  });

  final ApiClient api;

  /// The sync engine — null on a build without the outbox, which then never
  /// queues (every failure surfaces as before).
  final SyncService? syncService;

  /// Issues the offline CN number (08 §9). Without it nothing can be queued.
  final DocNumberService? docNumberService;

  /// Plain row patches only — never `db.transaction` around the network call,
  /// never a Drift transactional service.
  @override
  final AppDatabase db;

  /// Reads stay on Drift until the read slice (#55) replaces them.
  final ReturnsRepository drift;

  /// The id + `Idempotency-Key` of a credit note that never got a verdict,
  /// keyed by the refund it was for.
  ///
  /// 🔴 The over-refund guard does not catch a resend: it enforces
  /// `requested ≤ sold − refunded`, so returning 3 of 10 twice is two legal
  /// credit notes and ฿600 refunded for ฿300 of goods. The key, and since #452
  /// the client `id` the server records the note under, are what make the
  /// second press a replay of the first.
  final PendingWrites _pending = PendingWrites('r');

  /// Same rule as `ApiSalesRepository._isDegraded` (08 §5): Degraded or
  /// Syncing, or anything already queued → a new write joins the outbox.
  bool get _isDegraded {
    final sync = syncService;
    if (sync == null) return false;
    return sync.currentStatus == SyncStatus.degraded ||
        sync.currentStatus == SyncStatus.syncing ||
        sync.currentOutboxRemaining > 0;
  }

  @override
  Future<ReturnRow> createReturn(ReturnInput input) {
    return rethrowThai(() async {
      // One id + key for this attempt, reused by `ApiClient`'s 401 → refresh →
      // retry, by the counter's own second press AND by the offline queue. A
      // credit note is money leaving the drawer; a second one is a second
      // refund for goods that came back once.
      final attempt = _pending.of(_refundKey(input));
      final body = _returnBody(attempt.id, input);

      if (_isDegraded) {
        final ret = await _createOffline(attempt, input, body);
        _pending.close(attempt);
        return ret;
      }

      final Map<String, dynamic> res;
      try {
        res =
            ((await api.post(
                      '/api/v1/returns',
                      body: body,
                      headers: attempt.headers,
                    ))
                    as Map)
                .cast<String, dynamic>();
      } on ApiException catch (e) {
        _pending.closeIfVerdict(attempt, e);
        rethrow;
      } catch (e) {
        // The web token store could not be opened for the 401 → refresh: the
        // server refused this attempt before any transaction, so nothing is
        // queued and the till shows the store's own sentence (same as sales).
        if (e is TokenStoreUnavailableException) rethrow;
        // #409: a reply that arrived but is not a credit note means the server
        // answered and has probably committed — never an offline note. The
        // attempt stays parked so the next press replays it.
        if (!isTransportFailure(e)) {
          throw PosException(
            'UNREADABLE_RESPONSE',
            ServerErrorResolver.resolve(null),
          );
        }
        // Only a TRANSPORT failure (timeout, dropped socket) with the sync
        // engine wired becomes an offline credit note, under the SAME id + key:
        // if the lost request had in fact committed, the push replays it (08 §5).
        final sync = syncService;
        if (sync == null) rethrow;
        sync.recordNonVerdictWrite();
        final ret = await _createOffline(attempt, input, body);
        _pending.close(attempt);
        return ret;
      }

      final row = await _patchFromResponse(res);
      // Closed only after the cache agrees — same rule as the sale path.
      _pending.close(attempt);
      return row;
    });
  }

  /// Exactly the fields `parseCreateReturn` reads. `cnNo` and `date` join it
  /// only on the queued op (08 §6.4, same as `sale.create`).
  Map<String, dynamic> _returnBody(String id, ReturnInput input) => {
    'id': id,
    'saleId': input.saleId,
    'refundMethod': input.refundMethod,
    // `returns.reason` is NOT NULL DEFAULT '' on both sides, and the old app
    // stores '' when staff typed nothing.
    'reason': input.reason ?? '',
    'items': [
      for (final i in input.items)
        {
          'productId': i.productId,
          'name': i.name,
          'qty': i.qty,
          // Sent verbatim. See the file header: the bill decides the price.
          'price': wireMoney(i.price),
          'originalQty': i.originalQty,
        },
    ],
  };

  // ── Offline credit note (08 §6.1/§7/§9) ─────────────────────────────────

  /// Queues `return.create`: the credit note, its lines, the stock put back,
  /// the customer/mechanic reversal, the auto-void of a fully returned bill,
  /// the CN number and the `outbox_ops` row — ALL in one local transaction, so
  /// the note and its op exist together or not at all, and the CN number is
  /// consumed only when the op is queued (C8). The rules come from the pure
  /// [planReturn]; the Drift `createReturn` is never called.
  ///
  /// A refusal here leaves the attempt parked on purpose: after a transport
  /// failure the online request may have committed, so the next press must
  /// still carry the same id + key.
  Future<ReturnRow> _createOffline(
    PendingWrite attempt,
    ReturnInput input,
    Map<String, dynamic> body,
  ) async {
    final now = DateTime.now();
    final ret = await db.transaction(() async {
      final openShift =
          await (db.select(db.shifts)
                ..where((t) => t.isActive.equals(true) & t.closedAt.isNull())
                ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
                ..limit(1))
              .getSingleOrNull();
      // A cash refund is money leaving the drawer: the server refuses it with
      // no open drawer (#100), so it is refused here before anything is
      // written. A transfer or a tab deduction may go with no drawer, and then
      // has no `shift:` aggregate to wait on.
      if (input.refundMethod == 'เงินสด' && openShift == null) {
        throw PosException(
          'NO_OPEN_SHIFT',
          ServerErrorResolver.resolve('NO_OPEN_SHIFT'),
        );
      }

      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals(input.saleId))).getSingleOrNull();
      if (sale == null) {
        throw PosException(
          'SALE_NOT_FOUND',
          ServerErrorResolver.resolve('SALE_NOT_FOUND'),
        );
      }
      if (sale.voided) {
        throw PosException(
          'SALE_VOIDED',
          ServerErrorResolver.resolve('SALE_VOIDED'),
        );
      }
      // Only a bill naming a mechanic has a tab to deduct from — the server's
      // `REFUND_METHOD_NOT_ALLOWED`.
      if (input.refundMethod == 'หักจากเครดิต' && sale.mechanicId == null) {
        throw PosException(
          'REFUND_METHOD_NOT_ALLOWED',
          ServerErrorResolver.resolve('REFUND_METHOD_NOT_ALLOWED'),
        );
      }

      final soldItems = await (db.select(
        db.saleItems,
      )..where((t) => t.saleId.equals(sale.id))).get();
      final customer = sale.customerId == null
          ? null
          : await (db.select(
              db.customers,
            )..where((t) => t.id.equals(sale.customerId!))).getSingleOrNull();
      final mechanic = sale.mechanicId == null
          ? null
          : await (db.select(
              db.mechanics,
            )..where((t) => t.id.equals(sale.mechanicId!))).getSingleOrNull();
      final plan = planReturn(
        sale: sale,
        soldItems: soldItems,
        refundedSoFar: await refundedQtyOf(db, sale.id),
        input: input,
        customer: customer,
        mechanic: mechanic,
      );

      // After every guard, so a refused credit note burns no number.
      final cnNo = await _issueOfflineCnNo(now);

      final row = ReturnRow(
        id: attempt.id,
        cnNo: cnNo,
        saleId: sale.id,
        receiptNo: sale.receiptNo,
        refundSubtotal: plan.refundSubtotal,
        refundDiscount: plan.refundDiscount,
        refundTotal: plan.refundTotal,
        refundMethod: input.refundMethod,
        reason: input.reason ?? '',
        customerId: sale.customerId,
        mechanicId: sale.mechanicId,
        mechanicName: sale.mechanicName,
        date: now,
      );
      await db.into(db.returns).insert(row);
      for (final i in input.items) {
        await db
            .into(db.returnItems)
            .insert(
              ReturnItemsCompanion.insert(
                returnId: row.id,
                productId: i.productId,
                name: i.name,
                qty: i.qty,
                price: i.price,
                originalQty: Value(i.originalQty),
              ),
            );
      }

      // Stock back on the shelf. Not `.stamped` — same reason as the offline
      // sale: `updatedAt` is the pull cursor, and a local clock pushes it past
      // server changes it has not seen yet.
      for (final i in input.items) {
        final p = await (db.select(
          db.products,
        )..where((t) => t.id.equals(i.productId))).getSingleOrNull();
        if (p != null) {
          await (db.update(db.products)..where((t) => t.id.equals(p.id)))
              .write(ProductsCompanion(stock: Value(p.stock + i.qty)));
        }
      }

      final c = plan.customerAfter;
      if (c != null) {
        await (db.update(
          db.customers,
        )..where((t) => t.id.equals(sale.customerId!))).write(
          CustomersCompanion(
            totalSpend: Value(c.totalSpend),
            points: Value(c.points),
          ),
        );
      }
      final m = plan.mechanicAfter;
      if (m != null) {
        await (db.update(
          db.mechanics,
        )..where((t) => t.id.equals(sale.mechanicId!))).write(
          MechanicsCompanion(
            totalSales: Value(m.totalSales),
            totalDiscount: Value(m.totalDiscount),
            totalMarkup: Value(m.totalMarkup),
            creditBalance: Value(m.creditBalance),
            updatedAt: Value(now),
          ),
        );
      }
      if (plan.voidsSale) {
        await (db.update(db.sales)..where((t) => t.id.equals(sale.id))).write(
          SalesCompanion(voided: const Value(true), voidedAt: Value(now)),
        );
      }

      await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              opId: newId('op'),
              idempotencyKey: attempt.headers['Idempotency-Key']!,
              type: 'return.create',
              // = the online body + the device's CN number and clock (08 §6.4).
              payload: jsonEncode({
                ...body,
                'cnNo': cnNo,
                'date': now.toUtc().toIso8601String(),
              }),
              aggregates: jsonEncode([
                'return:${row.id}',
                'sale:${sale.id}',
                if (openShift != null) 'shift:${openShift.id}',
              ]),
              createdAt: now.toUtc(),
              status: 'pending',
            ),
          );
      return row;
    });

    final sync = syncService;
    if (sync != null) {
      await sync.refreshOutbox();
      if (sync.currentStatus != SyncStatus.degraded) unawaited(sync.push());
    }
    return ret;
  }

  /// The next CN number from this device's own counter (08 §9), committed in
  /// the caller's transaction. See [DocNumberService.issueOffline].
  Future<String> _issueOfflineCnNo(DateTime now) async {
    final numbers = docNumberService;
    if (numbers == null) throw const OfflineSeedRequiredException();
    return numbers.issueOffline(docType: 'cn', now: now);
  }

  /// Identifies "the same refund, sent again": the bill, how it is refunded, and
  /// every line. See [_pending].
  String _refundKey(ReturnInput input) => [
    input.saleId,
    input.refundMethod,
    input.reason ?? '',
    for (final i in input.items) '${i.productId}x${i.qty}@${wireMoney(i.price)}',
  ].join('|');

  /// Copies the server's credit note into the cache. One Drift transaction so a
  /// half-patched cache is impossible; the network call is already done.
  Future<ReturnRow> _patchFromResponse(Map<String, dynamic> res) async {
    final ret = ReturnRow(
      id: res['id'] as String,
      // Server's (ADR-0007) — `returns_screen.dart` prints this on the note.
      cnNo: res['cnNo'] as String,
      saleId: res['saleId'] as String,
      receiptNo: res['receiptNo'] as String,
      // All three refund amounts are the SERVER's: it recomputes them from the
      // bill's own prices and its own discount ratio. Never the client's sums.
      refundSubtotal: money(res['refundSubtotal']),
      refundDiscount: money(res['refundDiscount']),
      refundTotal: money(res['refundTotal']),
      refundMethod: res['refundMethod'] as String,
      reason: res['reason'] as String? ?? '',
      customerId: res['customerId'] as String?,
      mechanicId: res['mechanicId'] as String?,
      mechanicName: res['mechanicName'] as String?,
      date: stamp(res['date']),
      // `res['shiftId']` is DROPPED: the Drift `Returns` table has no shiftId
      // column. Per ADR-0010 decision 2 the client schema moves only when the
      // client actually needs the field, and nothing on this device reads a
      // credit note's shift — the closing report the server computes does. Adding
      // the column here would be schema churn with no reader. (`Sales.shiftId`
      // exists because #53 added it for the sale path.)
    );

    await db.transaction(() async {
      await db.into(db.returns).insert(ret);

      // Lines after the header: `ReturnItems.returnId` is a real FK.
      //
      // Built from the SERVER's `items`, not the input: the server is what
      // decided each line's price, and its list is the canonical one (it also
      // aggregates duplicate lines). `lineNo` and `costAtSale` come back too but
      // have no column here.
      final items =
          (res['items'] as List? ?? const [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList()
            ..sort(
              (a, b) => (a['lineNo'] as int? ?? 0).compareTo(
                b['lineNo'] as int? ?? 0,
              ),
            );
      await db.batch((b) {
        for (final i in items) {
          b.insert(
            db.returnItems,
            ReturnItemsCompanion.insert(
              returnId: ret.id,
              productId: i['productId'] as String,
              name: i['name'] as String,
              qty: i['qty'] as int,
              price: money(i['price']),
              originalQty: Value(i['originalQty'] as int?),
            ),
          );
        }
      });

      // Stock: the server's restored number, not `old + qty`.
      for (final p in (res['products'] as List? ?? const [])) {
        final row = (p as Map).cast<String, dynamic>();
        await (db.update(
          db.products,
        )..where((t) => t.id.equals(row['id'] as String))).write(
          // Not `.stamped`, for the reason spelled out in
          // `api_sales_repository.dart`: `updatedAt` is #55's sync cursor and
          // this response carries none, so a locally invented one would push the
          // cursor past server changes it has not seen yet.
          ProductsCompanion(stock: Value(row['stock'] as int)),
        );
      }

      // Customer: the reversed points and spend as the server has them — never
      // the local `max(0, old - refund)` the Drift service computes.
      final customerAfter = res['customerAfter'];
      if (customerAfter is Map) {
        final c = customerAfter.cast<String, dynamic>();
        await (db.update(
          db.customers,
        )..where((t) => t.id.equals(c['id'] as String))).write(
          CustomersCompanion(
            points: Value(c['points'] as int),
            totalSpend: Value(money(c['totalSpend'])),
          ),
        );
      }

      // Mechanic: the four running totals AS REVERSED BY THE SERVER (#82) —
      // never the local `old - refund`. `mechanicCreditBalanceAfter` stays as
      // the fallback for a server that predates #82; when neither field is
      // there the row is left stale rather than recomputed.
      //
      // 🔴 `totalCredit` is NOT written — the legacy alias of `totalDiscount`
      // settled in #11; the server never moves it.
      final mechanicAfter = res['mechanicAfter'];
      if (mechanicAfter is Map) {
        final m = mechanicAfter.cast<String, dynamic>();
        final companion = MechanicsCompanion(
          totalSales: keepMoney(moneyOrNull(m['totalSales'])),
          totalDiscount: keepMoney(moneyOrNull(m['totalDiscount'])),
          totalMarkup: keepMoney(moneyOrNull(m['totalMarkup'])),
          creditBalance: keepMoney(moneyOrNull(m['creditBalance'])),
        );
        if (companion != const MechanicsCompanion()) {
          await (db.update(db.mechanics)
                ..where((t) => t.id.equals(m['id'] as String)))
              .write(companion);
        }
      } else {
        final creditAfter = moneyOrNull(res['mechanicCreditBalanceAfter']);
        final mechanicId = ret.mechanicId;
        if (creditAfter != null && mechanicId != null) {
          await (db.update(db.mechanics)..where((t) => t.id.equals(mechanicId)))
              .write(MechanicsCompanion(creditBalance: Value(creditAfter)));
        }
      }

      // Auto-void: BECAUSE THE SERVER SAID SO. The Drift service decides this by
      // summing returned qty against sold qty; here that sum is the server's
      // business and the client would need the whole bill to redo it. `voidedAt`
      // is the credit note's own server timestamp — the void happened in that
      // same transaction — rather than a local clock reading.
      if (res['saleVoided'] == true) {
        await (db.update(
          db.sales,
        )..where((t) => t.id.equals(ret.saleId))).write(
          SalesCompanion(voided: const Value(true), voidedAt: Value(ret.date)),
        );
      }

      // The สต็อก log rows the SERVER wrote for this credit note (#82), copied
      // verbatim — `delta`, `stockAfter` and `type: 'return'` are all its
      // numbers ('return' is not the same row type as a void's 'void', see
      // `movementRowFromWire`). Without them the log on `products_screen.dart`
      // was blind to every API-written return.
      //
      // Absent → the table is left alone; the rows are safe on the server and a
      // read slice will fetch them. Inventing `{delta, stockAfter}` from the
      // lines is the arithmetic ADR-0010 §3 forbids.
      final movements = (res['movements'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (movements.isNotEmpty) {
        await db.batch((b) {
          for (final mv in movements) {
            b.insert(db.movements, movementRowFromWire(mv));
          }
        });
      }
    });

    return ret;
  }

  // ── Reads — still Drift (#55 owns them) ───────────────────────────────────

  @override
  Future<List<ReturnWithItems>> getReturns({DateTime? from, DateTime? to}) =>
      drift.getReturns(from: from, to: to);
}
