// receipt_view.dart — 58mm thermal receipt (port of pos/Receipt.jsx).
//
// Renders the #receipt-paper equivalent: a narrow (226px) monospace paper with
// shop header, receipt meta, item lines, totals, points, footer. A modal dialog
// (showReceiptDialog) wraps it with พิมพ์ใบเสร็จ / ปิด actions and prints via the
// `printing` package (Printing.layoutPdf) using a PDF rebuild of the same layout.
//
// Behaviour parity with Receipt.jsx:
//  • When a mechanic is set, the receipt shows ONLY the mechanic-quoted prices
//    (item.price already reflects the override); shop price is hidden.
//  • Credit sales (เครดิตช่าง) show "ค้างชำระ (เครดิตช่าง)" instead of paid/change.
//  • Points line only when a customer is attached.
//  • All money via baht(); divider is '- ' * 20 like the JS.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import 'thai_format.dart';

/// One line on the receipt. Mirrors the JS sale.items[i] fields the receipt reads.
class ReceiptLine {
  final String name;
  final String? nameTH;
  final String? partNo;
  final int qty;
  final double price;
  const ReceiptLine({
    required this.name,
    this.nameTH,
    this.partNo,
    required this.qty,
    required this.price,
  });
}

/// All the data the receipt needs. Built by the checkout flow right after
/// saveSale (the persisted SaleRow plus the cart lines + payment context that
/// the SaleRow doesn't carry, e.g. cashReceived / change / customer points).
class ReceiptData {
  final SaleRow sale;
  final List<ReceiptLine> items;
  final SettingsRowData settings;
  final String? customerName;
  final int? customerPoints;
  final double cashReceived;
  final double change;

  const ReceiptData({
    required this.sale,
    required this.items,
    required this.settings,
    this.customerName,
    this.customerPoints,
    required this.cashReceived,
    required this.change,
  });
}

const _divider = '- - - - - - - - - - - - - - - - - - - - ';

/// Shows the receipt modal. Returns when the user closes it.
Future<void> showReceiptDialog(BuildContext context, ReceiptData data) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ReceiptView(data: data),
    ),
  );
}

class ReceiptView extends StatelessWidget {
  final ReceiptData data;
  const ReceiptView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: () => _print(context),
              icon: const Icon(Icons.print, size: 18),
              label: const Text('พิมพ์ใบเสร็จ'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE8601C),
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, size: 18),
              label: const Text('ปิด'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFA8B4C2),
                backgroundColor: const Color(0xFF153660),
                side: const BorderSide(color: Color(0x26FFFFFF)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: SingleChildScrollView(child: _paper()),
        ),
      ],
    );
  }

  Widget _paper() {
    final s = data.settings;
    final sale = data.sale;
    final isMechanicSale = sale.mechanicId != null;
    final isCredit = sale.paymentMethod == 'เครดิตช่าง';

    const mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['Courier New', 'Courier'],
      fontSize: 11,
      color: Color(0xFF111111),
      height: 1.5,
    );

    Widget row(String l, String r, {bool bold = false, double size = 11}) {
      final st = mono.copyWith(
        fontSize: size,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(child: Text(l, style: st)),
            const SizedBox(width: 8),
            Text(r, style: st),
          ],
        ),
      );
    }

    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        _divider,
        style: mono.copyWith(fontSize: 9, color: const Color(0xFF999999)),
      ),
    );

    Widget center(String t, {double size = 10, FontWeight? w, Color? c}) =>
        Text(
          t,
          textAlign: TextAlign.center,
          style: mono.copyWith(
            fontSize: size,
            fontWeight: w,
            color: c ?? const Color(0xFF555555),
          ),
        );

    return Container(
      width: 226,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          center(
            s.shopName,
            size: 14,
            w: FontWeight.w700,
            c: const Color(0xFF111111),
          ),
          center(s.shopNameEN, size: 11, c: const Color(0xFF111111)),
          if ((s.address ?? '').isNotEmpty) center(s.address!),
          center('โทร ${s.phone ?? ''}'),
          divider(),

          // Receipt info
          row('เลขที่', sale.receiptNo),
          row('วันที่', thaiDateTimeSlash(sale.date)),
          row('แคชเชียร์', s.cashierName ?? ''),
          if (data.customerName != null) row('ลูกค้า', data.customerName!),
          if (isMechanicSale) row('ช่าง', sale.mechanicName ?? ''),
          divider(),

          // Items
          for (final it in data.items) ...[
            Text(
              it.name,
              style: mono.copyWith(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            Text(
              '${it.nameTH ?? ''} [${it.partNo ?? ''}]',
              style: mono.copyWith(fontSize: 9, color: const Color(0xFF777777)),
            ),
            row('${it.qty} x ${baht(it.price)}', baht(it.qty * it.price)),
            const SizedBox(height: 2),
          ],
          divider(),

          // Totals
          row('ยอดรวม', baht(sale.subtotal)),
          if (sale.discount > 0) row('ส่วนลด', '-${baht(sale.discount)}'),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0xFFCCCCCC)),
                bottom: BorderSide(color: Color(0xFFCCCCCC)),
              ),
            ),
            child: row('รวมทั้งสิ้น', baht(sale.total), bold: true, size: 13),
          ),
          if (isCredit)
            row('ค้างชำระ (เครดิตช่าง)', baht(sale.total))
          else ...[
            row(
              'ชำระ (${sale.paymentMethod})',
              baht(data.cashReceived != 0 ? data.cashReceived : sale.total),
            ),
            if (data.change > 0) row('เงินทอน', baht(data.change)),
          ],
          divider(),

          // Points
          if (data.customerName != null) ...[
            center('แต้มสะสม +${(sale.total / 10).floor()} แต้ม'),
            center('รวม ${data.customerPoints ?? 0} แต้ม'),
            divider(),
          ],

          // Footer
          center('ขอบคุณที่ใช้บริการ'),
          center('Thank you for your purchase'),
          center('พาร์ทครบ ช่างไว้ใจ'),
        ],
      ),
    );
  }

  Future<void> _print(BuildContext context) async {
    await Printing.layoutPdf(onLayout: (format) => _buildPdf(format));
  }

  Future<Uint8List> _buildPdf(PdfPageFormat _) async {
    final s = data.settings;
    final sale = data.sale;
    final isMechanicSale = sale.mechanicId != null;
    final isCredit = sale.paymentMethod == 'เครดิตช่าง';
    final font = await PdfGoogleFonts.sarabunRegular();
    final fontB = await PdfGoogleFonts.sarabunBold();

    final doc = pw.Document();
    final base = pw.TextStyle(font: font, fontSize: 8);
    final baseB = pw.TextStyle(font: fontB, fontSize: 8);

    pw.Widget row(String l, String r, {bool bold = false, double size = 8}) {
      final st = (bold ? baseB : base).copyWith(fontSize: size);
      return pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: pw.Text(l, style: st)),
          pw.SizedBox(width: 6),
          pw.Text(r, style: st),
        ],
      );
    }

    pw.Widget divider() => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Text(
        '-' * 40,
        style: base.copyWith(fontSize: 6, color: PdfColors.grey600),
      ),
    );

    pw.Widget center(String t, {double size = 7, bool bold = false}) =>
        pw.Center(
          child: pw.Text(
            t,
            textAlign: pw.TextAlign.center,
            style: (bold ? baseB : base).copyWith(
              fontSize: size,
              color: PdfColors.grey800,
            ),
          ),
        );

    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(
          58 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 4 * PdfPageFormat.mm,
        ),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            center(s.shopName, size: 11, bold: true),
            center(s.shopNameEN, size: 8),
            if ((s.address ?? '').isNotEmpty) center(s.address!),
            center('โทร ${s.phone ?? ''}'),
            divider(),
            row('เลขที่', sale.receiptNo),
            row('วันที่', thaiDateTimeSlash(sale.date)),
            row('แคชเชียร์', s.cashierName ?? ''),
            if (data.customerName != null) row('ลูกค้า', data.customerName!),
            if (isMechanicSale) row('ช่าง', sale.mechanicName ?? ''),
            divider(),
            for (final it in data.items) ...[
              pw.Text(it.name, style: baseB),
              pw.Text(
                '${it.nameTH ?? ''} [${it.partNo ?? ''}]',
                style: base.copyWith(fontSize: 6, color: PdfColors.grey700),
              ),
              row('${it.qty} x ${baht(it.price)}', baht(it.qty * it.price)),
              pw.SizedBox(height: 2),
            ],
            divider(),
            row('ยอดรวม', baht(sale.subtotal)),
            if (sale.discount > 0) row('ส่วนลด', '-${baht(sale.discount)}'),
            pw.Container(
              margin: const pw.EdgeInsets.symmetric(vertical: 2),
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  top: pw.BorderSide(color: PdfColors.grey400),
                  bottom: pw.BorderSide(color: PdfColors.grey400),
                ),
              ),
              child: row('รวมทั้งสิ้น', baht(sale.total), bold: true, size: 10),
            ),
            if (isCredit)
              row('ค้างชำระ (เครดิตช่าง)', baht(sale.total))
            else ...[
              row(
                'ชำระ (${sale.paymentMethod})',
                baht(data.cashReceived != 0 ? data.cashReceived : sale.total),
              ),
              if (data.change > 0) row('เงินทอน', baht(data.change)),
            ],
            divider(),
            if (data.customerName != null) ...[
              center('แต้มสะสม +${(sale.total / 10).floor()} แต้ม'),
              center('รวม ${data.customerPoints ?? 0} แต้ม'),
              divider(),
            ],
            center('ขอบคุณที่ใช้บริการ'),
            center('Thank you for your purchase'),
            center('พาร์ทครบ ช่างไว้ใจ'),
          ],
        ),
      ),
    );
    return doc.save();
  }
}
