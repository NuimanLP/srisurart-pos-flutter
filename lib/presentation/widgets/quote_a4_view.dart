// QuoteA4View — A4 printable quotation (ใบเสนอราคา / QUOTATION) preview + print.
//
// Flutter port of the `Quote` component (the #receipt-paper data-print="a4"
// block) in pos/Quote.jsx. Builds a real PDF via the `pdf` package and shows it
// with the `printing` package's PdfPreview (which also exposes the share/print
// bar). Thai text uses Sarabun; the display headings use Barlow Condensed — both
// fetched lazily through PdfGoogleFonts so Thai glyphs render in the PDF.
//
// The JS A4 layout (760px paper) is reproduced: orange header band with shop
// info + QUOTATION title, a meta grid (เสนอแก่ / เลขที่·วันที่·ใช้ได้ถึง·ผู้ออก),
// the items table, a notes box + totals box, and two signature columns.
// The default notes line and the validity-days term match the JSX exactly.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../data/db/database.dart';
import '../../domain/models/aggregates.dart';

// Brand colors as PDF colors (hex parity with the JSX A4 styles).
const PdfColor _navy = PdfColor.fromInt(0xFF0B2444);
const PdfColor _orange = PdfColor.fromInt(0xFFE8601C);
const PdfColor _steel = PdfColor.fromInt(0xFF6B8FAF);
const PdfColor _gray = PdfColor.fromInt(0xFF4A6070);
const PdfColor _cream = PdfColor.fromInt(0xFFF5EFE3);
const PdfColor _expiredRed = PdfColor.fromInt(0xFFC0392B);
const PdfColor _itemBorder = PdfColor.fromInt(0xFFEDE5D8);

/// The default NOTES line when the quote carries none (parity with JSX).
const String kQuoteDefaultNotes =
    '— ราคานี้เป็นราคาขายปลีก ยังไม่รวมภาษีมูลค่าเพิ่ม —';

final DateFormat _thLongDate = DateFormat('d MMMM yyyy', 'th');

String _longThaiDate(DateTime d) {
  // Buddhist year (พ.ศ.) like toLocaleDateString('th-TH', {year:'numeric',...}).
  final be = d.year + 543;
  final base = _thLongDate.format(d);
  return base.replaceFirst(d.year.toString(), be.toString());
}

/// A printable A4 quotation view. Pass the quote header + its line items and the
/// shop settings; the widget renders the PDF and the print/share toolbar.
class QuoteA4View extends StatelessWidget {
  final QuoteRow quote;
  final List<QuoteItemRow> items;
  final SettingsRowData settings;

  const QuoteA4View({
    super.key,
    required this.quote,
    required this.items,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return PdfPreview(
      build: (format) => _buildPdf(format),
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      pdfFileName: '${quote.quoteNo}.pdf',
    );
  }

  Future<Uint8List> _buildPdf(PdfPageFormat format) async {
    final base = await PdfGoogleFonts.sarabunRegular();
    final bold = await PdfGoogleFonts.sarabunBold();
    final semi = await PdfGoogleFonts.sarabunSemiBold();
    final cond = await PdfGoogleFonts.barlowCondensedBold();

    final doc = pw.Document(
      // The display headings use Barlow Condensed (cond), which has NO Thai
      // glyphs. The labels mix Thai + EN (e.g. 'เสนอแก่ · TO'), so without a
      // fallback the Thai half renders as .notdef boxes. Sarabun fonts as the
      // theme-wide fallback render any non-Latin glyph; the fallback is
      // inherited by every TextStyle even when it overrides `font:`.
      theme: pw.ThemeData.withFont(
        base: base,
        bold: bold,
        fontFallback: [base, bold, semi],
      ),
    );

    final s = settings;
    final isExpired = quote.isExpired;
    final dateStr = _longThaiDate(quote.date);
    final validUntilStr = _longThaiDate(quote.validUntil);
    final validDays =
        ((quote.validUntil.difference(quote.date).inMilliseconds) / 86400000)
            .round();

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        build: (ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _headerBand(s, cond),
              pw.SizedBox(height: 18),
              _metaGrid(s, dateStr, validUntilStr, isExpired, cond, semi),
              pw.SizedBox(height: 18),
              _itemsTable(cond, semi),
              pw.SizedBox(height: 14),
              _totalsRow(validDays, cond),
              pw.SizedBox(height: 22),
              _signatures(cond),
            ],
          );
        },
      ),
    );
    return doc.save();
  }

  pw.Widget _headerBand(SettingsRowData s, pw.Font cond) {
    final taxId = s.taxId;
    final phoneLine = 'โทร ${s.phone ?? ''}'
        '${(taxId != null && taxId.isNotEmpty) ? ' · เลขประจำตัวผู้เสียภาษี $taxId' : ''}';
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 14),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _orange, width: 3)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(s.shopName,
                    style: pw.TextStyle(
                        font: cond, fontSize: 22, color: _navy)),
                pw.Text(s.shopNameEN.toUpperCase(),
                    style: pw.TextStyle(
                        font: cond,
                        fontSize: 12,
                        color: _orange,
                        letterSpacing: 2.2)),
                pw.SizedBox(height: 4),
                if ((s.address ?? '').isNotEmpty)
                  pw.Text(s.address!,
                      style:
                          const pw.TextStyle(fontSize: 9, color: _gray)),
                pw.Text(phoneLine,
                    style: const pw.TextStyle(fontSize: 9, color: _gray)),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('ใบเสนอราคา',
                  style: pw.TextStyle(font: cond, fontSize: 28, color: _navy)),
              pw.Text('QUOTATION',
                  style: pw.TextStyle(
                      font: cond,
                      fontSize: 12,
                      color: _orange,
                      letterSpacing: 3.2)),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _metaGrid(
    SettingsRowData s,
    String dateStr,
    String validUntilStr,
    bool isExpired,
    pw.Font cond,
    pw.Font semi,
  ) {
    final converted = quote.status == 'converted';
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _metaLabel('เสนอแก่ · TO', cond),
              pw.Text(
                (quote.customerName != null && quote.customerName!.isNotEmpty)
                    ? quote.customerName!
                    : '— ลูกค้าทั่วไป —',
                style: pw.TextStyle(font: semi, fontSize: 14, color: _navy),
              ),
              if ((quote.customerPhone ?? '').isNotEmpty)
                pw.Text('โทร ${quote.customerPhone}',
                    style: const pw.TextStyle(fontSize: 10, color: _gray)),
            ],
          ),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              _metaRow('เลขที่', quote.quoteNo, cond),
              _metaRow('วันที่', dateStr, cond),
              _metaRow(
                'ใช้ได้ถึง',
                validUntilStr,
                cond,
                valueColor: isExpired ? _expiredRed : _navy,
                valueBold: true,
                valueFont: semi,
              ),
              _metaRow('ผู้ออก', s.cashierName ?? '', cond),
              if (converted)
                pw.Container(
                  margin: const pw.EdgeInsets.only(top: 8),
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: pw.BoxDecoration(
                    color: const PdfColor.fromInt(0xFFE5F0DD),
                    borderRadius: pw.BorderRadius.circular(12),
                  ),
                  child: pw.Text('✓ แปลงเป็นการขายแล้ว',
                      style: pw.TextStyle(
                          font: semi,
                          fontSize: 10,
                          color: const PdfColor.fromInt(0xFF3A6D1F))),
                ),
              if (isExpired && !converted)
                pw.Container(
                  margin: const pw.EdgeInsets.only(top: 8),
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: pw.BoxDecoration(
                    color: const PdfColor.fromInt(0xFFFBE5E2),
                    borderRadius: pw.BorderRadius.circular(12),
                  ),
                  child: pw.Text('⏱ หมดอายุ',
                      style: pw.TextStyle(
                          font: semi,
                          fontSize: 10,
                          color: const PdfColor.fromInt(0xFFA12818))),
                ),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget _metaLabel(String t, pw.Font cond) => pw.Text(
        t.toUpperCase(),
        style: pw.TextStyle(
            font: cond, fontSize: 9, color: _steel, letterSpacing: 1.6),
      );

  pw.Widget _metaRow(
    String label,
    String value,
    pw.Font cond, {
    PdfColor? valueColor,
    bool valueBold = false,
    pw.Font? valueFont,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(label,
              style: pw.TextStyle(
                  font: cond, fontSize: 9, color: _steel, letterSpacing: 1.6)),
          pw.SizedBox(width: 10),
          pw.Text(value,
              style: pw.TextStyle(
                fontSize: 11,
                font: valueFont,
                color: valueColor ?? _navy,
                fontWeight: valueBold ? pw.FontWeight.bold : pw.FontWeight.normal,
              )),
        ],
      ),
    );
  }

  pw.Widget _itemsTable(pw.Font cond, pw.Font semi) {
    pw.Widget th(String t, {pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: pw.Text(t.toUpperCase(),
              style: pw.TextStyle(
                  font: cond, fontSize: 9, color: _steel, letterSpacing: 1.4)),
        );

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(
          color: _cream,
          border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 2)),
        ),
        children: [
          th('#', align: pw.Alignment.center),
          th('รายการ · DESCRIPTION'),
          th('จำนวน', align: pw.Alignment.center),
          th('ราคา/หน่วย', align: pw.Alignment.centerRight),
          th('รวม', align: pw.Alignment.centerRight),
        ],
      ),
    ];

    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      rows.add(
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            border:
                pw.Border(bottom: pw.BorderSide(color: _itemBorder, width: 1)),
          ),
          children: [
            _td('${i + 1}', align: pw.Alignment.center, color: _steel),
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: pw.Text(it.name,
                  style: pw.TextStyle(font: semi, fontSize: 11, color: _navy)),
            ),
            _td('${it.qty}', align: pw.Alignment.center),
            _td(_money(it.price), align: pw.Alignment.centerRight),
            _td(_money(it.qty * it.price),
                align: pw.Alignment.centerRight, font: semi),
          ],
        ),
      );
    }

    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(28),
        1: pw.FlexColumnWidth(),
        2: pw.FixedColumnWidth(50),
        3: pw.FixedColumnWidth(80),
        4: pw.FixedColumnWidth(86),
      },
      children: rows,
    );
  }

  pw.Widget _td(String t,
          {pw.Alignment align = pw.Alignment.centerLeft,
          PdfColor color = _navy,
          pw.Font? font}) =>
      pw.Container(
        alignment: align,
        padding: const pw.EdgeInsets.all(8),
        child: pw.Text(t, style: pw.TextStyle(fontSize: 11, color: color, font: font)),
      );

  pw.Widget _totalsRow(int validDays, pw.Font cond) {
    final notes = (quote.notes != null && quote.notes!.isNotEmpty)
        ? quote.notes!
        : kQuoteDefaultNotes;
    final discount = quote.discount ?? 0;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _metaLabel('หมายเหตุ · NOTES', cond),
              pw.SizedBox(height: 4),
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: const pw.BoxDecoration(
                  color: _cream,
                  border: pw.Border(left: pw.BorderSide(color: _orange, width: 3)),
                ),
                child: pw.Text(notes,
                    style: const pw.TextStyle(fontSize: 10, color: _navy)),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                  '• ใบเสนอราคามีอายุ $validDays วัน นับจากวันที่ออก',
                  style: const pw.TextStyle(fontSize: 9, color: _gray)),
              pw.Text('• ราคาอาจเปลี่ยนแปลงตามต้นทุน หากเกินกำหนดอายุ',
                  style: const pw.TextStyle(fontSize: 9, color: _gray)),
              pw.Text('• สินค้าตามใบเสนอราคานี้ ยังไม่ได้ตัดสต็อก',
                  style: const pw.TextStyle(fontSize: 9, color: _gray)),
            ],
          ),
        ),
        pw.SizedBox(width: 18),
        pw.Container(
          width: 230,
          padding: const pw.EdgeInsets.all(14),
          decoration: const pw.BoxDecoration(color: _cream),
          child: pw.Column(
            children: [
              _totLine('ยอดรวม', _money(quote.subtotal ?? 0)),
              if (discount > 0)
                _totLine('ส่วนลด', '-${_money(discount)}'),
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 8),
                padding: const pw.EdgeInsets.only(top: 8),
                decoration: const pw.BoxDecoration(
                  border:
                      pw.Border(top: pw.BorderSide(color: _navy, width: 2)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('รวมทั้งสิ้น',
                        style: pw.TextStyle(font: cond, fontSize: 16, color: _orange)),
                    pw.Text(_money(quote.total ?? 0),
                        style: pw.TextStyle(font: cond, fontSize: 16, color: _orange)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget _totLine(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 5),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: const pw.TextStyle(fontSize: 11, color: _navy)),
            pw.Text(value, style: const pw.TextStyle(fontSize: 11, color: _navy)),
          ],
        ),
      );

  pw.Widget _signatures(pw.Font cond) {
    pw.Widget col(String label) => pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Container(
                height: 32,
                margin: const pw.EdgeInsets.only(bottom: 8),
                decoration: const pw.BoxDecoration(
                  border:
                      pw.Border(bottom: pw.BorderSide(color: _gray, width: 1)),
                ),
              ),
              pw.Text(label,
                  style: pw.TextStyle(
                      font: cond, fontSize: 10, color: _navy, letterSpacing: 1.6)),
              pw.SizedBox(height: 4),
              pw.Text('วันที่ ........../........../..........',
                  style: const pw.TextStyle(fontSize: 9, color: _steel)),
            ],
          ),
        );
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 2),
      padding: const pw.EdgeInsets.only(top: 18),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
            top: pw.BorderSide(color: PdfColor.fromInt(0xFFC9BFA8), width: 1)),
      ),
      child: pw.Row(
        children: [
          col('ผู้เสนอราคา · QUOTED BY'),
          pw.SizedBox(width: 32),
          col('ผู้อนุมัติ · APPROVED BY'),
        ],
      ),
    );
  }
}

// Money rendered like the JSX `฿N.toLocaleString()` (grouping, no forced
// decimals). Kept local to the PDF so it matches the on-paper formatting.
final NumberFormat _pdfMoneyFmt = NumberFormat('#,##0.##');
String _money(num v) => '฿${_pdfMoneyFmt.format(v)}';
