// label_printer.dart — 58mm shelf-label generator.
//
// Flutter port of pos/LabelPrinter.jsx. Renders a selectable product list +
// per-label preview (Code128 barcode of partNo via barcode_widget), then prints
// 58mm-wide labels to PDF via the `printing` package. The PDF barcodes use the
// `barcode` package that ships inside `pdf` (pw.BarcodeWidget) so the printed
// output matches the JsBarcode CODE128 of the JS version.

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme/app_colors.dart';
import '../../data/db/database.dart';

// Fixed brand hexes used on the white printed label (parity with the JSX).
const _navyLabel = Color(0xFF0B2444);
const _steelLabel = Color(0xFF4A6070);
const _orangeLabel = Color(0xFFE8601C);
const _compatLabel = Color(0xFF6B8FAF);

class LabelPrinter extends StatefulWidget {
  final List<ProductRow> products;
  final List<String> selectedIds;
  final List<String> categories; // for catColor() parity
  final String shopNameEN;

  const LabelPrinter({
    super.key,
    required this.products,
    required this.selectedIds,
    required this.categories,
    this.shopNameEN = 'SRISURART',
  });

  @override
  State<LabelPrinter> createState() => _LabelPrinterState();

  // Plain thousand-grouped number (no ฿) for the label price (toLocaleString parity).
  static String plain(num v) {
    final s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
    final parts = s.split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return parts.length > 1 ? '${buf.toString()}.${parts[1]}' : buf.toString();
  }

  // Selector-row price text — JSX shows ฿{p.price} raw (no grouping).
  static String priceText(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

class _LabelPrinterState extends State<LabelPrinter> {
  int _copies = 1;
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.selectedIds};
  }

  List<ProductRow> get _printProducts =>
      widget.products.where((p) => _selected.contains(p.id)).toList();

  Color _catColor(String cat) => AppColors.catColor(cat, widget.categories);

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  Future<void> _print() async {
    final printProducts = _printProducts;
    if (printProducts.isEmpty) return;

    final doc = pw.Document();
    const mm = PdfPageFormat.mm;

    for (final p in printProducts) {
      for (var c = 0; c < _copies; c++) {
        final zoneColor =
            PdfColor.fromInt(_catColor(p.category).toARGB32());
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat(54 * mm, double.infinity, marginAll: 0),
            build: (ctx) => _pdfLabel(p, zoneColor),
          ),
        );
      }
    }

    await Printing.layoutPdf(onLayout: (format) => doc.save());
  }

  pw.Widget _pdfLabel(ProductRow p, PdfColor zoneColor) {
    const navy = PdfColor.fromInt(0xFF0B2444);
    const steel = PdfColor.fromInt(0xFF4A6070);
    const orange = PdfColor.fromInt(0xFFE8601C);
    const compat = PdfColor.fromInt(0xFF6B8FAF);

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: const PdfColor.fromInt(0xFFDDDDDD), width: 0.5),
        borderRadius: pw.BorderRadius.circular(2),
        color: PdfColors.white,
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // zone strip
          pw.Container(
            color: zoneColor,
            padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('${p.category} · ประเภท',
                    style: pw.TextStyle(
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 9)),
                pw.Text(widget.shopNameEN,
                    style: pw.TextStyle(
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 8)),
              ],
            ),
          ),
          // names
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(7, 5, 7, 2),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(p.name.toUpperCase(),
                    style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                        color: navy)),
                if (p.nameTH.isNotEmpty)
                  pw.Text(p.nameTH,
                      style: pw.TextStyle(fontSize: 10, color: steel)),
              ],
            ),
          ),
          // part no
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(7, 0, 7, 3),
            child: pw.Text(p.partNo,
                style: pw.TextStyle(
                    fontSize: 9, color: orange, fontWeight: pw.FontWeight.bold)),
          ),
          // barcode
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(4, 0, 4, 2),
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.code128(),
              data: p.partNo,
              drawText: false,
              height: 32,
              color: PdfColors.black,
              backgroundColor: PdfColors.white,
            ),
          ),
          if ((p.compat ?? '').isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.fromLTRB(7, 0, 7, 3),
              child: pw.Text(p.compat!,
                  style: pw.TextStyle(fontSize: 8, color: compat)),
            ),
          // price strip
          pw.Container(
            color: navy,
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('ราคา · Price',
                        style: pw.TextStyle(
                            color: const PdfColor.fromInt(0x80FFFFFF),
                            fontSize: 8)),
                    pw.Text('รวม VAT 7%',
                        style: pw.TextStyle(
                            color: const PdfColor.fromInt(0x59FFFFFF),
                            fontSize: 7)),
                  ],
                ),
                pw.RichText(
                  text: pw.TextSpan(children: [
                    pw.TextSpan(
                        text: '฿',
                        style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                            color: orange)),
                    pw.TextSpan(
                        text: LabelPrinter.plain(p.price),
                        style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                            color: orange)),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final printProducts = _printProducts;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('🏷 พิมพ์ป้ายราคา · Print Shelf Labels',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text('58mm thermal · เลือกสินค้าแล้วกดพิมพ์',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // body
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 300, child: _selectorCol(theme)),
                  const VerticalDivider(width: 1),
                  Expanded(child: _previewCol(theme, printProducts)),
                ],
              ),
            ),
            const Divider(height: 1),
            // footer
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_selected.length} สินค้า × $_copies ชุด = ${_selected.length * _copies} ป้าย',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('ยกเลิก'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.orange,
                      foregroundColor: AppColors.white,
                    ),
                    onPressed: _selected.isEmpty ? null : _print,
                    icon: const Icon(Icons.print),
                    label: const Text('พิมพ์ป้ายราคา'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectorCol(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _colTitle('เลือกสินค้า (${_selected.length} รายการ)', theme),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _selChip('เลือกทั้งหมด',
                  () => setState(() => _selected = widget.products.map((p) => p.id).toSet())),
              _selChip('ล้าง', () => setState(() => _selected = {})),
              _selChip('⚠ สต็อกต่ำ',
                  () => setState(() => _selected = widget.products
                      .where((p) => p.stock <= p.minStock)
                      .map((p) => p.id)
                      .toSet()),
                  color: AppColors.warning),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              itemCount: widget.products.length,
              itemBuilder: (ctx, i) {
                final p = widget.products[i];
                final on = _selected.contains(p.id);
                return InkWell(
                  onTap: () => _toggle(p.id),
                  child: Container(
                    decoration: BoxDecoration(
                      color: on
                          ? AppColors.orange.withValues(alpha: 0.1)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    margin: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                            size: 18, color: AppColors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              Text(p.partNo,
                                  style: const TextStyle(
                                      fontSize: 11, color: AppColors.orange)),
                            ],
                          ),
                        ),
                        Text('฿${LabelPrinter.priceText(p.price)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppColors.orange)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(),
          _colTitle('จำนวนสำเนา / ป้าย', theme),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: () => setState(() {
                  if (_copies > 1) _copies--;
                }),
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 40,
                child: Text('$_copies',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
              ),
              IconButton.filledTonal(
                onPressed: () => setState(() => _copies++),
                icon: const Icon(Icons.add),
              ),
              const SizedBox(width: 8),
              Text('ชุด', style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewCol(ThemeData theme, List<ProductRow> printProducts) {
    return Container(
      color: theme.colorScheme.surfaceContainerLowest,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _colTitle('ตัวอย่างป้าย · Preview', theme),
          const SizedBox(height: 8),
          Expanded(
            child: printProducts.isEmpty
                ? Center(
                    child: Text('เลือกสินค้าด้านซ้ายเพื่อดูตัวอย่าง',
                        style: theme.textTheme.bodyMedium))
                : ListView.builder(
                    itemCount: printProducts.length,
                    itemBuilder: (ctx, i) {
                      final p = printProducts[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p.name} × $_copies',
                                style: theme.textTheme.labelMedium),
                            const SizedBox(height: 4),
                            _ShelfLabel(product: p, zoneColor: _catColor(p.category)),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _colTitle(String t, ThemeData theme) => Text(
        t,
        style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700, color: theme.colorScheme.secondary),
      );

  Widget _selChip(String label, VoidCallback onTap, {Color? color}) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: color != null ? BorderSide(color: color) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 32),
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

// On-screen preview label (parity with ShelfLabel in the JSX).
class _ShelfLabel extends StatelessWidget {
  final ProductRow product;
  final Color zoneColor;
  const _ShelfLabel({required this.product, required this.zoneColor});

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Container(
      width: 218,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFCCCCCC)),
        borderRadius: BorderRadius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: zoneColor,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text('${p.category} · ประเภท',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 10,
                          letterSpacing: 1)),
                ),
                const Text('SRISURART',
                    style: TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontWeight: FontWeight.w600,
                        fontSize: 9)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: _navyLabel,
                        height: 1.1)),
                Text(p.nameTH,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _steelLabel,
                        height: 1.2)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
            child: Text(p.partNo,
                style: const TextStyle(
                    fontSize: 10,
                    color: _orangeLabel,
                    fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
            child: bw.BarcodeWidget(
              barcode: bw.Barcode.code128(),
              data: p.partNo,
              drawText: false,
              height: 36,
              color: Colors.black,
              backgroundColor: Colors.white,
            ),
          ),
          if ((p.compat ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text(p.compat!,
                  style: const TextStyle(fontSize: 9, color: _compatLabel)),
            ),
          Container(
            color: _navyLabel,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ราคา · Price',
                        style: TextStyle(color: Color(0x80FFFFFF), fontSize: 8)),
                    Text('รวม VAT 7%',
                        style: TextStyle(color: Color(0x66FFFFFF), fontSize: 8)),
                  ],
                ),
                RichText(
                  text: TextSpan(children: [
                    const TextSpan(
                        text: '฿',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _orangeLabel)),
                    TextSpan(
                        text: LabelPrinter.plain(p.price),
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: _orangeLabel,
                            height: 1)),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
