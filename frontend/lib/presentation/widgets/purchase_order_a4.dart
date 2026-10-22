// PurchaseOrderA4View — A4 printable purchase order (ใบสั่งซื้อ / PURCHASE
// ORDER) preview + print/share, owned by PurchaseOrdersScreen (CONTRACT §5).
// Owner request 2026-10-22: print a PO or send it to the supplier's sales rep.
// 🔴 Owner decision 2026-10-22: NO prices on paper — no unit cost, no line
// total, no grand total (the sales rep must not see the shop's costs). Columns
// are # / part no / name / qty only; the foot is an item + quantity count.
// No internal status either (no รอรับสินค้า / received / cancelled dates) — the
// paper goes to the supplier. Lines print in the order the caller passes.
//
// Same infrastructure as QuoteA4View: the `pdf` package builds the document,
// `printing`'s PdfPreview shows it with its print/share bar, and the bundled
// Sarabun / Barlow Condensed fonts (PosPdfFonts, #271) render Thai offline.
// Reads only the PO row + its items + local Settings, so the Drift build and
// the API build print the same paper.
//
// Thai text never carries letterSpacing (#479: the PDF `Tc` operator pushes
// zero-advance tone marks off their consonant) — only the constant Latin
// heading 'PURCHASE ORDER' is spaced.
//
// The Thai labels in this file are `agent ร่าง` (owner to ratify).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/utils/pdf_fonts.dart';
import '../../data/db/database.dart';
import '../../domain/models/aggregates.dart';
import 'thai_format.dart';

// Brand colors (same values as the A4 quote).
const PdfColor _navy = PdfColor.fromInt(0xFF0B2444);
const PdfColor _orange = PdfColor.fromInt(0xFFE8601C);
const PdfColor _steel = PdfColor.fromInt(0xFF6B8FAF);
const PdfColor _gray = PdfColor.fromInt(0xFF4A6070);
const PdfColor _cream = PdfColor.fromInt(0xFFF5EFE3);
const PdfColor _itemBorder = PdfColor.fromInt(0xFFEDE5D8);

class PurchaseOrderA4View extends StatelessWidget {
  final PurchaseOrderWithItems data;
  final SettingsRowData settings;

  const PurchaseOrderA4View({
    super.key,
    required this.data,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return PdfPreview(
      build: (format) => buildPdf(format),
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      pdfFileName: '${data.po.poNo}.pdf',
    );
  }

  @visibleForTesting
  Future<Uint8List> buildPdf(
    PdfPageFormat format, {
    bool compress = true,
  }) async {
    final base = await PosPdfFonts.sarabunRegular();
    final bold = await PosPdfFonts.sarabunBold();
    final semi = await PosPdfFonts.sarabunSemiBold();
    final cond = await PosPdfFonts.barlowCondensedBold();

    // Sarabun as fallback: Barlow Condensed has no Thai glyphs.
    final doc = pw.Document(
      compress: compress,
      theme: pw.ThemeData.withFont(
        base: base,
        bold: bold,
        fontFallback: [base, bold, semi],
      ),
    );
    final po = data.po;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        footer: (ctx) => ctx.pagesCount > 1
            ? pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text(
                  '${po.poNo}  ${ctx.pageNumber}/${ctx.pagesCount}',
                  style: const pw.TextStyle(fontSize: 8, color: _steel),
                ),
              )
            : pw.SizedBox(),
        build: (ctx) => [
          _header(cond),
          pw.SizedBox(height: 18),
          _meta(cond, semi),
          pw.SizedBox(height: 18),
          _itemsTable(cond, semi),
          pw.SizedBox(height: 14),
          _total(cond),
          pw.SizedBox(height: 40),
          _signature(cond),
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _header(pw.Font cond) {
    final s = settings;
    final phone = (s.phone ?? '').trim();
    final taxId = (s.taxId ?? '').trim();
    final phoneLine = [
      if (phone.isNotEmpty) 'โทร $phone',
      if (taxId.isNotEmpty) 'เลขประจำตัวผู้เสียภาษี $taxId',
    ].join(' · ');
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 14),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _orange, width: 3)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  s.shopName,
                  style: pw.TextStyle(font: cond, fontSize: 22, color: _navy),
                ),
                if (s.shopNameEN.isNotEmpty)
                  pw.Text(
                    s.shopNameEN.toUpperCase(),
                    style: pw.TextStyle(
                      font: cond,
                      fontSize: 12,
                      color: _orange,
                    ),
                  ),
                pw.SizedBox(height: 4),
                if ((s.address ?? '').isNotEmpty)
                  pw.Text(
                    s.address!,
                    style: const pw.TextStyle(fontSize: 9, color: _gray),
                  ),
                if (phoneLine.isNotEmpty)
                  pw.Text(
                    phoneLine,
                    style: const pw.TextStyle(fontSize: 9, color: _gray),
                  ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'ใบสั่งซื้อ',
                style: pw.TextStyle(font: cond, fontSize: 28, color: _navy),
              ),
              pw.Text(
                'PURCHASE ORDER',
                style: pw.TextStyle(
                  font: cond,
                  fontSize: 12,
                  color: _orange,
                  letterSpacing: 3.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _label(String t, pw.Font cond) => pw.Text(
    t,
    style: pw.TextStyle(font: cond, fontSize: 9, color: _steel),
  );

  pw.Widget _metaRow(String label, String value, pw.Font cond) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [
        _label(label, cond),
        pw.SizedBox(width: 10),
        pw.Text(value, style: const pw.TextStyle(fontSize: 11, color: _navy)),
      ],
    ),
  );

  pw.Widget _meta(pw.Font cond, pw.Font semi) {
    final po = data.po;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _label('ผู้ขาย · SUPPLIER', cond),
              pw.Text(
                po.supplier,
                style: pw.TextStyle(font: semi, fontSize: 14, color: _navy),
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              _metaRow('เลขที่', po.poNo, cond),
              _metaRow('วันที่', thaiDate(po.createdAt), cond),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget _itemsTable(pw.Font cond, pw.Font semi) {
    pw.Widget th(String t, {pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: _label(t, cond),
        );
    pw.Widget td(
      String t, {
      pw.Alignment align = pw.Alignment.centerLeft,
      pw.Font? font,
      PdfColor color = _navy,
    }) => pw.Container(
      alignment: align,
      padding: const pw.EdgeInsets.all(8),
      child: pw.Text(
        t,
        style: pw.TextStyle(fontSize: 11, color: color, font: font),
      ),
    );

    final items = data.items;
    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(26),
        1: pw.FixedColumnWidth(90),
        2: pw.FlexColumnWidth(),
        3: pw.FixedColumnWidth(60),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            color: _cream,
            border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 2)),
          ),
          children: [
            th('#', align: pw.Alignment.center),
            th('รหัสสินค้า'),
            th('รายการ'),
            th('จำนวน', align: pw.Alignment.center),
          ],
        ),
        for (var i = 0; i < items.length; i++)
          pw.TableRow(
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: _itemBorder, width: 1),
              ),
            ),
            children: [
              td('${i + 1}', align: pw.Alignment.center, color: _steel),
              td(items[i].partNo, color: _gray),
              td(items[i].name, font: semi),
              td('${items[i].qty}', align: pw.Alignment.center, font: semi),
            ],
          ),
      ],
    );
  }

  pw.Widget _total(pw.Font cond) {
    final pieces = data.items.fold<int>(0, (s, i) => s + i.qty);
    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: const pw.BoxDecoration(color: _cream),
        child: pw.Text(
          'รวม ${data.items.length} รายการ · $pieces ชิ้น',
          style: pw.TextStyle(font: cond, fontSize: 14, color: _orange),
        ),
      ),
    );
  }

  pw.Widget _signature(pw.Font cond) => pw.Row(
    children: [
      pw.Spacer(),
      pw.SizedBox(
        width: 220,
        child: pw.Column(
          children: [
            pw.Container(
              height: 32,
              margin: const pw.EdgeInsets.only(bottom: 8),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: _gray, width: 1),
                ),
              ),
            ),
            pw.Text(
              'ผู้สั่งซื้อ · ORDERED BY',
              style: pw.TextStyle(font: cond, fontSize: 10, color: _navy),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'วันที่ ........../........../..........',
              style: const pw.TextStyle(fontSize: 9, color: _steel),
            ),
          ],
        ),
      ),
    ],
  );
}
