// qr_bill_ticklist.dart — the day's โอน/QR bills on A4, one line per bill with
// an empty box, so the owner can tick each one against the bank app (pain
// point 1a, docs/research/pain-points-ai-leverage-2026-10-23.md §4.1).
//
// Opened from the closing report (`showQrTickList`), under its โอน/QR rows.
// Read-only and local: it reads sales / credit notes / QR accounts / settings
// through the repositories, the same reads as the closing report, so the Drift
// build and the API build print the same paper (on the API build: this
// device's bills only, exactly like the closing report).
//
// 🔴 The per-account totals are NOT a second formula: each group's header is a
// row of `qrAccountRows(NetSales.qrByAccount)` — the closing report's own
// split. The lines only itemise it:
// - a manual void is left out (`countedSales`);
// - a fully returned bill (auto-void) stays, at its full amount, and a credit
//   note refunded by `โอน` is its own negative line on its own date, under the
//   account of the bill it refunds (the closing report's rule — so a bill sold
//   today and refunded tomorrow is on both days' lists);
// - a credit note refunded in cash / off credit is not on the list (no bank
//   money moved) and its bill stays at its full amount.
//
// Thai text never carries letterSpacing (#479). The Thai labels in this file
// are `agent ร่าง` (owner to ratify, 02 §8.1.1).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../core/utils/pdf_fonts.dart';
import '../../data/db/database.dart';
import '../../data/repositories/payment_accounts_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/aggregates.dart';
import '../../domain/reports/net_sales.dart';
import 'closing_report.dart';
import 'empty_state.dart';
import 'loading_view.dart';
import 'thai_format.dart';

const PdfColor _navy = PdfColor.fromInt(0xFF0B2444);
const PdfColor _orange = PdfColor.fromInt(0xFFE8601C);
const PdfColor _gray = PdfColor.fromInt(0xFF4A6070);
const PdfColor _cream = PdfColor.fromInt(0xFFF5EFE3);
const PdfColor _itemBorder = PdfColor.fromInt(0xFFEDE5D8);

/// One line to tick: a โอน/QR bill (money in) or a `โอน` refund (money out).
class QrTickLine {
  final DateTime time;

  /// The bill's receipt no., or the credit note's CN no. for a refund.
  final String docNo;

  /// The bill's total, or minus the refund.
  final double amount;
  final bool isRefund;
  const QrTickLine(this.time, this.docNo, this.amount, {this.isRefund = false});
}

/// One receiving account: the closing report's row ([label], [bills], [net])
/// and the lines that make it up, oldest first.
class QrTickGroup {
  final String label;
  final int bills;
  final double net;
  final List<QrTickLine> lines;
  const QrTickGroup(this.label, this.bills, this.net, this.lines);
}

/// The tick list of one day.
class QrTickList {
  final DateTime day;
  final List<QrTickGroup> groups;

  /// The closing report's `📱 โอน/QR` row ([NetSales.qr]).
  final PaymentGroup total;
  final String shopName;
  const QrTickList({
    required this.day,
    required this.groups,
    required this.total,
    required this.shopName,
  });
}

/// Builds the groups from the day's rows — pure, for tests.
///
/// [sales] / [returns] are the day's bills and credit notes; [originalSales]
/// the bills of those credit notes from earlier days (for their account);
/// [laterReturnedSaleIds] the bills with a credit note AFTER the day.
/// [countedSales] tells an auto-void from a manual void by the bill's credit
/// note, and on a past day that note can be later than the day — such a bill
/// is passed on as not voided (it still counts on its own day). For today the
/// set is empty and this is exactly the closing report's computation.
({List<QrTickGroup> groups, PaymentGroup total}) qrTickGroups({
  required List<SaleWithItems> sales,
  required List<ReturnWithItems> returns,
  List<SaleWithItems> originalSales = const [],
  Set<String> laterReturnedSaleIds = const {},
  required List<PaymentAccountRow> accounts,
}) {
  final lites = toReportLites(
    sales: sales,
    returns: returns,
    products: const [],
    originalSales: originalSales,
  );
  final saleLites = [
    for (final s in lites.sales)
      s.voided && laterReturnedSaleIds.contains(s.id)
          ? SaleLite(
              id: s.id,
              subtotal: s.subtotal,
              discount: s.discount,
              total: s.total,
              paymentMethod: s.paymentMethod,
              paymentAccountId: s.paymentAccountId,
              items: s.items,
            )
          : s,
  ];
  final net = NetSales.of(saleLites, lites.returns);
  final rows = qrAccountRows(net.qrByAccount, accounts);

  // Which row a line belongs to — the order qrAccountRows builds its rows in:
  // known accounts (in `accounts` order), every deleted account merged, then
  // no account.
  final known = {for (final a in accounts) a.id};
  String rowKey(String? accountId) => accountId == null
      ? 'none'
      : known.contains(accountId)
      ? 'a:$accountId'
      : 'deleted';
  final keys = [
    for (final a in accounts)
      if (net.qrByAccount.containsKey(a.id)) 'a:${a.id}',
    if (net.qrByAccount.keys.any((k) => k != null && !known.contains(k)))
      'deleted',
    if (net.qrByAccount.containsKey(null)) 'none',
  ];
  assert(keys.length == rows.length);

  final saleById = {for (final s in sales) s.sale.id: s.sale};
  final linesByKey = <String, List<QrTickLine>>{};
  for (final s in qrSales(net.counted)) {
    final row = saleById[s.id]!;
    (linesByKey[rowKey(s.paymentAccountId)] ??= []).add(
      QrTickLine(row.date, row.receiptNo, row.total),
    );
  }
  for (var i = 0; i < returns.length; i++) {
    final r = lites.returns[i];
    if (!isQrMoney(r.refundMethod)) continue;
    final row = returns[i].ret;
    (linesByKey[rowKey(r.saleAccountId)] ??= []).add(
      QrTickLine(row.date, row.cnNo, -row.refundTotal, isRefund: true),
    );
  }

  return (
    groups: [
      for (var i = 0; i < rows.length; i++)
        QrTickGroup(
          rows[i].label,
          rows[i].bills,
          rows[i].net,
          (linesByKey[keys[i]] ?? [])..sort((a, b) => a.time.compareTo(b.time)),
        ),
    ],
    total: net.qr,
  );
}

/// Reads [day]'s tick list through the repositories — the closing report's
/// reads (`_loadClosingData`) for any day, plus the later credit notes.
Future<QrTickList> loadQrTickList(BuildContext context, DateTime day) async {
  final salesRepo = context.read<SalesRepository>();
  final returnsRepo = context.read<ReturnsRepository>();
  final accountsRepo = context.read<PaymentAccountsRepository>();
  final settingsRepo = context.read<SettingsRepository>();

  final bounds = dayBounds(day);
  final sales = await salesRepo.getSales(from: bounds.from, to: bounds.to);
  final returns = await returnsRepo.getReturns(
    from: bounds.from,
    to: bounds.to,
  );
  final later = await returnsRepo.getReturns(from: bounds.to);
  final daySaleIds = {for (final s in sales) s.sale.id};
  final originalSales = await salesRepo.getSalesByIds(
    returns.map((r) => r.ret.saleId).where((id) => !daySaleIds.contains(id)),
  );
  final accounts = await accountsRepo.getAccounts();
  final settings = await settingsRepo.getSettings();

  final built = qrTickGroups(
    sales: sales,
    returns: returns,
    originalSales: originalSales,
    laterReturnedSaleIds: {for (final r in later) r.ret.saleId},
    accounts: accounts,
  );
  return QrTickList(
    day: bounds.from,
    groups: built.groups,
    total: built.total,
    shopName: settings.shopName,
  );
}

/// Opens the tick list (today first; another day can be picked).
Future<void> showQrTickList(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => const QrTickListPage(),
  ),
);

/// Date bar + the A4 preview with PdfPreview's print/share bar.
class QrTickListPage extends StatefulWidget {
  const QrTickListPage({super.key});

  @override
  State<QrTickListPage> createState() => _QrTickListPageState();
}

class _QrTickListPageState extends State<QrTickListPage> {
  late DateTime _day;
  late Future<QrTickList> _future;

  @override
  void initState() {
    super.initState();
    _day = DateUtils.dateOnly(DateTime.now());
    _future = loadQrTickList(context, _day);
  }

  Future<void> _pickDay() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(today.year - 5),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _day = picked;
      _future = loadQrTickList(context, picked);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('รายการบิล โอน/QR')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'วันที่ ${thaiDate(_day)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                OutlinedButton.icon(
                  onPressed: _pickDay,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: const Text('เลือกวันที่'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<QrTickList>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const LoadingView();
                }
                if (snap.hasError) {
                  return EmptyState(
                    icon: Icons.error_outline,
                    message: 'เกิดข้อผิดพลาด: ${snap.error}',
                  );
                }
                return QrTickListA4View(data: snap.data!);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class QrTickListA4View extends StatelessWidget {
  final QrTickList data;
  const QrTickListA4View({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return PdfPreview(
      build: (format) => buildPdf(format),
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      pdfFileName: 'qr-${dateKey(data.day)}.pdf',
    );
  }

  @visibleForTesting
  Future<Uint8List> buildPdf(
    PdfPageFormat format, {
    bool compress = true,
  }) async {
    final base = await PosPdfFonts.sarabunRegular();
    final bold = await PosPdfFonts.sarabunBold();
    final doc = pw.Document(
      compress: compress,
      theme: pw.ThemeData.withFont(base: base, bold: bold),
    );
    final printedAt = DateTime.now();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'พิมพ์เมื่อ ${thaiDateTime(printedAt)}  ${ctx.pageNumber}/${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: _gray),
          ),
        ),
        build: (ctx) => [
          _header(),
          pw.SizedBox(height: 14),
          if (data.groups.isEmpty)
            pw.Text(
              'ไม่มีบิล โอน/QR ในวันนี้',
              style: const pw.TextStyle(fontSize: 12, color: _gray),
            ),
          for (final g in data.groups) ...[
            _groupTitle(g),
            _lines(g),
            pw.SizedBox(height: 14),
          ],
          _grandTotal(),
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _header() => pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 10),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _orange, width: 3)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                data.shopName,
                style: const pw.TextStyle(fontSize: 12, color: _gray),
              ),
              pw.Text(
                'รายการบิล โอน/QR',
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                  color: _navy,
                ),
              ),
            ],
          ),
        ),
        pw.Text(
          'วันที่ ${thaiDate(data.day)}',
          style: pw.TextStyle(
            fontSize: 13,
            fontWeight: pw.FontWeight.bold,
            color: _navy,
          ),
        ),
      ],
    ),
  );

  pw.Widget _groupTitle(QrTickGroup g) => pw.Container(
    color: _cream,
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(
            '${g.label} (${g.bills} บิล)',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: _navy,
            ),
          ),
        ),
        pw.Text(
          _money(g.net),
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
            color: _orange,
          ),
        ),
      ],
    ),
  );

  pw.Widget _lines(QrTickGroup g) {
    pw.Widget th(String t, {pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: pw.Text(
            t,
            style: const pw.TextStyle(fontSize: 9, color: _gray),
          ),
        );
    pw.Widget td(String t, {pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: pw.Text(
            t,
            style: const pw.TextStyle(fontSize: 11, color: _navy),
          ),
        );
    // A new box per row: a pw widget keeps its own layout, so one shared
    // instance is drawn on the last row only.
    pw.Widget box() => pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(vertical: 7),
      child: pw.Container(
        width: 12,
        height: 12,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _navy, width: 1),
        ),
      ),
    );
    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(60),
        1: pw.FlexColumnWidth(),
        2: pw.FixedColumnWidth(110),
        3: pw.FixedColumnWidth(40),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 1)),
          ),
          children: [
            th('เวลา'),
            th('เลขที่บิล'),
            th('ยอด', align: pw.Alignment.centerRight),
            th('ตรวจ', align: pw.Alignment.center),
          ],
        ),
        for (final l in g.lines)
          pw.TableRow(
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: _itemBorder, width: 1),
              ),
            ),
            children: [
              td(thaiTime(l.time)),
              td(l.isRefund ? 'คืนเงิน ${l.docNo}' : l.docNo),
              td(_money(l.amount), align: pw.Alignment.centerRight),
              box(),
            ],
          ),
      ],
    );
  }

  pw.Widget _grandTotal() => pw.Align(
    alignment: pw.Alignment.centerRight,
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const pw.BoxDecoration(color: _cream),
      child: pw.Text(
        'รวม โอน/QR (${data.total.bills} บิล) ${_money(data.total.net)}',
        style: pw.TextStyle(
          fontSize: 13,
          fontWeight: pw.FontWeight.bold,
          color: _orange,
        ),
      ),
    ),
  );
}

/// Satang shown, as the bank app shows them; a refund reads `−฿40.00`.
String _money(double v) => v < 0 ? '−${baht2(-v)}' : baht2(v);
