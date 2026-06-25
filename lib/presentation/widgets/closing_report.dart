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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../providers/providers.dart';
import '../providers/shift_providers.dart';
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
  final List<_SaleLite> sales;
  final double cashRefundsToday;
  final double cashCreditPaymentsToday;
  final double drawerStarting;
  final double drawerIn;
  final double drawerOut;
  final bool drawerToday;
  final double taxRate;
  final String shopName;
  final String shopNameEN;
  final String? address;
  final String? phone;
  final String? cashierName;
  const _ClosingData({
    required this.sales,
    required this.cashRefundsToday,
    required this.cashCreditPaymentsToday,
    required this.drawerStarting,
    required this.drawerIn,
    required this.drawerOut,
    required this.drawerToday,
    required this.taxRate,
    required this.shopName,
    required this.shopNameEN,
    required this.address,
    required this.phone,
    required this.cashierName,
  });
}

/// A flattened sale + items (with cost looked up) used by the report math.
class _SaleLite {
  final double subtotal;
  final double discount;
  final double total;
  final String paymentMethod;
  final List<_ItemLite> items;
  const _SaleLite({
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethod,
    required this.items,
  });
}

class _ItemLite {
  final String partNo;
  final String name;
  final int qty;
  final double price;
  final double cost;
  const _ItemLite({
    required this.partNo,
    required this.name,
    required this.qty,
    required this.price,
    required this.cost,
  });
}

String _today() => DateTime.now().toIso8601String().substring(0, 10);

/// Legacy credit payments carried a `method` field (`'เงินสด'` | `'โอน/QR'`)
/// and only cash settlements counted toward the drawer. The Drift port has no
/// `method` column; MechanicsScreen instead encodes the method as the `note`
/// prefix (`'<method>'` or `'<method> · <note>'`). Treat a payment as cash only
/// when that leading segment is exactly `'เงินสด'`, mirroring `p.method === 'เงินสด'`.
bool _isCashCreditPayment(String? note) {
  if (note == null) return false;
  final method = note.split(' · ').first.trim();
  return method == 'เงินสด';
}

final _closingDataProvider = FutureProvider.autoDispose<_ClosingData>((
  ref,
) async {
  final today = _today();
  final salesAgg = await ref.watch(salesRepoProvider).getSales();
  final returns = await ref.watch(returnsRepoProvider).getReturns();
  final creditPayments = await ref
      .watch(mechanicsRepoProvider)
      .getCreditPayments();
  final products = await ref.watch(productsRepoProvider).getAll();
  final settings = await ref.watch(settingsRepoProvider).getSettings();
  final drawer = await ref.watch(shiftsRepoProvider).getCashDrawer();

  final costByPart = {for (final p in products) p.partNo: p.cost};

  final sales = <_SaleLite>[];
  for (final s in salesAgg) {
    final sale = s.sale;
    if (sale.date.toIso8601String().substring(0, 10) != today) continue;
    sales.add(
      _SaleLite(
        subtotal: sale.subtotal,
        discount: sale.discount,
        total: sale.total,
        paymentMethod: sale.paymentMethod,
        items: [
          for (final i in s.items)
            _ItemLite(
              partNo: i.partNo ?? '',
              name: i.name,
              qty: i.qty,
              price: i.price,
              cost: costByPart[i.partNo] ?? 0,
            ),
        ],
      ),
    );
  }

  // Cash refunds today reduce the drawer.
  final cashRefundsToday = returns
      .where(
        (r) =>
            r.ret.date.toIso8601String().substring(0, 10) == today &&
            r.ret.refundMethod == 'เงินสด',
      )
      .fold<double>(0, (s, r) => s + r.ret.refundTotal);

  // Cash credit-payments today increase the drawer. The JS filtered
  // p.method === 'เงินสด' so only cash settlements hit the drawer; transfers
  // (โอน/QR) must NOT. The Drift CreditPayments table has no `method` column,
  // but MechanicsScreen folds the chosen method into the `note` as
  // '<method>' or '<method> · <typed note>' (see mechanics_screen.dart). We
  // recover the method from that prefix and count only cash settlements,
  // matching ClosingReport.jsx (and keeping the drawer math consistent).
  final cashCreditPaymentsToday = creditPayments
      .where(
        (p) =>
            p.date.toIso8601String().substring(0, 10) == today &&
            _isCashCreditPayment(p.note),
      )
      .fold<double>(0, (s, p) => s + p.amount);

  final drawerToday = drawer != null && drawer.shift.dateStr == today;
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
    sales: sales,
    cashRefundsToday: cashRefundsToday,
    cashCreditPaymentsToday: cashCreditPaymentsToday,
    drawerStarting: drawerStarting,
    drawerIn: drawerIn,
    drawerOut: drawerOut,
    drawerToday: drawerToday,
    taxRate: settings.taxRate,
    shopName: settings.shopName,
    shopNameEN: settings.shopNameEN,
    address: settings.address,
    phone: settings.phone,
    cashierName: settings.cashierName,
  );
});

class ClosingReport extends ConsumerStatefulWidget {
  const ClosingReport({super.key});

  @override
  ConsumerState<ClosingReport> createState() => _ClosingReportState();
}

class _ClosingReportState extends ConsumerState<ClosingReport> {
  final _cashCtl = TextEditingController();
  final _cashierCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  bool _cashierInit = false;
  bool _printed = false;
  bool _busy = false;

  @override
  void dispose() {
    _cashCtl.dispose();
    _cashierCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  // ── Closing math (ports ClosingReport.jsx) ──────────────────────────────
  double _totalRevenue(_ClosingData d) =>
      d.sales.fold(0, (s, t) => s + t.total);

  List<_SaleLite> _cashSales(_ClosingData d) =>
      d.sales.where((s) => s.paymentMethod == 'เงินสด').toList();

  List<_SaleLite> _qrSales(_ClosingData d) => d.sales
      .where(
        (s) =>
            s.paymentMethod == 'โอน/QR' ||
            s.paymentMethod == 'PromptPay' ||
            s.paymentMethod == 'โอนเงิน',
      )
      .toList();

  double _sumTotal(List<_SaleLite> list) => list.fold(0, (s, t) => s + t.total);

  double _grossProfit(_ClosingData d) {
    final vatDivisor = 1 + d.taxRate / 100;
    return d.sales.fold<double>(0, (tot, sale) {
      final subtotal = sale.subtotal != 0
          ? sale.subtotal
          : sale.items.fold<double>(0, (a, i) => a + i.price * i.qty);
      final discountRatio = subtotal > 0 ? sale.discount / subtotal : 0.0;
      final itemProfit = sale.items.fold<double>(0, (a, i) {
        final lineRevenue = i.price * i.qty * (1 - discountRatio);
        return a + (lineRevenue / vatDivisor) - (i.cost * i.qty);
      });
      return tot + itemProfit;
    });
  }

  List<_TopItem> _topItems(_ClosingData d) {
    final map = <String, _TopItem>{};
    for (final t in d.sales) {
      for (final i in t.items) {
        final cur = map[i.partNo] ?? _TopItem(i.name, 0, 0);
        map[i.partNo] = _TopItem(
          cur.name,
          cur.qty + i.qty,
          cur.revenue + i.qty * i.price,
        );
      }
    }
    final list = map.values.toList()
      ..sort((a, b) => b.revenue.compareTo(a.revenue));
    return list.take(5).toList();
  }

  double _cashExpected(_ClosingData d) {
    final cashTotal = _sumTotal(_cashSales(d));
    return d.drawerStarting +
        cashTotal +
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
      // receipt_view pattern: Google Fonts Sarabun, loaded async.
      final font = await PdfGoogleFonts.sarabunRegular();
      final fontB = await PdfGoogleFonts.sarabunBold();
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
    final totalRevenue = _totalRevenue(d);
    final cashSales = _cashSales(d);
    final qrSales = _qrSales(d);
    final cashTotal = _sumTotal(cashSales);
    final qrTotal = _sumTotal(qrSales);
    final grossProfit = _grossProfit(d);
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
            row('จำนวนบิล', '${d.sales.length}'),
            row(
              'เฉลี่ย/บิล',
              baht(
                d.sales.isEmpty ? 0 : (totalRevenue / d.sales.length).round(),
              ),
            ),
            row('กำไรประมาณ', baht(grossProfit.round())),
            divider(),
            sectionTitle('แบ่งตามวิธีชำระเงิน'),
            row('💵 เงินสด (${cashSales.length} บิล)', baht(cashTotal)),
            row('📱 โอน/QR (${qrSales.length} บิล)', baht(qrTotal)),
            row('รวมทั้งหมด', baht(totalRevenue), big: true),
            divider(),
            sectionTitle('ตรวจนับเงินสดในลิ้นชัก'),
            if (d.drawerToday) ...[
              row('เงินตั้งต้น', baht(d.drawerStarting)),
              row('+ ยอดขายเงินสด', baht(cashTotal)),
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
    final asyncData = ref.watch(_closingDataProvider);
    final now = DateTime.now();
    return Column(
      children: [
        _Header(
          title: '📊 สรุปยอดปิดร้าน · Daily Closing Report',
          subtitle: '${_thaiDateLong(now)} · ปิดเวลา ${_hhmm(now)} น.',
          onClose: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: asyncData.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('เกิดข้อผิดพลาด: $e')),
            data: (d) {
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
    final totalRevenue = _totalRevenue(d);
    final cashSales = _cashSales(d);
    final qrSales = _qrSales(d);
    final cashTotal = _sumTotal(cashSales);
    final qrTotal = _sumTotal(qrSales);
    final grossProfit = _grossProfit(d);
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
          _Kpi('จำนวนบิล', '${d.sales.length} บิล', null),
          _Kpi(
            'เฉลี่ย/บิล',
            baht(d.sales.isEmpty ? 0 : (totalRevenue / d.sales.length).round()),
            null,
          ),
          _Kpi('กำไรประมาณ', baht(grossProfit.round()), AppColors.successLight),
        ]),
        const SizedBox(height: 20),
        _SectionTitle('วิธีชำระเงิน'),
        _payRow('💵 เงินสด', cashSales.length, cashTotal, AppColors.orange),
        _payRow('📱 โอน/QR', qrSales.length, qrTotal, AppColors.steelBlue),
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
          if (cashTotal > 0)
            _miniRow(
              '+ ยอดขายเงินสด',
              '+${baht(cashTotal)}',
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

class _TopItem {
  final String name;
  final int qty;
  final double revenue;
  const _TopItem(this.name, this.qty, this.revenue);
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
