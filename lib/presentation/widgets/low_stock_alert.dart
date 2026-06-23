// low_stock_alert.dart — once-per-session low-stock alert (port of
// pos/LowStockAlert.jsx).
//
// JS behaviour parity:
//  • Lists OUT-of-stock (stock == 0) then LOW (0 < stock <= minStock) products,
//    each row showing a category pill, the part name + Thai name + partNo, and
//    the stock/min figure, with a per-row "handled" toggle (○ / ✓).
//  • A running "ยังมี N รายการที่ยังไม่ได้จัดการ" counter in the footer (or
//    "✓ จัดการทุกรายการแล้ว" once every row is ticked).
//  • A "🖨 พิมพ์ใบสั่งซื้อ" action that emits the same 80mm supplier order list
//    as the JS print popup (out-of-stock then low-stock sections, name + partNo
//    + stock/min), via the `printing` package.
//  • Shown once per app session — controlled by [lowStockShownThisSession], a
//    module-level flag the host screen checks (mirrors the JS
//    sessionStorage `sa_lowstock_dismissed` once-per-session rule, NOT per day).
//  • Provides a "ไปหน้าสั่งซื้อ" action (navigates to /purchase-orders).

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme/app_colors.dart';
import '../../data/db/database.dart';

/// Session flag: true once the alert has been shown/dismissed this app run.
/// The checkout screen flips this so the banner appears at most once per session.
bool lowStockShownThisSession = false;

/// Splits products into out-of-stock and low-stock buckets (db.js logic).
({List<ProductRow> out, List<ProductRow> low}) lowStockBuckets(
    List<ProductRow> products) {
  final out = products.where((p) => p.stock == 0).toList();
  final low =
      products.where((p) => p.stock > 0 && p.stock <= p.minStock).toList();
  return (out: out, low: low);
}

class LowStockBanner extends StatefulWidget {
  final List<ProductRow> outOfStock;
  final List<ProductRow> lowStock;
  final VoidCallback onClose;
  final VoidCallback onOrder;

  /// Category → hex-color string (e.g. "#0B2444"), used to tint the row pills
  /// like the JS `getCatColor(p.category)`. Optional: a navy fallback is used
  /// for any category not present in the map.
  final Map<String, String> catColors;

  const LowStockBanner({
    super.key,
    required this.outOfStock,
    required this.lowStock,
    required this.onClose,
    required this.onOrder,
    this.catColors = const {},
  });

  @override
  State<LowStockBanner> createState() => _LowStockBannerState();
}

class _LowStockBannerState extends State<LowStockBanner> {
  // Mirrors the JS `dismissed` array: ids the user has ticked as handled.
  final Set<String> _dismissed = <String>{};
  bool _busy = false;
  bool _printed = false;

  static const Color _outColor = Color(0xFFC0392B); // #C0392B
  static const Color _lowColor = Color(0xFFD4820A); // #D4820A
  static const Color _navy = Color(0xFF0B2444); // pill fallback (catColor miss)
  static const Color _partColor = Color(0xFFE8601C); // #E8601C

  Color _pillColor(String category) {
    final hex = widget.catColors[category];
    if (hex == null) return _navy;
    final cleaned = hex.replaceFirst('#', '');
    final v = int.tryParse(cleaned, radix: 16);
    if (v == null) return _navy;
    return Color(cleaned.length <= 6 ? (0xFF000000 | v) : v);
  }

  int get _visibleCount {
    var n = 0;
    for (final p in widget.outOfStock) {
      if (!_dismissed.contains(p.partNo)) n++;
    }
    for (final p in widget.lowStock) {
      if (!_dismissed.contains(p.partNo)) n++;
    }
    return n;
  }

  void _toggle(String id) {
    setState(() {
      if (_dismissed.contains(id)) {
        _dismissed.remove(id);
      } else {
        _dismissed.add(id);
      }
    });
  }

  // ── 80mm supplier-order print (ports LowStockAlert.jsx handlePrint) ────────
  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      final font = await PdfGoogleFonts.sarabunRegular();
      final fontB = await PdfGoogleFonts.sarabunBold();
      final doc = _buildPdf(font, fontB);
      await Printing.layoutPdf(onLayout: (_) async => doc.save());
      if (mounted) setState(() => _printed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  pw.Document _buildPdf(pw.Font font, pw.Font fontB) {
    final doc = pw.Document();
    final now = DateTime.now();

    pw.Widget sectionTitle(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6, bottom: 2),
          child: pw.Text(t,
              style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.grey700)),
        );

    pw.Widget row(ProductRow p, {required bool isOut}) {
      final color = isOut
          ? const PdfColor.fromInt(0xFFC0392B)
          : const PdfColor.fromInt(0xFFD4820A);
      return pw.Container(
        decoration: const pw.BoxDecoration(
          border: pw.Border(
              bottom: pw.BorderSide(width: 0.5, color: PdfColors.grey300)),
        ),
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(p.name,
                      style: pw.TextStyle(fontSize: 9, color: color)),
                  pw.Text(p.partNo,
                      style: const pw.TextStyle(
                          fontSize: 7,
                          color: PdfColor.fromInt(0xFFE8601C))),
                ],
              ),
            ),
            pw.SizedBox(
              width: 22,
              child: pw.Text('${p.stock}',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: const PdfColor.fromInt(0xFFC0392B))),
            ),
            pw.SizedBox(
              width: 24,
              child: pw.Text('/${p.minStock}',
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey700)),
            ),
          ],
        ),
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80.copyWith(
            marginTop: 8, marginBottom: 8, marginLeft: 8, marginRight: 8),
        theme: pw.ThemeData.withFont(base: font, bold: fontB),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Container(
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                    bottom: pw.BorderSide(width: 2, color: _navyPdf)),
              ),
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Center(
                child: pw.Text('⚠ แจ้งเตือนสต็อกต่ำ',
                    style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: _navyPdf)),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Center(
              child: pw.Text(
                  'Low Stock Alert · ${_thaiDateTime(now)} · ศรีสุราษฎร์เจริญยนต์',
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(
                      fontSize: 7, color: PdfColors.grey700)),
            ),
            if (widget.outOfStock.isNotEmpty) ...[
              sectionTitle('❌ หมดสต็อก (${widget.outOfStock.length} รายการ)'),
              for (final p in widget.outOfStock) row(p, isOut: true),
            ],
            if (widget.lowStock.isNotEmpty) ...[
              sectionTitle('⚠ สต็อกต่ำ (${widget.lowStock.length} รายการ)'),
              for (final p in widget.lowStock) row(p, isOut: false),
            ],
            pw.SizedBox(height: 10),
            pw.Center(
              child: pw.Text('พิมพ์เพื่อส่งซัพพลายเออร์ · Print for supplier order',
                  style: const pw.TextStyle(
                      fontSize: 7, color: PdfColors.grey)),
            ),
          ],
        ),
      ),
    );
    return doc;
  }

  static const PdfColor _navyPdf = PdfColor.fromInt(0xFF0B2444);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outN = widget.outOfStock.length;
    final lowN = widget.lowStock.length;
    final visible = _visibleCount;

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: _lowColor, width: 2),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──
            Container(
              color: _lowColor.withValues(alpha: 0.1),
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
              child: Row(
                children: [
                  const Text('⚠', style: TextStyle(fontSize: 30)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'แจ้งเตือนสต็อก · Stock Alert',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'พบ $outN รายการหมด + $lowN รายการต่ำกว่าขั้นต่ำ',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.steelBlue),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onClose,
                    child: const Text('✕ ปิด'),
                  ),
                ],
              ),
            ),
            // ── Item list (out then low) ──
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (outN > 0)
                      _section(
                        theme,
                        titleLeft: '❌ หมดสต็อก',
                        titleColor: _outColor,
                        count: outN,
                        rows: [
                          for (final p in widget.outOfStock)
                            _row(theme, p,
                                statusColor: _outColor, statusLabel: 'OUT'),
                        ],
                      ),
                    if (lowN > 0)
                      _section(
                        theme,
                        titleLeft: '⚠ สต็อกต่ำ',
                        titleColor: _lowColor,
                        count: lowN,
                        rows: [
                          for (final p in widget.lowStock)
                            _row(theme, p,
                                statusColor: _lowColor,
                                statusLabel: '${p.stock}/${p.minStock}'),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            // ── Footer ──
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      visible > 0
                          ? 'ยังมี $visible รายการที่ยังไม่ได้จัดการ'
                          : (_printed
                              ? '✓ ส่งใบสั่งซื้อไปยังหน้าต่างพิมพ์แล้ว'
                              : '✓ จัดการทุกรายการแล้ว'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.steelBlue),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _print,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('🖨 พิมพ์ใบสั่งซื้อ'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      widget.onOrder();
                      widget.onClose();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: _partColor,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('🛒 ไปหน้าสั่งซื้อ'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(
    ThemeData theme, {
    required String titleLeft,
    required Color titleColor,
    required int count,
    required List<Widget> rows,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(titleLeft,
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700, color: titleColor)),
                Text('$count รายการ',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.steelBlue)),
              ],
            ),
          ),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    ProductRow p, {
    required Color statusColor,
    required String statusLabel,
  }) {
    final dismissed = _dismissed.contains(p.partNo);
    return Opacity(
      opacity: dismissed ? 0.4 : 1,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            // category pill
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: _pillColor(p.category),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                p.category,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8),
              ),
            ),
            const SizedBox(width: 10),
            // name + thai name + partNo
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '${p.nameTH} · '),
                      TextSpan(
                        text: p.partNo,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            color: _partColor,
                            fontSize: 11),
                      ),
                    ]),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.steelBlue),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // stock/min figure
            SizedBox(
              width: 64,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(statusLabel,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                          height: 1,
                          color: statusColor)),
                  Text('Min: ${p.minStock}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.steelBlue, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // handled toggle (○ / ✓)
            IconButton(
              tooltip: 'ทำเครื่องหมายว่าจัดการแล้ว',
              onPressed: () => _toggle(p.partNo),
              icon: Text(
                dismissed ? '✓' : '○',
                style: TextStyle(
                    fontSize: 16,
                    color: dismissed
                        ? const Color(0xFF5A9E2F)
                        : AppColors.steelBlue),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Thai date/time for the print header (th-TH toLocaleString equivalent) ────
const _thMonthsShort = [
  'ม.ค.',
  'ก.พ.',
  'มี.ค.',
  'เม.ย.',
  'พ.ค.',
  'มิ.ย.',
  'ก.ค.',
  'ส.ค.',
  'ก.ย.',
  'ต.ค.',
  'พ.ย.',
  'ธ.ค.',
];

String _thaiDateTime(DateTime d) {
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${_thMonthsShort[d.month - 1]} ${d.year + 543} $hh:$mm';
}
