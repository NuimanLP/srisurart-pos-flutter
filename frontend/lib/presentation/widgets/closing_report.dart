// closing_report.dart — End-of-Day Closing Report dialog.
//
// Flutter port of pos/ClosingReport.jsx (the daily closing summary popup):
// revenue KPIs, payment-method breakdown, top items, and a cash-drawer
// discrepancy check (starting cash → expected vs physical → variance) plus a
// thermal print of the report. Thai UI strings are copied verbatim from the
// JSX source for behaviour parity.
//
// Shown as a dialog via [showClosingReport]. It reads sales/returns/credit-
// payments/settings/cash-drawer THROUGH the repo providers (never AppDatabase),
// computes the closing figures locally (mirroring db.js), and prints an 80mm
// receipt with the `printing` package.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../core/utils/pdf_fonts.dart';
import '../../data/db/database.dart';
import '../../data/repositories/mechanics_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/shifts_repository.dart';
import '../../domain/models/aggregates.dart';
import 'app_button.dart';

/// Opens the daily Closing Report as a modal dialog.
Future<void> showClosingReport(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
        child: const ClosingReport(),
      ),
    ),
  );
}

/// Aggregated read-model for the closing report (one async load of everything).
class _ClosingData {
  /// The whole day's bills net of the whole day's credit notes — revenue,
  /// bills, payment rows, top items and profit.
  final NetSales net;

  /// Cash bills since the drawer's count began ([ShiftsRepository.cashCountFrom])
  /// — the day's cash sales unless a later shift of the day is the drawer.
  final double drawerCashSales;
  final double cashRefundsToday;
  final double cashCreditPaymentsToday;
  final double drawerStarting;
  final double drawerIn;
  final double drawerOut;
  final bool drawerToday;
  final String shopName;
  final String shopNameEN;
  final String? address;
  final String? phone;
  final String? cashierName;
  const _ClosingData({
    required this.net,
    required this.drawerCashSales,
    required this.cashRefundsToday,
    required this.cashCreditPaymentsToday,
    required this.drawerStarting,
    required this.drawerIn,
    required this.drawerOut,
    required this.drawerToday,
    required this.shopName,
    required this.shopNameEN,
    required this.address,
    required this.phone,
    required this.cashierName,
  });
}

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
  return sales.where((s) => !s.voided || returned.contains(s.id)).toList();
}

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
  const TopItem(this.name, this.qty, this.revenue);
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
  final GrossProfitResult profit;

  const NetSales._(
    this.counted,
    this.netRevenue,
    this.cash,
    this.qr,
    this.credit,
    this.topItems,
    this.profit,
  );

  /// Bills counted like the server's `totalTransactions`: an auto-voided
  /// (fully returned) bill still counts, a manual void does not.
  int get billCount => counted.length;

  /// Net revenue per counted bill (0 with no bills). Deliberately NOT the
  /// server's `avgTicket`, which divides the gross (pre-refund) revenue: this
  /// report shows net revenue, so a fully returned bill must not read ฿150/bill
  /// next to ฿0 revenue.
  double get avgPerBill => counted.isEmpty ? 0 : netRevenue / counted.length;

  factory NetSales.of(
    List<SaleLite> sales,
    List<ReturnLite> returns,
    double taxRate,
  ) {
    final counted = countedSales(sales, returns);
    double sumTotal(List<SaleLite> l) => l.fold(0, (a, s) => a + s.total);
    double refunds(bool Function(String) method) => returns
        .where((r) => method(r.refundMethod))
        .fold(0, (a, r) => a + r.refundTotal);
    PaymentGroup group(List<SaleLite> l, bool Function(String) method) =>
        PaymentGroup(l.length, sumTotal(l) - refunds(method));

    final top = <String, TopItem>{};
    void addLine(ItemLite i, int sign) {
      final cur = top[i.partNo] ?? TopItem(i.name, 0, 0);
      top[i.partNo] = TopItem(
        cur.name,
        cur.qty + sign * i.qty,
        cur.revenue + sign * i.qty * i.price,
      );
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
      computeGrossProfit(counted, taxRate, returns),
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

/// Disclosure lines for [GrossProfitResult] — verbatim copy of the warning
/// `products_screen.dart`'s `_monthly` already shows under "Margin % เดือนนี้"
/// (reused, not invented, per CONTRACT.md's Thai-string-parity rule).
List<String> costDisclosureLines(GrossProfitResult r) => [
  if (r.estimatedCostLines > 0)
    '${r.estimatedCostLines} รายการคำนวณจากต้นทุนปัจจุบัน ไม่ใช่ ณ วันที่ขาย',
  if (r.unknownCostLines > 0)
    '${r.unknownCostLines} รายการไม่มีข้อมูลต้นทุน (กำไรจะสูงกว่าจริง)',
];

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

Future<_ClosingData> _loadClosingData(BuildContext context) async {
  final salesRepo = context.read<SalesRepository>();
  final returnsRepo = context.read<ReturnsRepository>();
  final mechanicsRepo = context.read<MechanicsRepository>();
  final productsRepo = context.read<ProductsRepository>();
  final settingsRepo = context.read<SettingsRepository>();
  final shiftsRepo = context.read<ShiftsRepository>();

  final now = DateTime.now();
  final today = dateKey(now);
  // Only today's bills/returns/credit payments are read (#417) — the same
  // rows the old `dateKey(x) == today` in-memory filters kept.
  final day = dayBounds(now);
  final drawer = await shiftsRepo.getCashDrawer();
  final drawerToday = drawer != null && drawer.shift.dateStr == today;
  // The drawer check counts from the same point as the cash-drawer screen
  // (08 §11, #452): midnight for the day's first shift, a later shift's own
  // opening otherwise. Revenue, the payment breakdown and top items stay the
  // whole day — this is the DAILY closing report.
  final countFrom = drawerToday
      ? (await shiftsRepo.cashCountFrom(drawer.shift) ?? day.from)
      : day.from;
  final salesAgg = await salesRepo.getSales(from: day.from, to: day.to);
  final returns = await returnsRepo.getReturns(from: countFrom, to: day.to);
  final creditPayments = await mechanicsRepo.getCreditPayments(
    from: countFrom,
    to: day.to,
  );
  // The day's credit notes for the whole-day sections (revenue, bills,
  // payment rows, top items, profit) — `returns` above is the drawer's window.
  final dayReturns = await returnsRepo.getReturns(from: day.from, to: day.to);
  final todaySaleIds = {for (final s in salesAgg) s.sale.id};
  // A credit note today may be for an earlier day's bill: load that bill too,
  // for its lines' costAtSale.
  final originalSales = await salesRepo.getSalesByIds(
    dayReturns
        .map((r) => r.ret.saleId)
        .where((id) => !todaySaleIds.contains(id)),
  );
  final products = await productsRepo.getAll();
  final settings = await settingsRepo.getSettings();

  final lites = toReportLites(
    sales: salesAgg,
    returns: dayReturns,
    products: products,
    originalSales: originalSales,
  );

  // Cash refunds today reduce the drawer.
  final cashRefundsToday = returns
      .where((r) => r.ret.refundMethod == 'เงินสด')
      .fold<double>(0, (s, r) => s + r.ret.refundTotal);

  // Cash credit-payments today increase the drawer. The JS filtered
  // p.method === 'เงินสด' so only cash settlements hit the drawer; transfers
  // (โอน/QR) must NOT. The Drift CreditPayments table has no `method` column,
  // but MechanicsScreen folds the chosen method into the `note` as
  // '<method>' or '<method> · <typed note>' (see mechanics_screen.dart). We
  // recover the method from that prefix and count only cash settlements,
  // matching ClosingReport.jsx (and keeping the drawer math consistent).
  final cashCreditPaymentsToday = creditPayments
      .where((p) => isCashCreditPayment(p.note))
      .fold<double>(0, (s, p) => s + p.amount);

  // Cash bills in the drawer's window — the "+ ยอดขายเงินสด" of the check.
  final drawerCashSales = salesAgg
      .where(
        (s) =>
            s.sale.paymentMethod == 'เงินสด' &&
            !s.sale.date.isBefore(countFrom),
      )
      .fold<double>(0, (sum, s) => sum + s.sale.total);

  final drawerStarting = drawerToday ? drawer.shift.startingCash : 0.0;
  final drawerOut = drawerToday
      ? drawer.entries
            .where((e) => e.type == 'out')
            .fold<double>(0, (s, e) => s + e.amount)
      : 0.0;
  final drawerIn = drawerToday
      ? drawer.entries
            .where((e) => e.type == 'in')
            .fold<double>(0, (s, e) => s + e.amount)
      : 0.0;

  return _ClosingData(
    net: NetSales.of(lites.sales, lites.returns, settings.taxRate),
    drawerCashSales: drawerCashSales,
    cashRefundsToday: cashRefundsToday,
    cashCreditPaymentsToday: cashCreditPaymentsToday,
    drawerStarting: drawerStarting,
    drawerIn: drawerIn,
    drawerOut: drawerOut,
    drawerToday: drawerToday,
    shopName: settings.shopName,
    shopNameEN: settings.shopNameEN,
    address: settings.address,
    phone: settings.phone,
    cashierName: settings.cashierName,
  );
}

class ClosingReport extends StatefulWidget {
  const ClosingReport({super.key});

  @override
  State<ClosingReport> createState() => _ClosingReportState();
}

class _ClosingReportState extends State<ClosingReport> {
  final _cashCtl = TextEditingController();
  final _cashierCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  bool _cashierInit = false;
  bool _printed = false;
  bool _busy = false;
  // Created in initState — never inline in build.
  late Future<_ClosingData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadClosingData(context);
  }

  @override
  void dispose() {
    _cashCtl.dispose();
    _cashierCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  // ── Closing math (ports ClosingReport.jsx, net of credit notes) ─────────
  List<TopItem> _topItems(_ClosingData d) => d.net.topItems.take(5).toList();

  double _cashExpected(_ClosingData d) {
    return d.drawerStarting +
        d.drawerCashSales +
        d.cashCreditPaymentsToday -
        d.cashRefundsToday -
        d.drawerOut +
        d.drawerIn;
  }

  double _cashActual() => double.tryParse(_cashCtl.text) ?? 0;

  Future<void> _print(_ClosingData d) async {
    setState(() => _busy = true);
    try {
      // Thai glyphs require a Thai-capable font (helvetica has none). Match the
      // receipt_view pattern: bundled Sarabun asset, loaded async (#271 — was
      // PdfGoogleFonts, which fetched over the network).
      final font = await PosPdfFonts.sarabunRegular();
      final fontB = await PosPdfFonts.sarabunBold();
      final doc = _buildPdf(d, font, fontB);
      await Printing.layoutPdf(onLayout: (_) async => doc.save());
      if (mounted) setState(() => _printed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  pw.Document _buildPdf(_ClosingData d, pw.Font font, pw.Font fontB) {
    final doc = pw.Document();
    final now = DateTime.now();
    final totalRevenue = d.net.netRevenue;
    final cash = d.net.cash;
    final qr = d.net.qr;
    final credit = d.net.credit;
    final profitResult = d.net.profit;
    final grossProfit = profitResult.profit;
    final topItems = _topItems(d);
    final cashExpected = _cashExpected(d);
    final cashActual = _cashActual();
    final diff = cashActual - cashExpected;
    final cashierName = _cashierCtl.text.isEmpty
        ? 'แคชเชียร์'
        : _cashierCtl.text;
    final note = _noteCtl.text;

    final navy = const PdfColor.fromInt(0xFF0B2444);

    pw.Widget row(String l, String r, {bool big = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            l,
            style: pw.TextStyle(
              fontSize: big ? 11 : 9,
              fontWeight: big ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
          pw.Text(
            r,
            style: pw.TextStyle(
              fontSize: big ? 11 : 9,
              fontWeight: big ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ],
      ),
    );
    pw.Widget divider() => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Divider(height: 1, thickness: 0.5),
    );
    pw.Widget sectionTitle(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Text(
        t.toUpperCase(),
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.grey700,
        ),
      ),
    );

    final diffLabel = diff == 0
        ? '✓ ตรงยอด'
        : diff > 0
        ? 'เงินเกิน +${baht(diff.abs())}'
        : 'เงินขาด −${baht(diff.abs())}';

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80.copyWith(
          marginTop: 8,
          marginBottom: 8,
          marginLeft: 8,
          marginRight: 8,
        ),
        theme: pw.ThemeData.withFont(base: font, bold: fontB),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Center(
              child: pw.Text(
                d.shopName,
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                  color: navy,
                ),
              ),
            ),
            pw.Center(
              child: pw.Text(
                '${d.shopNameEN} · ${d.address ?? ''}',
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey700,
                ),
              ),
            ),
            if ((d.phone ?? '').isNotEmpty)
              pw.Center(
                child: pw.Text(
                  d.phone!,
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                  ),
                ),
              ),
            pw.SizedBox(height: 6),
            pw.Container(
              color: navy,
              padding: const pw.EdgeInsets.all(4),
              child: pw.Center(
                child: pw.Text(
                  'สรุปยอดประจำวัน · Daily Closing',
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.white,
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 6),
            row('วันที่', _thaiDateLong(now)),
            row('ปิดร้านเวลา', '${_hhmm(now)} น.'),
            row('แคชเชียร์', cashierName),
            divider(),
            row('รายได้รวม', baht(totalRevenue)),
            row('จำนวนบิล', '${d.net.billCount}'),
            row('เฉลี่ย/บิล', baht(d.net.avgPerBill.round())),
            row('กำไรประมาณ', baht(grossProfit.round())),
            for (final line in costDisclosureLines(profitResult))
              pw.Text(
                line,
                style: const pw.TextStyle(
                  fontSize: 7,
                  color: PdfColors.orange800,
                ),
              ),
            divider(),
            sectionTitle('แบ่งตามวิธีชำระเงิน'),
            row('💵 เงินสด (${cash.bills} บิล)', baht(cash.net)),
            row('📱 โอน/QR (${qr.bills} บิล)', baht(qr.net)),
            row('🔧 เครดิตช่าง (${credit.bills} บิล)', baht(credit.net)),
            row('รวมทั้งหมด', baht(totalRevenue), big: true),
            divider(),
            sectionTitle('ตรวจนับเงินสดในลิ้นชัก'),
            if (d.drawerToday) ...[
              row('เงินตั้งต้น', baht(d.drawerStarting)),
              row('+ ยอดขายเงินสด', baht(d.drawerCashSales)),
              if (d.cashCreditPaymentsToday > 0)
                row(
                  '+ รับชำระเครดิต (เงินสด)',
                  baht(d.cashCreditPaymentsToday),
                ),
              if (d.cashRefundsToday > 0)
                row('− คืนเงินสด', baht(d.cashRefundsToday)),
              if (d.drawerIn > 0)
                row('+ เงินเพิ่มระหว่างวัน', baht(d.drawerIn)),
              if (d.drawerOut > 0)
                row('− เงินออกระหว่างวัน', baht(d.drawerOut)),
            ],
            row('ยอดเงินสดที่ควรมี', baht(cashExpected)),
            row('นับจริงได้', baht(cashActual)),
            pw.Container(
              margin: const pw.EdgeInsets.symmetric(vertical: 4),
              padding: const pw.EdgeInsets.all(5),
              color: diff == 0
                  ? const PdfColor.fromInt(0xFFE8F5E9)
                  : diff > 0
                  ? const PdfColor.fromInt(0xFFFFF3E0)
                  : const PdfColor.fromInt(0xFFFCE4E4),
              child: pw.Center(
                child: pw.Text(
                  diffLabel,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: diff == 0
                        ? const PdfColor.fromInt(0xFF2E7D12)
                        : diff > 0
                        ? const PdfColor.fromInt(0xFFE65100)
                        : const PdfColor.fromInt(0xFFC0392B),
                  ),
                ),
              ),
            ),
            divider(),
            sectionTitle('สินค้าขายดีวันนี้ Top ${topItems.length}'),
            if (topItems.isEmpty)
              pw.Center(
                child: pw.Text(
                  'ยังไม่มียอดขายวันนี้',
                  style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey),
                ),
              ),
            for (var i = 0; i < topItems.length; i++)
              row(
                '${i + 1}. ${topItems[i].name}',
                '${baht(topItems[i].revenue)} (${topItems[i].qty} ชิ้น)',
              ),
            divider(),
            if (note.isNotEmpty) ...[
              sectionTitle('หมายเหตุ'),
              pw.Text(note, style: const pw.TextStyle(fontSize: 9)),
              divider(),
            ],
            pw.SizedBox(height: 24),
            pw.Center(
              child: pw.Text(
                'ลายมือชื่อแคชเชียร์ / Cashier Signature',
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey700,
                ),
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Center(
              child: pw.Text(
                'ลายมือชื่อผู้จัดการ / Manager Signature',
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey700,
                ),
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Center(
              child: pw.Text(
                'พิมพ์เมื่อ ${_thaiDateLong(now)} ${_hhmm(now)} · ${d.shopNameEN}',
                style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey),
              ),
            ),
          ],
        ),
      ),
    );
    return doc;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      children: [
        _Header(
          title: '📊 สรุปยอดปิดร้าน · Daily Closing Report',
          subtitle: '${_thaiDateLong(now)} · ปิดเวลา ${_hhmm(now)} น.',
          onClose: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: FutureBuilder<_ClosingData>(
            future: _dataFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('เกิดข้อผิดพลาด: ${snap.error}'));
              }
              final d = snap.data!;
              if (!_cashierInit) {
                _cashierCtl.text = d.cashierName ?? 'แคชเชียร์';
                _cashierInit = true;
              }
              return _body(context, d);
            },
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, _ClosingData d) {
    final totalRevenue = d.net.netRevenue;
    final cash = d.net.cash;
    final qr = d.net.qr;
    final credit = d.net.credit;
    final profitResult = d.net.profit;
    final grossProfit = profitResult.profit;
    final profitDisclosure = costDisclosureLines(profitResult);
    final topItems = _topItems(d);
    final cashExpected = _cashExpected(d);
    final cashActual = _cashActual();
    final diff = cashActual - cashExpected;
    final statColor = diff == 0
        ? AppColors.successLight
        : diff > 0
        ? AppColors.warning
        : AppColors.error;
    final statLabel = diff == 0
        ? '✓ ตรงยอด'
        : diff > 0
        ? 'เงินเกิน +${baht(diff.abs())}'
        : 'เงินขาด −${baht(diff.abs())}';

    final theme = Theme.of(context);

    // Two scrollable panes. Side-by-side on a wide dialog; stacked vertically on
    // a narrow (phone) dialog so neither the summary nor the fixed-width cash
    // form is crushed — the old fixed 320px right pane + Expanded left overflowed
    // below ~720px (reachable on phones via Cash Drawer's สรุปยอดปิดร้าน).
    final Widget summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kpiGrid([
          _Kpi('รายได้รวม', baht(totalRevenue), AppColors.orange),
          _Kpi('จำนวนบิล', '${d.net.billCount} บิล', null),
          _Kpi('เฉลี่ย/บิล', baht(d.net.avgPerBill.round()), null),
          _Kpi('กำไรประมาณ', baht(grossProfit.round()), AppColors.successLight),
        ]),
        if (profitDisclosure.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              profitDisclosure.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.warning,
              ),
            ),
          ),
        const SizedBox(height: 20),
        _SectionTitle('วิธีชำระเงิน'),
        _payRow('💵 เงินสด', cash.bills, cash.net, AppColors.orange),
        _payRow('📱 โอน/QR', qr.bills, qr.net, AppColors.steelBlue),
        _payRow('🔧 เครดิตช่าง', credit.bills, credit.net, AppColors.warning),
        Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.dividerColor, width: 2),
            ),
          ),
          padding: const EdgeInsets.only(top: 8),
          margin: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'รวมทั้งหมด',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                baht(totalRevenue),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.orange,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _SectionTitle('สินค้าขายดีวันนี้'),
        if (topItems.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'ยังไม่มีรายการวันนี้',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.steelBlue,
              ),
            ),
          ),
        for (var i = 0; i < topItems.length; i++)
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '#${i + 1}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.orange,
                          ),
                        ),
                      ),
                      Expanded(child: Text(topItems[i].name)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      baht(topItems[i].revenue),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.successLight,
                      ),
                    ),
                    Text(
                      '${topItems[i].qty} ชิ้น',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.steelBlue,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );

    final Widget cashForm = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('ข้อมูลแคชเชียร์'),
        _fieldLabel('ชื่อแคชเชียร์'),
        TextField(
          controller: _cashierCtl,
          decoration: const InputDecoration(isDense: true),
        ),
        const SizedBox(height: 20),
        _SectionTitle('ตรวจนับเงินสดในลิ้นชัก'),
        if (d.drawerToday) ...[
          if (d.drawerStarting > 0)
            _miniRow('เงินตั้งต้น', baht(d.drawerStarting), null),
          if (d.drawerCashSales > 0)
            _miniRow(
              '+ ยอดขายเงินสด',
              '+${baht(d.drawerCashSales)}',
              AppColors.successLight,
            ),
          if (d.cashCreditPaymentsToday > 0)
            _miniRow(
              '+ รับชำระเครดิต (เงินสด)',
              '+${baht(d.cashCreditPaymentsToday)}',
              AppColors.successLight,
            ),
          if (d.cashRefundsToday > 0)
            _miniRow(
              '− คืนเงินสด',
              '−${baht(d.cashRefundsToday)}',
              AppColors.error,
            ),
          if (d.drawerIn > 0)
            _miniRow(
              '+ เงินเพิ่มระหว่างวัน',
              '+${baht(d.drawerIn)}',
              AppColors.successLight,
            ),
          if (d.drawerOut > 0)
            _miniRow(
              '− เงินออกระหว่างวัน',
              '−${baht(d.drawerOut)}',
              AppColors.error,
            ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                'ยอดเงินสดที่ควรมี',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.steelBlue,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              baht(cashExpected),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _fieldLabel('นับเงินสดจริงได้ ฿'),
        TextField(
          controller: _cashCtl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
          onChanged: (_) => setState(() {}),
        ),
        if (_cashCtl.text.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: statColor.withValues(alpha: 0.12),
              border: Border.all(color: statColor, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Text(
                  'ผลต่าง',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statLabel,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: statColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        _SectionTitle('หมายเหตุ (ถ้ามี)'),
        TextField(
          controller: _noteCtl,
          maxLines: 3,
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'เช่น มีสินค้าเสียหาย, ปัญหาระบบ…',
          ),
        ),
        const SizedBox(height: 16),
        AppButton(
          label: '🖨 พิมพ์รายงานปิดร้าน',
          busy: _busy,
          fullWidth: true,
          onPressed: () => _print(d),
        ),
        if (_printed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '✓ ส่งรายงานไปยังหน้าต่างพิมพ์แล้ว',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.successLight,
              ),
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 720) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: summary,
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: cashForm,
                ),
              ),
            ],
          );
        }
        // Narrow (phone): stack the two panes in a single scroll view.
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              summary,
              const SizedBox(height: 24),
              const Divider(height: 1),
              const SizedBox(height: 24),
              cashForm,
            ],
          ),
        );
      },
    );
  }

  Widget _kpiGrid(List<_Kpi> kpis) {
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 92,
      ),
      children: kpis.map((k) => _kpiCard(k)).toList(),
    );
  }

  Widget _kpiCard(_Kpi k) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  k.value,
                  maxLines: 1,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: k.color ?? theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                k.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.steelBlue,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _payRow(String label, int count, double value, Color color) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$label '),
                    TextSpan(
                      text: '($count บิล)',
                      style: TextStyle(
                        color: AppColors.steelBlue,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                baht(value),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _miniRow(String label, String value, Color? color) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.steelBlue,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _fieldLabel(String text) => Builder(
    builder: (context) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.steelBlue,
          ),
        ),
      );
    },
  );
}

class _Kpi {
  final String label;
  final String value;
  final Color? color;
  const _Kpi(this.label, this.value, this.color);
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: AppColors.steelBlue,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onClose;
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.steelBlue,
                  ),
                ),
              ],
            ),
          ),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
        ],
      ),
    );
  }
}

// ── small date/time helpers (long Thai date used on header + print) ──────────
const _thMonths = [
  'มกราคม',
  'กุมภาพันธ์',
  'มีนาคม',
  'เมษายน',
  'พฤษภาคม',
  'มิถุนายน',
  'กรกฎาคม',
  'สิงหาคม',
  'กันยายน',
  'ตุลาคม',
  'พฤศจิกายน',
  'ธันวาคม',
];

String _thaiDateLong(DateTime d) =>
    '${d.day} ${_thMonths[d.month - 1]} ${d.year + 543}';

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
