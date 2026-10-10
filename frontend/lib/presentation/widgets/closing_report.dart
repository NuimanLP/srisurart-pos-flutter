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
import '../../data/repositories/payment_accounts_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/shifts_repository.dart';
import '../../domain/reports/net_sales.dart';
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

  /// The drawer check — [ShiftsRepository.drawerCash], the same number the
  /// cash-drawer screen shows and its cash-out refusal checks (by shift).
  final DrawerCash cash;
  final bool drawerToday;
  final String shopName;
  final String shopNameEN;
  final String? address;
  final String? phone;
  final String? cashierName;

  /// The โอน/QR row split by account ([qrAccountRows]).
  final List<QrAccountRow> qrAccounts;
  const _ClosingData({
    required this.net,
    required this.cash,
    required this.qrAccounts,
    required this.drawerToday,
    required this.shopName,
    required this.shopNameEN,
    required this.address,
    required this.phone,
    required this.cashierName,
  });

  double get drawerCashSales => cash.cashSales;
  double get cashRefundsToday => cash.cashRefunds;
  double get cashCreditPaymentsToday => cash.cashCreditPayments;
  double get drawerStarting => cash.startingCash;
  double get drawerIn => cash.totalIn;
  double get drawerOut => cash.totalOut;
}

/// One line of the โอน/QR breakdown under the closing report's QR row.
typedef QrAccountRow = ({String label, int bills, double net});

/// A bill whose account is no longer in the local cache (deleted).
const qrDeletedAccountLabel = 'บัญชีที่ลบแล้ว'; // เจ้าของรับรอง 2026-10-10 (contract §5)

/// A โอน/QR bill with no account recorded.
const qrNoAccountLabel = 'ไม่ระบุบัญชี'; // เจ้าของรับรอง 2026-10-10 (contract §5)

/// [NetSales.qrByAccount] as display rows: the shop's accounts in their own
/// order (by nickname), then every deleted account merged into one
/// [qrDeletedAccountLabel] row, then [qrNoAccountLabel]. Empty when there is
/// no โอน/QR money at all, so the report shows no breakdown.
List<QrAccountRow> qrAccountRows(
  Map<String?, PaymentGroup> byAccount,
  List<PaymentAccountRow> accounts,
) {
  final known = {for (final a in accounts) a.id};
  final rows = <QrAccountRow>[
    for (final a in accounts)
      if (byAccount[a.id] case final g?)
        (label: a.nickname, bills: g.bills, net: g.net),
  ];
  var deletedBills = 0;
  var deletedNet = 0.0;
  var anyDeleted = false;
  for (final e in byAccount.entries) {
    if (e.key == null || known.contains(e.key)) continue;
    anyDeleted = true;
    deletedBills += e.value.bills;
    deletedNet += e.value.net;
  }
  if (anyDeleted) {
    rows.add((label: qrDeletedAccountLabel, bills: deletedBills, net: deletedNet));
  }
  if (byAccount[null] case final g?) {
    rows.add((label: qrNoAccountLabel, bills: g.bills, net: g.net));
  }
  return rows;
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

Future<_ClosingData> _loadClosingData(BuildContext context) async {
  final salesRepo = context.read<SalesRepository>();
  final returnsRepo = context.read<ReturnsRepository>();
  final productsRepo = context.read<ProductsRepository>();
  final settingsRepo = context.read<SettingsRepository>();
  final shiftsRepo = context.read<ShiftsRepository>();
  final accountsRepo = context.read<PaymentAccountsRepository>();

  final now = DateTime.now();
  final today = dateKey(now);
  // Only today's bills/returns/credit payments are read (#417) — the same
  // rows the old `dateKey(x) == today` in-memory filters kept.
  final day = dayBounds(now);
  // The drawer check follows the current shift — still open past midnight
  // counts (owner 2026-10-04) — not the calendar day.
  final drawer = currentShiftOf(await shiftsRepo.getCashDrawer(), today);
  final drawerToday = drawer != null;
  final salesAgg = await salesRepo.getSales(from: day.from, to: day.to);
  // The day's credit notes for the whole-day sections (revenue, bills,
  // payment rows, top items, profit).
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
  final accounts = await accountsRepo.getAccounts();

  final lites = toReportLites(
    sales: salesAgg,
    returns: dayReturns,
    products: products,
    originalSales: originalSales,
  );

  // The drawer check is the current shift, counted by shift exactly as the
  // cash-drawer screen counts it (owner 2026-10-03). With no current shift
  // there is no drawer: money taken outside a shift belongs to none. Revenue,
  // the payment breakdown and top items above stay the whole day — DAILY report.
  final cash = drawer != null
      ? await shiftsRepo.drawerCash(drawer)
      : DrawerCash.empty;

  final net = NetSales.of(lites.sales, lites.returns, settings.taxRate);
  return _ClosingData(
    net: net,
    cash: cash,
    qrAccounts: qrAccountRows(net.qrByAccount, accounts),
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

  double _cashExpected(_ClosingData d) => d.cash.expected;

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
            for (final a in d.qrAccounts)
              row('    · ${a.label} (${a.bills} บิล)', baht(a.net)),
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
        for (final a in d.qrAccounts) _qrAccountRow(a),
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

  /// One indented account line under the โอน/QR row (owner 2026-10-10).
  Widget _qrAccountRow(QrAccountRow a) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(left: 20, top: 4, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '· ${a.label} '),
                      TextSpan(
                        text: '(${a.bills} บิล)',
                        style: TextStyle(
                          color: AppColors.steelBlue,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Text(
                baht(a.net),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.steelBlue,
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
