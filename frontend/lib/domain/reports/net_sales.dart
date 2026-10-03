// net_sales.dart — the one set of sales-report rules the app uses, the
// client side of the server's `reports.service.ts` (`COUNTED_SALE`,
// `grossProfitCtes`): a manual void is excluded, an auto-void (a bill with a
// credit note) stays counted and its credit notes subtract.
//
// Pure functions only (no Flutter, no repositories), shared by the closing
// report, the cash-drawer screen, the reports screen and products_screen.dart's
// inventory reports. Moved out of `closing_report.dart` once it served more
// than that one widget (#569 follow-up).

import '../../data/db/database.dart';
import '../models/aggregates.dart';

/// A flattened sale + items (with cost looked up) used by the report math.
/// Public (no leading underscore) so [computeGrossProfit] is unit-testable
/// from `test/` without a widget pump.
class SaleLite {
  /// The bill's id — matched against [ReturnLite.saleId] to tell a manual
  /// void from a return's auto-void ([countedSales]).
  final String id;
  final double subtotal;
  final double discount;
  final double total;
  final String paymentMethod;
  final bool voided;
  final List<ItemLite> items;
  const SaleLite({
    this.id = '',
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethod,
    this.voided = false,
    required this.items,
  });
}

/// A flattened credit note (return) for the report math. Its [items] carry the
/// cost of the ORIGINAL sale line ([ItemLite.costAtSale]) — `ReturnItems` has
/// no cost column of its own, unlike the server's `return_items.cost_at_sale`
/// (#22), which is copied from that same bill line.
class ReturnLite {
  final String saleId;
  final double refundTotal;
  final String refundMethod;
  final List<ItemLite> items;
  const ReturnLite({
    required this.saleId,
    required this.refundTotal,
    required this.refundMethod,
    required this.items,
  });
}

class ItemLite {
  final String partNo;
  final String name;
  final int qty;
  final double price;

  /// Cost recorded on the bill itself at the time of sale (ADR-0008,
  /// `SaleItems.costAtSale` in `data/db/tables.dart`). Null on a legacy bill
  /// sold before that column existed.
  final double? costAtSale;

  /// Today's `products.cost` for the same part, looked up as a fallback only
  /// — it drifts on every weighted-average PO receive, so it is never
  /// preferred over [costAtSale]. Null when the product row is gone too.
  final double? currentCost;
  const ItemLite({
    required this.partNo,
    required this.name,
    required this.qty,
    required this.price,
    required this.costAtSale,
    required this.currentCost,
  });
}

/// Result of [computeGrossProfit]: the profit figure plus how much of it is a
/// guess (ADR-0008) — mirrors `estimatedCostRows`/`unknownCostRows` in
/// `server/src/reports/reports.service.ts`.
class GrossProfitResult {
  final double profit;

  /// Lines with no `costAtSale`, costed at today's product cost instead.
  final int estimatedCostLines;

  /// Lines with no `costAtSale` AND no current product cost — costed at 0
  /// (profit reads higher than true; flagged via [costDisclosureLines]
  /// rather than excluded from the cost side).
  final int unknownCostLines;

  /// Σ sale-line qty × cost − Σ credit-note-line qty × cost.
  final double cost;
  const GrossProfitResult(
    this.profit,
    this.estimatedCostLines,
    this.unknownCostLines, {
    this.cost = 0,
  });
}

/// Approximate gross profit — the server's `grossProfitCtes`
/// (`reports.service.ts`), term for term:
///
///   (Σ sale.total − Σ return.refundTotal) ÷ (1 + taxRate/100)
///   − Σ sale-line qty × cost + Σ return-line qty × cost
///
/// [sales] must already be the counted bills ([countedSales]); [returns] are
/// the credit notes of the same period. `sale.total` is after the bill
/// discount and `refundTotal` carries the proportional share of it, so a
/// discounted bill with a partial return nets correctly. Cost per line is
/// `COALESCE(costAtSale, currentCost, 0)`: `costAtSale` (ADR-0008) first,
/// because `products.cost` is recomputed on every weighted-average PO receive
/// and would make a past bill's profit drift; a line with neither is costed at
/// 0 and disclosed via [costDisclosureLines]. Return lines count towards the
/// disclosure too, as the server counts every `gp_lines` row.
GrossProfitResult computeGrossProfit(
  List<SaleLite> sales,
  double taxRate, [
  List<ReturnLite> returns = const [],
]) {
  final vatDivisor = 1 + taxRate / 100;
  var estimatedCostLines = 0;
  var unknownCostLines = 0;
  double lineCost(ItemLite i) {
    if (i.costAtSale != null) return i.costAtSale! * i.qty;
    if (i.currentCost != null) {
      estimatedCostLines++;
      return i.currentCost! * i.qty;
    }
    unknownCostLines++;
    return 0;
  }

  var revenue = 0.0;
  var cost = 0.0;
  for (final s in sales) {
    revenue += s.total;
    for (final i in s.items) {
      cost += lineCost(i);
    }
  }
  for (final r in returns) {
    revenue -= r.refundTotal;
    for (final i in r.items) {
      cost -= lineCost(i);
    }
  }
  return GrossProfitResult(
    revenue / vatDivisor - cost,
    estimatedCostLines,
    unknownCostLines,
    cost: cost,
  );
}

/// The bills that still count as money taken and goods sold — the server's
/// `COUNTED_SALE`. A **manual** void undoes the bill outright, so it is
/// dropped. An **auto**-void is what a return of the last unit does; that bill
/// stays and its credit notes subtract (dropping it too would take the refund
/// off twice). The two are separable because the server refuses a manual void
/// once a return exists (`SALE_HAS_RETURNS`): a voided bill is an auto-void
/// exactly when it has a credit note.
///
/// [returns] must reach from the start of [sales]' period up to NOW: an
/// auto-void happens at its return's time, so that credit note is always
/// inside such a window (both callers pass the current day/month for both
/// lists). A past period that ends before now would need the bill's returns
/// looked up separately, or it would read an auto-void as a manual one.
List<SaleLite> countedSales(List<SaleLite> sales, List<ReturnLite> returns) {
  final returned = {for (final r in returns) r.saleId};
  return sales.where((s) => _counts(s.voided, s.id, returned)).toList();
}

/// The `COUNTED_SALE` test itself: not voided, or voided by a return
/// ([returnedSaleIds] holds the bills that have a credit note).
bool _counts(bool voided, String saleId, Set<String> returnedSaleIds) =>
    !voided || returnedSaleIds.contains(saleId);

/// Bills and net money of one payment-method row.
class PaymentGroup {
  /// Counted bills paid this way (a fully returned bill still counts).
  final int bills;

  /// Those bills' totals minus the period's refunds paid back this way.
  final double net;
  const PaymentGroup(this.bills, this.net);
}

/// One row of "สินค้าขายดี", net of returned quantity.
class TopItem {
  final String name;
  final int qty;
  final double revenue;

  /// The part the row is keyed by ([ItemLite.partNo]).
  final String partNo;
  const TopItem(this.name, this.qty, this.revenue, {this.partNo = ''});
}

/// Revenue, bills, payment rows, top items and profit for one period, net of
/// the period's credit notes. Credit notes are taken by their own date, like
/// the server's `/reports/summary`: a part sold yesterday and returned today
/// reduces today.
class NetSales {
  /// [countedSales] of the input — manual voids dropped.
  final List<SaleLite> counted;

  /// Σ counted bill totals − Σ refunds.
  final double netRevenue;
  final PaymentGroup cash;
  final PaymentGroup qr;
  final PaymentGroup credit;

  /// Every part with a positive net quantity, highest net revenue first.
  final List<TopItem> topItems;

  /// Σ counted sale-line qty − Σ credit-note-line qty — the server's
  /// `totalItems` (`gp_lines`). Can be negative in a period with only returns.
  final int netItems;

  final List<ReturnLite> _returns;
  final double? _taxRate;

  NetSales._(
    this.counted,
    this.netRevenue,
    this.cash,
    this.qr,
    this.credit,
    this.topItems,
    this.netItems,
    this._returns,
    this._taxRate,
  );

  /// Gross profit ([computeGrossProfit]) over [counted] and the credit notes.
  /// Needs the `taxRate` passed to [NetSales.of]; a screen that shows no
  /// profit (the reports screen) may leave it out and must not read this.
  late final GrossProfitResult profit = computeGrossProfit(
    counted,
    _taxRate ?? (throw StateError('NetSales.of was given no taxRate')),
    _returns,
  );

  /// Bills counted like the server's `totalTransactions`: an auto-voided
  /// (fully returned) bill still counts, a manual void does not.
  int get billCount => counted.length;

  /// Net revenue per counted bill (0 with no bills) — the same definition as
  /// the server's `avgTicket` (`/reports/summary`, owner decision 2026-10-03),
  /// so a fully returned bill reads ฿0/bill next to ฿0 revenue on both sides.
  /// Callers round it to whole baht, as the server does.
  double get avgPerBill => counted.isEmpty ? 0 : netRevenue / counted.length;

  factory NetSales.of(
    List<SaleLite> sales,
    List<ReturnLite> returns, [
    double? taxRate,
  ]) {
    final counted = countedSales(sales, returns);
    double sumTotal(List<SaleLite> l) => l.fold(0, (a, s) => a + s.total);
    double refunds(bool Function(String) method) => returns
        .where((r) => method(r.refundMethod))
        .fold(0, (a, r) => a + r.refundTotal);
    PaymentGroup group(List<SaleLite> l, bool Function(String) method) =>
        PaymentGroup(l.length, sumTotal(l) - refunds(method));

    final top = <String, TopItem>{};
    var netItems = 0;
    void addLine(ItemLite i, int sign) {
      final cur = top[i.partNo] ?? TopItem(i.name, 0, 0, partNo: i.partNo);
      top[i.partNo] = TopItem(
        cur.name,
        cur.qty + sign * i.qty,
        cur.revenue + sign * i.qty * i.price,
        partNo: i.partNo,
      );
      netItems += sign * i.qty;
    }

    for (final s in counted) {
      for (final i in s.items) {
        addLine(i, 1);
      }
    }
    for (final r in returns) {
      for (final i in r.items) {
        addLine(i, -1);
      }
    }
    final topItems = top.values.where((t) => t.qty > 0).toList()
      ..sort((a, b) => b.revenue.compareTo(a.revenue));

    return NetSales._(
      counted,
      sumTotal(counted) - refunds((_) => true),
      group(cashSales(counted), _isCashRefund),
      group(qrSales(counted), _isQrRefund),
      group(creditSales(counted), _isCreditRefund),
      topItems,
      netItems,
      returns,
      taxRate,
    );
  }
}

// Refund methods offered by returns_screen.dart: 'เงินสด' | 'โอน' |
// 'หักจากเครดิต' (aggregates.dart). 'โอน' is in [_isTransfer] with the
// sale-side spellings, so one list drives both sides of the โอน/QR row.
bool _isCashRefund(String m) => m == 'เงินสด';
bool _isQrRefund(String m) => _isTransfer(m);
bool _isCreditRefund(String m) => m == 'หักจากเครดิต';

/// Flattens repository rows into [SaleLite]/[ReturnLite] for [NetSales].
///
/// A return line takes `partNo`, name and `costAtSale` from its original sale
/// line — the first line of that bill with the same product and price, else
/// the same product (the server's `return_events` match) — looked up in
/// [sales] and [originalSales] (bills outside the period that the period's
/// credit notes refer to). `currentCost` is today's product cost, the
/// fallback only.
({List<SaleLite> sales, List<ReturnLite> returns}) toReportLites({
  required List<SaleWithItems> sales,
  required List<ReturnWithItems> returns,
  required List<ProductRow> products,
  List<SaleWithItems> originalSales = const [],
}) {
  final costByPart = {for (final p in products) p.partNo: p.cost};
  final productById = {for (final p in products) p.id: p};
  final linesBySale = {
    for (final s in originalSales) s.sale.id: s.items,
    for (final s in sales) s.sale.id: s.items,
  };
  ItemLite returnLine(String saleId, ReturnItemRow i) {
    final lines = linesBySale[saleId] ?? const <SaleItemRow>[];
    final line =
        lines
            .where((l) => l.productId == i.productId && l.price == i.price)
            .firstOrNull ??
        lines.where((l) => l.productId == i.productId).firstOrNull;
    return ItemLite(
      partNo: line?.partNo ?? productById[i.productId]?.partNo ?? '',
      name: line?.name ?? i.name,
      qty: i.qty,
      price: i.price,
      costAtSale: line?.costAtSale,
      currentCost: productById[i.productId]?.cost,
    );
  }

  return (
    sales: [
      for (final s in sales)
        SaleLite(
          id: s.sale.id,
          subtotal: s.sale.subtotal,
          discount: s.sale.discount,
          total: s.sale.total,
          paymentMethod: s.sale.paymentMethod,
          voided: s.sale.voided,
          items: [
            for (final i in s.items)
              ItemLite(
                partNo: i.partNo ?? '',
                name: i.name,
                qty: i.qty,
                price: i.price,
                costAtSale: i.costAtSale,
                currentCost: costByPart[i.partNo],
              ),
          ],
        ),
    ],
    returns: [
      for (final r in returns)
        ReturnLite(
          saleId: r.ret.saleId,
          refundTotal: r.ret.refundTotal,
          refundMethod: r.ret.refundMethod,
          items: [for (final i in r.items) returnLine(r.ret.saleId, i)],
        ),
    ],
  );
}

/// Sales paid in cash — one of the three groups a `SaleLite` list is split
/// into for the "วิธีชำระเงิน" breakdown (#461). Extracted to a top-level pure
/// function (like [computeGrossProfit]) so the grouping is unit-testable
/// without a widget pump.
List<SaleLite> cashSales(List<SaleLite> sales) =>
    sales.where((s) => s.paymentMethod == 'เงินสด').toList();

/// Sales paid by transfer/QR. Three spellings are accepted because both the
/// current UI copy (`'โอน/QR'`) and older `db.js`-era values (`'PromptPay'`,
/// `'โอนเงิน'`) can appear on rows saved before a copy change. `'โอน'` is the
/// refund-side spelling (returns_screen.dart), shared via [_isTransfer].
List<SaleLite> qrSales(List<SaleLite> sales) =>
    sales.where((s) => _isTransfer(s.paymentMethod)).toList();

bool _isTransfer(String m) =>
    m == 'โอน/QR' || m == 'PromptPay' || m == 'โอนเงิน' || m == 'โอน';

/// Sales paid via `เครดิตช่าง` (mechanic credit) — settled later through
/// `CreditPayments`, never touching the cash drawer directly (only a cash
/// *settlement* of that credit does, tracked separately as
/// `cashCreditPaymentsToday`). Before #461 the payment-method breakdown only
/// showed [cashSales]/[qrSales], so a day with a เครดิตช่าง bill made those two
/// rows sum to less than `รวมทั้งหมด` (which totals every sale). This group
/// closes that gap.
List<SaleLite> creditSales(List<SaleLite> sales) =>
    sales.where((s) => s.paymentMethod == 'เครดิตช่าง').toList();

/// Legacy credit payments carried a `method` field (`'เงินสด'` | `'โอน/QR'`)
/// and only cash settlements counted toward the drawer. The Drift port has no
/// `method` column; MechanicsScreen instead encodes the method as the `note`
/// prefix (`'<method>'` or `'<method> · <note>'`). Treat a payment as cash only
/// when that leading segment is exactly `'เงินสด'`, mirroring `p.method === 'เงินสด'`.
bool isCashCreditPayment(String? note) {
  if (note == null) return false;
  final method = note.split(' · ').first.trim();
  return method == 'เงินสด';
}

/// "+ ยอดขายเงินสด" of the expected drawer cash — the ONE place both the
/// cash-drawer screen and the closing report's drawer check take it from
/// (#452: one counting window, `ShiftsRepository.cashCountFrom` → [from]).
///
/// Cash bills dated at or after [from], without manual voids: a manual void
/// hands the money back, so the bill is not in the drawer (the server's
/// `/reports/closing` `cash_sales` applies `COUNTED_SALE` too). An auto-voided
/// bill (one with a credit note) stays counted — its cash refund is already
/// subtracted as "− คืนเงินสด", so dropping the sale too would take it off
/// twice.
///
/// [returns] must cover the same window as [sales] up to now (both callers
/// read them from [from]): a bill's credit note always comes after the bill,
/// so it is inside that window.
double drawerCashSalesOf(
  List<SaleWithItems> sales,
  List<ReturnWithItems> returns, {
  required DateTime from,
}) {
  final returned = {for (final r in returns) r.ret.saleId};
  return sales
      .where(
        (s) =>
            s.sale.paymentMethod == 'เงินสด' &&
            !s.sale.date.isBefore(from) &&
            _counts(s.sale.voided, s.sale.id, returned),
      )
      .fold<double>(0, (sum, s) => sum + s.sale.total);
}
