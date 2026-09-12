// ApiSalesRepository — `POST /api/v1/sales`, then patch the Drift cache (#56, ADR-0010).
//
// The whole point of this class is what it does NOT do. `SalesRepository.saveSale`
// is a Drift transaction that pre-checks stock, decrements it, grants points and
// moves the customer/mechanic ledgers. Every one of those is now the server's job
// (`server/src/sales/sales.service.ts`), so calling the Drift service after a `201`
// would decrement the stock a second time, and pre-checking stock locally would
// refuse a bill the server would have taken — local stock is a cache, and a cache
// that vetoes the truth is worse than a stale one. So: send, then copy the
// server's answer into the local rows. ADR-0010 §3.
//
// Corollary, applied literally below: **no client-side arithmetic on a
// server-owned number.** `pointsGranted`, the new stock, the customer's points and
// spend, the mechanic's credit balance and the receipt number are all read off the
// response. Where the response does not carry a field, the local row is left
// STALE rather than reconstructed — an invented value is a second set of
// invariants that drifts silently, which is exactly what the ADR bans.
//
// Fields the server owns and does NOT hand back (all three are flagged in the #56
// report, none of them are guessed here):
//   • `sales.shiftId` — `CreateSaleResult` carries no `shiftId` even though the
//     server stamps one on the row. Left null; a `GET /sales` refresh (#55) is the
//     only honest way to fill it.
//   • `saleItems.costAtSale` — the response carries no cost. `products.cost` here
//     is a cache and moves on every PO receive (ADR-0008), so writing it would
//     fabricate the bill's profit. Left null, which `tables.dart` already defines
//     as "estimated, never backfill".
//   • `movements` — the server writes the movement rows but does not return them.
//     Nothing is synthesised; the local movements table simply does not see this
//     bill until a read slice fetches it.

import 'package:drift/drift.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/ids.dart';
import '../../../domain/models/aggregates.dart';
import '../../db/database.dart';
import '../sales_repository.dart';
import 'api_wire.dart';

class ApiSalesRepository implements SalesRepository {
  ApiSalesRepository({
    required this.api,
    required this.db,
    required this.drift,
  });

  final ApiClient api;

  /// Used ONLY for plain row patches. Never `db.transaction` around the network
  /// call, and never a Drift transactional service.
  @override
  final AppDatabase db;

  /// Reads stay on Drift until the read slice (#55) replaces them.
  final SalesRepository drift;

  /// The bill id + `Idempotency-Key` of an attempt that never got a verdict,
  /// keyed by the cart it was for. See [_attemptFor] — this is what stops a
  /// cashier's second press after a timeout from becoming a second bill.
  final Map<String, _Attempt> _unresolved = {};

  @override
  Future<SaleRow> saveSale(SaleInput input) {
    return rethrowThai(() async {
      final attempt = _attemptFor(input);
      final body = _saleBody(attempt.saleId, input);

      final Map<String, dynamic> res;
      try {
        res = await _post(body, attempt.headers);
      } on ApiException {
        // The server reached a verdict, so this attempt is closed: a 409 for
        // insufficient stock or a credit limit is an answer, and the next press
        // is a NEW bill that must not replay this one's id.
        _unresolved.remove(attempt.cartKey);
        rethrow;
      }
      // Anything else — a dropped socket, a timeout — left the bill's fate
      // unknown, so the attempt stays parked for the retry (see [_attemptFor]).

      _unresolved.remove(attempt.cartKey);
      return _patchFromResponse(attempt.saleId, input, res);
    });
  }

  /// The bill id and `Idempotency-Key` this cart should be sent under.
  ///
  /// 🔴 Both are minted ONCE PER CART, not once per call, and that is the whole
  /// point. `ApiClient` sets no timeout and the shop's link is not reliable, so
  /// the ordinary failure is: `POST /sales` hangs or the socket drops, the
  /// counter sees `ขายไม่สำเร็จ…` and presses ยืนยัน again. The server may well
  /// have committed the first bill — the reply is what was lost, not the write.
  /// Minting a fresh id and a fresh key on the second press defeats BOTH of the
  /// server's defences at once (`existingSale` keys on the client's bill id,
  /// `idempotency_keys` on the header), so the customer is charged twice and the
  /// stock leaves twice for goods that left the shop once. Re-sending the same
  /// pair makes the second press replay the first bill, which is #56 AC2 and the
  /// reason `POST /sales` takes a client-generated id at all.
  ///
  /// The cart is fingerprinted rather than held by identity because
  /// `checkout_screen.dart` rebuilds a fresh `SaleInput` on every press.
  _Attempt _attemptFor(SaleInput input) {
    final key = _cartKey(input);
    return _unresolved[key] ??= _Attempt(
      cartKey: key,
      saleId: newId('s'),
      headers: idempotencyKey(),
    );
  }

  /// Identifies "the same cart, sent again": the money, who it is for, and every
  /// line. Two genuinely different bills that happen to match on all of this are
  /// indistinguishable from a retry — and the counter ringing the identical cart
  /// up twice in a row, for the same customer and mechanic, is far likelier to
  /// be a retry than a real second sale. The entry is dropped the moment the
  /// server answers, so this only ever spans one unresolved attempt.
  String _cartKey(SaleInput input) => [
    wireMoney(input.subtotal),
    wireMoney(input.discount),
    wireMoney(input.total),
    input.paymentMethod,
    input.customerId ?? '',
    input.mechanicId ?? '',
    input.mechanicDelta == null ? '' : wireMoney(input.mechanicDelta!),
    input.overrideCreditLimit,
    for (final i in input.items) '${i.productId}x${i.qty}@${wireMoney(i.price)}',
  ].join('|');

  Future<Map<String, dynamic>> _post(
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async {
    final res = await api.post('/api/v1/sales', body: body, headers: headers);
    return (res as Map).cast<String, dynamic>();
  }

  /// Exactly the fields `parseCreateSale` reads. `receiptNo`, `shiftId` and
  /// anything naming a tenant or a device are deliberately absent: phase 1
  /// issues every document number server-side (ADR-0007) and the device comes
  /// from the token (ADR-0004), so sending them is at best ignored.
  Map<String, dynamic> _saleBody(String saleId, SaleInput input) => {
    'id': saleId,
    // Money crosses as a two-decimal string — see api_wire.dart.
    'subtotal': wireMoney(input.subtotal),
    'discount': wireMoney(input.discount),
    'total': wireMoney(input.total),
    'paymentMethod': input.paymentMethod,
    'customerId': input.customerId,
    'customerName': input.customerName,
    'mechanicId': input.mechanicId,
    'mechanicName': input.mechanicName,
    'mechanicDelta': input.mechanicDelta == null
        ? null
        : wireMoney(input.mechanicDelta!),
    // The counter's own answer to 'ยืนยันขายเครดิต?', carried — never
    // re-derived from the cached mechanic row. See `SaleInput.overrideCreditLimit`.
    'overrideCreditLimit': input.overrideCreditLimit,
    'items': [
      for (var i = 0; i < input.items.length; i++)
        {
          // 1-based and unique: `lineNo` is part of the line's primary key on the
          // server and the order the receipt prints in, and a repeat is a 400.
          'lineNo': i + 1,
          'productId': input.items[i].productId,
          'partNo': input.items[i].partNo,
          'name': input.items[i].name,
          'nameTH': input.items[i].nameTH,
          'qty': input.items[i].qty,
          'price': wireMoney(input.items[i].price),
        },
    ],
  };

  /// Copies the server's answer into the cache. One Drift transaction so a
  /// half-patched cache is impossible — note this wraps only local writes, the
  /// network call is already done.
  Future<SaleRow> _patchFromResponse(
    String saleId,
    SaleInput input,
    Map<String, dynamic> res,
  ) async {
    final sale = SaleRow(
      id: res['id'] as String? ?? saleId,
      // Server's, always (ADR-0007). `checkout_screen.dart` prints this.
      receiptNo: res['receiptNo'] as String,
      // The bill's own three totals are the client's numbers, stored verbatim by
      // the server within its one-satang tolerance (`assertTotals`); only `total`
      // is echoed, so subtotal/discount come back from the input they were sent as.
      subtotal: input.subtotal,
      discount: input.discount,
      total: money(res['total']),
      paymentMethod: input.paymentMethod,
      customerId: input.customerId,
      customerName: input.customerName,
      mechanicId: input.mechanicId,
      mechanicName: input.mechanicName,
      mechanicDelta: input.mechanicDelta,
      // Server's floor(total/10) — never recomputed here, or a rounding
      // difference silently shows the customer a points balance the shop's
      // books disagree with.
      pointsGranted: res['pointsGranted'] as int,
      date: stamp(res['date']),
      voided: false,
      voidedAt: null,
      // 🔴 `CreateSaleResult` does not carry `shiftId`, although the server DOES
      // stamp one on the row it just wrote. Left null rather than guessed from
      // the local open shift: the drawer the server used is the one bound to the
      // device token, and a locally-chosen shift would mis-file the bill in the
      // closing report. Flagged as a spec-vs-server gap in #56.
      shiftId: null,
    );

    await db.transaction(() async {
      await db.into(db.sales).insert(sale);

      // Lines after the header: `SaleItems.saleId` is a real FK.
      await db.batch((b) {
        for (final item in input.items) {
          b.insert(
            db.saleItems,
            SaleItemsCompanion.insert(
              saleId: sale.id,
              productId: item.productId,
              partNo: Value(item.partNo),
              name: item.name,
              nameTH: Value(item.nameTH),
              qty: item.qty,
              price: item.price,
              // 🔴 Null on purpose. The response carries no cost, and the local
              // `products.cost` is a cache that moves on every weighted-average
              // PO receive (ADR-0008) — writing it would invent this bill's
              // profit. `tables.dart` already defines null here as "estimated,
              // never backfill".
              costAtSale: const Value(null),
            ),
          );
        }
      });

      // Stock: the server's post-deduction number, not `old - qty`.
      for (final p in (res['products'] as List? ?? const [])) {
        final row = (p as Map).cast<String, dynamic>();
        await (db.update(
          db.products,
        )..where((t) => t.id.equals(row['id'] as String))).write(
          // 🔴 Deliberately NOT `.stamped`. `products.updatedAt` is the cursor
          // `?updatedSince=` (#55) will page from, and this response carries no
          // `updatedAt` of its own. Stamping it with the local clock pushes the
          // cursor PAST server-side changes made in between, which lose rows
          // permanently; leaving it behind at worst re-fetches this row and
          // corrects it. A cursor that over-reads is recoverable, one that
          // skips is not. This contradicts `product_stamp.dart`'s "every product
          // write moves updatedAt" — flagged in #56 as a reviewer decision.
          ProductsCompanion(stock: Value(row['stock'] as int)),
        );
      }

      // Customer: points and spend AS THE SERVER HAS THEM.
      final customerAfter = res['customerAfter'];
      if (customerAfter is Map) {
        final c = customerAfter.cast<String, dynamic>();
        await (db.update(
          db.customers,
        )..where((t) => t.id.equals(c['id'] as String))).write(
          CustomersCompanion(
            points: Value(c['points'] as int),
            totalSpend: Value(money(c['totalSpend'])),
            // Same reasoning as products above: this is a sync cursor field and
            // the response has none, so it is not touched.
          ),
        );
      }

      // Mechanic: only the credit balance comes back. `totalSales`,
      // `totalDiscount` and `totalMarkup` are moved by the server too but are
      // NOT in `CreateSaleResult`, so those three columns go stale here rather
      // than being recomputed locally. Flagged in #56.
      final creditAfter = moneyOrNull(res['mechanicCreditBalanceAfter']);
      if (creditAfter != null && input.mechanicId != null) {
        await (db.update(db.mechanics)
              ..where((t) => t.id.equals(input.mechanicId!)))
            .write(MechanicsCompanion(creditBalance: Value(creditAfter)));
      }

      // `movements` is NOT written. The server writes the rows; the response
      // does not carry them, and synthesising `{delta, stockAfter, type}` here
      // would be exactly the local arithmetic ADR-0010 §3 forbids.
    });

    return sale;
  }

  // ── Reads — still Drift ────────────────────────────────────────────────────
  // `GET /sales` and friends belong to the read slice (#55), not this one. They
  // delegate so the screens keep working against the cache unchanged.

  @override
  Future<List<SaleWithItems>> getSales() => drift.getSales();

  @override
  Stream<List<SaleWithItems>> watchSales() => drift.watchSales();

  @override
  Future<Map<String, int>> getRefundedQty(String saleId) =>
      drift.getRefundedQty(saleId);
}

/// One unresolved `POST /sales`: the bill id and header it was sent under, kept
/// until the server answers so a retry can replay it rather than open a second
/// bill.
class _Attempt {
  const _Attempt({
    required this.cartKey,
    required this.saleId,
    required this.headers,
  });

  final String cartKey;
  final String saleId;
  final Map<String, String> headers;
}
