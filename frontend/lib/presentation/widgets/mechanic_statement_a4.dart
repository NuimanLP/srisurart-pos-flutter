// MechanicStatementA4View — A4 credit statement / ใบวางบิล for one mechanic,
// with debt aging (pain-points survey 2026-10-23 §4.2), owned by
// MechanicsScreen (CONTRACT §5).
//
// The numbers come from `allocateCreditStatement` (domain/reports/
// credit_statement.dart): the mechanic's stored creditBalance is the total,
// spread backwards over the newest credit bills; what no local bill explains is
// the `ยอดยกมา/ไม่มีบิลอ้างอิง` line. Display only — nothing is written.
//
// Same infrastructure as PurchaseOrderA4View / QuoteA4View: the `pdf` package
// builds the document, `printing`'s PdfPreview shows it with its print/share
// bar, and the bundled Sarabun / Barlow Condensed fonts (PosPdfFonts, #271)
// render Thai offline. Reads only local rows, so it works on the Drift and the
// API build alike (on the API build bills from other devices are not local and
// land in the residual line).
//
// Thai text never carries letterSpacing (#479) — only the constant Latin
// heading 'STATEMENT' is spaced.
//
// The Thai labels in this file are `agent ร่าง` (owner to ratify).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../core/utils/pdf_fonts.dart';
import '../../data/db/database.dart';
import '../../domain/reports/credit_statement.dart';
import 'thai_format.dart';

// Brand colors (same values as the A4 quote / PO).
const PdfColor _navy = PdfColor.fromInt(0xFF0B2444);
const PdfColor _orange = PdfColor.fromInt(0xFFE8601C);
const PdfColor _steel = PdfColor.fromInt(0xFF6B8FAF);
const PdfColor _gray = PdfColor.fromInt(0xFF4A6070);
const PdfColor _cream = PdfColor.fromInt(0xFFF5EFE3);
const PdfColor _itemBorder = PdfColor.fromInt(0xFFEDE5D8);

/// The residual line's label (`agent ร่าง`).
const String statementResidualLabel = 'ยอดยกมา/ไม่มีบิลอ้างอิง';

/// The mechanic as the statement names them: Thai name, else name.
String statementMechanicName(MechanicRow m) {
  final th = (m.nameTH ?? '').trim();
  return th.isNotEmpty ? th : m.name.trim();
}

/// `statement-<code>-YYYY-MM-DD.pdf` — the mechanic code only, no name (PDPA:
/// a shared file name should not carry personal data; the PO precedent is the
/// doc number only). Characters a file system refuses become `-`.
String statementFileName(MechanicRow m, DateTime asOf) {
  final who = m.code
      .replaceAll(RegExp(r'[\\/:*?"<>|\s\x00-\x1F]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'statement-${who.isEmpty ? 'mechanic' : who}-${dateKey(asOf)}.pdf';
}

class MechanicStatementA4View extends StatelessWidget {
  final MechanicRow mechanic;
  final CreditStatement statement;
  final SettingsRowData settings;
  final DateTime asOf;

  const MechanicStatementA4View({
    super.key,
    required this.mechanic,
    required this.statement,
    required this.settings,
    required this.asOf,
  });

  @override
  Widget build(BuildContext context) {
    return PdfPreview(
      build: (format) => buildPdf(format),
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      pdfFileName: statementFileName(mechanic, asOf),
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

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        footer: (ctx) => ctx.pagesCount > 1
            ? pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text(
                  '${mechanic.code}  ${ctx.pageNumber}/${ctx.pagesCount}',
                  style: const pw.TextStyle(fontSize: 8, color: _steel),
                ),
              )
            : pw.SizedBox(),
        build: (ctx) => [
          _header(cond),
          pw.SizedBox(height: 18),
          _meta(cond, semi),
          pw.SizedBox(height: 18),
          _table(cond, semi),
          pw.SizedBox(height: 14),
          _aging(cond),
          pw.SizedBox(height: 10),
          _total(cond),
          pw.SizedBox(height: 6),
          pw.Text(
            'ยอดค้างรวมตามบัญชีช่างของร้าน แจกแจงย้อนจากบิลเครดิตล่าสุด',
            style: const pw.TextStyle(fontSize: 9, color: _steel),
          ),
          pw.SizedBox(height: 40),
          _signatures(cond),
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
                'ใบแจ้งยอด / ใบวางบิล',
                style: pw.TextStyle(font: cond, fontSize: 24, color: _navy),
              ),
              pw.Text(
                'STATEMENT',
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
    final m = mechanic;
    final sub = [
      m.code,
      if ((m.shopName ?? '').trim().isNotEmpty) m.shopName!.trim(),
      if ((m.phone ?? '').trim().isNotEmpty) 'โทร ${m.phone!.trim()}',
    ].join(' · ');
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _label('ช่าง · MECHANIC', cond),
              pw.Text(
                statementMechanicName(m),
                style: pw.TextStyle(font: semi, fontSize: 14, color: _navy),
              ),
              pw.Text(
                sub,
                style: const pw.TextStyle(fontSize: 10, color: _gray),
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [_metaRow('วันที่', thaiDate(asOf), cond)],
          ),
        ),
      ],
    );
  }

  pw.Widget _table(pw.Font cond, pw.Font semi) {
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
    const rowBorder = pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _itemBorder, width: 1)),
    );

    final lines = statement.lines;
    if (statement.noDebt || (lines.isEmpty && !statement.hasResidual)) {
      return pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(16),
        decoration: const pw.BoxDecoration(color: _cream),
        child: pw.Text(
          'ไม่มียอดค้างชำระ',
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(font: semi, fontSize: 13, color: _navy),
        ),
      );
    }
    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(26),
        1: pw.FixedColumnWidth(90),
        2: pw.FlexColumnWidth(),
        3: pw.FixedColumnWidth(60),
        4: pw.FixedColumnWidth(100),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            color: _cream,
            border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 2)),
          ),
          children: [
            th('#', align: pw.Alignment.center),
            th('วันที่'),
            th('เลขที่บิล'),
            th('อายุ (วัน)', align: pw.Alignment.center),
            th('ยอดค้าง', align: pw.Alignment.centerRight),
          ],
        ),
        for (var i = 0; i < lines.length; i++)
          pw.TableRow(
            decoration: rowBorder,
            children: [
              td('${i + 1}', align: pw.Alignment.center, color: _steel),
              td(thaiDate(lines[i].date), color: _gray),
              td(lines[i].receiptNo, font: semi),
              td('${lines[i].ageDays}', align: pw.Alignment.center),
              td(
                baht2(lines[i].outstanding),
                align: pw.Alignment.centerRight,
                font: semi,
              ),
            ],
          ),
        if (statement.hasResidual)
          pw.TableRow(
            decoration: rowBorder,
            children: [
              td(
                '${lines.length + 1}',
                align: pw.Alignment.center,
                color: _steel,
              ),
              td('-', color: _gray),
              td(statementResidualLabel, font: semi),
              td('-', align: pw.Alignment.center),
              td(
                baht2(statement.residual),
                align: pw.Alignment.centerRight,
                font: semi,
              ),
            ],
          ),
      ],
    );
  }

  pw.Widget _aging(pw.Font cond) {
    pw.Widget cell(String label, double v) => pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _itemBorder)),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _label(label, cond),
            pw.Text(
              baht2(v),
              style: const pw.TextStyle(fontSize: 11, color: _navy),
            ),
          ],
        ),
      ),
    );
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _label('อายุหนี้', cond),
        pw.SizedBox(height: 4),
        pw.Row(
          children: [
            for (final b in AgingBucket.values)
              cell(b.label, statement.buckets[b] ?? 0),
            if (statement.hasResidual)
              cell(statementResidualLabel, statement.residual),
          ],
        ),
      ],
    );
  }

  pw.Widget _total(pw.Font cond) => pw.Align(
    alignment: pw.Alignment.centerRight,
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const pw.BoxDecoration(color: _cream),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          // Never a negative debt: a balance <= 0 owes nothing.
          pw.Text(
            'ยอดค้างชำระรวม ${baht2(statement.noDebt ? 0 : statement.total)}',
            style: pw.TextStyle(font: cond, fontSize: 16, color: _orange),
          ),
          if (statement.overpaid > 0)
            pw.Text(
              'ชำระเกิน ${baht2(statement.overpaid)}',
              style: pw.TextStyle(font: cond, fontSize: 11, color: _navy),
            ),
        ],
      ),
    ),
  );

  pw.Widget _signatureBox(String label, pw.Font cond) => pw.SizedBox(
    width: 200,
    child: pw.Column(
      children: [
        pw.Container(
          height: 32,
          margin: const pw.EdgeInsets.only(bottom: 8),
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _gray, width: 1)),
          ),
        ),
        pw.Text(
          label,
          style: pw.TextStyle(font: cond, fontSize: 10, color: _navy),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'วันที่ ........../........../..........',
          style: const pw.TextStyle(fontSize: 9, color: _steel),
        ),
      ],
    ),
  );

  pw.Widget _signatures(pw.Font cond) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      _signatureBox('ผู้วางบิล · ISSUED BY', cond),
      _signatureBox('ผู้รับวางบิล · RECEIVED BY', cond),
    ],
  );
}
