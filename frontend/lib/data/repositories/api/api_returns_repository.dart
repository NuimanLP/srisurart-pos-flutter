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

import 'package:drift/drift.dart';

import '../../../core/network/api_client.dart';
import '../../../domain/models/aggregates.dart';
import '../../db/database.dart';
import '../returns_repository.dart';
import 'api_wire.dart';

class ApiReturnsRepository implements ReturnsRepository {
  ApiReturnsRepository({
    required this.api,
    required this.db,
    required this.drift,
  });

  final ApiClient api;

  /// Plain row patches only — never `db.transaction` around the network call,
  /// never a Drift transactional service.
  @override
  final AppDatabase db;

  /// Reads stay on Drift until the read slice (#55) replaces them.
  final ReturnsRepository drift;

  @override
  Future<ReturnRow> createReturn(ReturnInput input) {
    return rethrowThai(() async {
      final body = {
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

      // One key for this attempt, reused by `ApiClient`'s 401 → refresh → retry.
      // A credit note is money leaving the drawer; a second one is a second
      // refund for goods that came back once.
      final res =
          ((await api.post(
                    '/api/v1/returns',
                    body: body,
                    headers: idempotencyKey(),
                  ))
                  as Map)
              .cast<String, dynamic>();

      return _patchFromResponse(res);
    });
  }

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

      // Mechanic: only the credit balance is returned. `totalSales`,
      // `totalDiscount` and `totalMarkup` are reversed server-side too but are
      // not in `CreateReturnResult`, so those columns go stale here rather than
      // being recomputed. Flagged in #56.
      final creditAfter = moneyOrNull(res['mechanicCreditBalanceAfter']);
      final mechanicId = ret.mechanicId;
      if (creditAfter != null && mechanicId != null) {
        await (db.update(db.mechanics)..where((t) => t.id.equals(mechanicId)))
            .write(MechanicsCompanion(creditBalance: Value(creditAfter)));
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

      // `movements` is NOT written: the server writes the restore rows but the
      // response does not carry them, and inventing them locally is the
      // arithmetic ADR-0010 §3 forbids.
    });

    return ret;
  }

  // ── Reads — still Drift (#55 owns them) ───────────────────────────────────

  @override
  Future<List<ReturnWithItems>> getReturns() => drift.getReturns();
}
