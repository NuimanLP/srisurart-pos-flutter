// SalesTaxReportSection — Settings → ส่งออก CSV → รายงานภาษีขาย (owner approved
// 2026-10-23; spec docs/research/thai-vat-abbreviated-invoice-2026-10-23.md
// §3, §4, §7.4). Owned by settings_screen.dart (CONTRACT §5).
//
// Pick a month, see the report on screen, download it as CSV through the
// export tab's own `_download` (BOM + csvSafe + quote-escape + saved-file
// dialog). The figures come from `domain/reports/sales_tax_report.dart`; this
// file only loads the rows through repositories and lays them out, so it
// reads the same on the Drift build and the API build (local Drift rows —
// bills from another device that never reached this cache are not in it; the
// shop has one till).
//
// A helper for filing, not a tax document: it never prints the words of an
// abbreviated tax invoice (that waits on ภ.พ.06, doc §8 O1). Every Thai string
// here is `agent ร่าง` (02_API_SCREENS.md §8.1.1).

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../core/utils/tax_identity.dart';
import '../../data/db/database.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/reports/sales_tax_report.dart';
import 'thai_format.dart';

/// The disclaimer shown on screen and written into the CSV — agent ร่าง.
const salesTaxDisclaimer =
    'รายงานนี้เป็นตัวช่วยเตรียมยื่นภาษี ไม่ใช่เอกสารทางภาษี '
    'กรุณาตรวจตัวเลขกับนักบัญชีหรือสรรพากรก่อนยื่น';

/// ภ.พ.30 field labels of the footer (doc §4) — agent ร่าง.
const salesTaxBaseLabel = 'ยอดขายในเดือนนี้ (ภ.พ.30 ช่อง 1)';
const salesTaxTaxableLabel = 'ยอดขายที่ต้องเสียภาษี (ภ.พ.30 ช่อง 4)';
const salesTaxVatLabel = 'ภาษีขายเดือนนี้ (ภ.พ.30 ช่อง 5)';

String _roundingNote(double rate) {
  final r = formatRate(rate);
  return 'ราคาขายรวม VAT แล้ว · VAT = ยอดรวม × $r/(100+$r) '
      'ปัดเศษเป็นสตางค์ทีละบรรทัด (รายวัน/รายใบลดหนี้) · '
      'ช่อง 2 (อัตรา 0%) และช่อง 3 (ยกเว้น) ถือเป็น 0 · '
      'เลขช่องอ้างอิงแบบ ภ.พ.30 พิมพ์ 2568 กรุณาเทียบกับแบบที่ใช้ยื่นจริง';
}

/// Satang as a CSV money cell: `1234.50`, negatives in accounting brackets
/// `(107.00)`. Brackets, not a minus sign: csvSafe (which every cell passes,
/// CONTRACT §7) turns a leading `-` into `'-…` text, while Excel reads
/// `(107.00)` as the number −107.
String csvMoney(int satang) {
  final abs = satang.abs();
  final text = '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  return satang < 0 ? '($text)' : text;
}

String _docCell(SalesTaxLine l) => l.docNo.isEmpty ? '-' : l.docNo;

String _remark(SalesTaxLine l) {
  if (l.kind == SalesTaxLineKind.creditNote) return 'ใบลดหนี้';
  final parts = ['รวม ${l.billCount} บิล'];
  if (l.voidedReceiptNos.isNotEmpty) {
    parts.add('ยกเลิก (ไม่นับ): ${l.voidedReceiptNos.join(', ')}');
  }
  return parts.join(' · ');
}

/// The CSV rows of [report]: a header block (shop, tax id, branch, month,
/// rate, disclaimer), one row per line (N89 columns — buyer columns stay
/// empty: day lines need none, a credit note's buyer is not recorded), then
/// the ภ.พ.30 figures.
List<List<Object?>> salesTaxCsvRows(
  SalesTaxReport report,
  SettingsRowData settings,
) {
  final taxId = (settings.taxId ?? '').trim();
  final branch = branchLabel(settings.branchNo);
  return [
    ['รายงานภาษีขาย'],
    ['เดือนภาษี', thaiMonthYear(DateTime(report.year, report.month))],
    ['ชื่อผู้ประกอบการ', settings.shopName],
    ['เลขประจำตัวผู้เสียภาษี', taxId.isEmpty ? '-' : formatTaxId(taxId)],
    ['สถานประกอบการ', branch.isEmpty ? '-' : branch],
    ['อัตราภาษี', '${formatRate(report.taxRate)}%'],
    ['หมายเหตุ', salesTaxDisclaimer],
    ['การคำนวณ', _roundingNote(report.taxRate)],
    [],
    [
      'ลำดับ',
      'วันที่',
      'เลขที่เอกสาร',
      'อ้างอิงเอกสารเดิม',
      'ชื่อผู้ซื้อ',
      'เลขประจำตัวผู้เสียภาษีผู้ซื้อ',
      'สาขา (ผู้ซื้อ)',
      'มูลค่าสินค้า (ไม่รวม VAT)',
      'ภาษีมูลค่าเพิ่ม',
      'รวม',
      'หมายเหตุ',
    ],
    for (final (i, l) in report.lines.indexed)
      [
        i + 1,
        thaiDateSlash(l.date),
        _docCell(l),
        l.refReceiptNo ?? '',
        '',
        '',
        '',
        csvMoney(l.baseSatang),
        csvMoney(l.vatSatang),
        csvMoney(l.totalSatang),
        _remark(l),
      ],
    [],
    [salesTaxBaseLabel, csvMoney(report.baseSatang)],
    [salesTaxTaxableLabel, csvMoney(report.baseSatang)],
    [salesTaxVatLabel, csvMoney(report.vatSatang)],
    ['ยอดขายรวม VAT สุทธิ', csvMoney(report.totalSatang)],
  ];
}

class _Loaded {
  final SalesTaxReport report;
  final SettingsRowData settings;
  const _Loaded(this.report, this.settings);
}

class SalesTaxReportSection extends StatefulWidget {
  const SalesTaxReportSection({
    super.key,
    required this.onDownloadCsv,
    this.initialMonth,
  });

  /// The export tab's CSV download (`_ExportTabState._download`).
  final Future<void> Function(List<List<Object?>> rows, String filename)
  onDownloadCsv;

  /// Month shown first; default = last month (the one ภ.พ.30 is filed for).
  final DateTime? initialMonth;

  @override
  State<SalesTaxReportSection> createState() => _SalesTaxReportSectionState();
}

class _SalesTaxReportSectionState extends State<SalesTaxReportSection> {
  late DateTime _month;
  late Future<_Loaded> _future;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final m = widget.initialMonth ?? DateTime(now.year, now.month - 1);
    _month = DateTime(m.year, m.month);
    _future = _load();
  }

  Future<_Loaded> _load() async {
    final salesRepo = context.read<SalesRepository>();
    final returnsRepo = context.read<ReturnsRepository>();
    final settings = await context.read<SettingsRepository>().getSettings();
    final from = DateTime(_month.year, _month.month);
    final to = DateTime(_month.year, _month.month + 1);
    final sales = [
      for (final s in await salesRepo.getSales(from: from, to: to)) s.sale,
    ];
    final returns = [
      for (final r in await returnsRepo.getReturns(from: from, to: to)) r.ret,
    ];
    // A voided bill is an auto-void when it has a credit note at any time —
    // possibly dated after this month.
    final returned = {
      for (final r in await returnsRepo.getReturnsForSales(
        sales.where((s) => s.voided).map((s) => s.id),
      ))
        r.saleId,
    };
    final report = buildSalesTaxReport(
      year: _month.year,
      month: _month.month,
      taxRate: settings.taxRate,
      sales: sales,
      returns: returns,
      returnedSaleIds: returned,
    );
    return _Loaded(report, settings);
  }

  void _shift(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _future = _load();
    });
  }

  bool get _isCurrentOrLater {
    final now = DateTime.now();
    return !_month.isBefore(DateTime(now.year, now.month));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'รายงานภาษีขาย (สำหรับยื่น ภ.พ.30)',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'สรุปยอดขายรายวันและใบลดหนี้ของเดือนที่เลือก แยกมูลค่าสินค้ากับภาษีมูลค่าเพิ่ม',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.secondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        _Disclaimer(),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left_rounded),
              tooltip: 'เดือนก่อน',
              onPressed: () => _shift(-1),
            ),
            Expanded(
              child: Text(
                thaiMonthYear(_month),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right_rounded),
              tooltip: 'เดือนถัดไป',
              onPressed: _isCurrentOrLater ? null : () => _shift(1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FutureBuilder<_Loaded>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return Text(
                'โหลดรายงานไม่สำเร็จ: ${snap.error}',
                style: const TextStyle(color: AppColors.error),
              );
            }
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _ReportBody(
              loaded: snap.data!,
              onDownload: () => widget.onDownloadCsv(
                salesTaxCsvRows(snap.data!.report, snap.data!.settings),
                'sales-tax-${_month.year}-'
                '${_month.month.toString().padLeft(2, '0')}.csv',
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Disclaimer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark ? AppColors.warningBannerDark : AppColors.warningBanner,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        salesTaxDisclaimer,
        style: TextStyle(
          color: dark ? AppColors.warningTextOnDark : AppColors.warningText,
          fontWeight: FontWeight.w600,
          height: 1.5,
        ),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.loaded, required this.onDownload});
  final _Loaded loaded;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = loaded.report;
    final s = loaded.settings;
    final taxId = (s.taxId ?? '').trim();
    final branch = branchLabel(s.branchNo);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.secondary,
      height: 1.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.shopName, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(
          taxId.isEmpty
              ? 'ยังไม่ได้กรอกเลขประจำตัวผู้เสียภาษี — กรอกได้ที่แท็บ ทั่วไป'
              : 'เลขประจำตัวผู้เสียภาษี ${formatTaxId(taxId)}',
          style: taxId.isEmpty
              ? const TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.w600,
                )
              : null,
        ),
        Text('สถานประกอบการ ${branch.isEmpty ? '-' : branch}'),
        Text(
          'อัตราภาษี ${formatRate(report.taxRate)}%',
        ),
        const SizedBox(height: 12),
        if (report.lines.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'ไม่มีบิลขายหรือใบลดหนี้ในเดือนนี้',
              textAlign: TextAlign.center,
              style: muted,
            ),
          )
        else
          for (final l in report.lines) _LineTile(line: l),
        const Divider(height: 24),
        _Total(label: salesTaxBaseLabel, satang: report.baseSatang),
        _Total(label: salesTaxTaxableLabel, satang: report.baseSatang),
        _Total(label: salesTaxVatLabel, satang: report.vatSatang, strong: true),
        const SizedBox(height: 8),
        Text(_roundingNote(report.taxRate), style: muted),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: onDownload,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
              minimumSize: const Size(0, 44),
            ),
            child: const Text('⬇ ดาวน์โหลด CSV'),
          ),
        ),
      ],
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line});
  final SalesTaxLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cn = line.kind == SalesTaxLineKind.creditNote;
    final title = cn
        ? 'ใบลดหนี้ ${line.docNo} · อ้างอิง ${line.refReceiptNo ?? '-'}'
        : _docCell(line);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${thaiDate(line.date)} · $title',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cn ? AppColors.error : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                baht2(line.totalSatang / 100),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          Text(
            'มูลค่า ${baht2(line.baseSatang / 100)} · '
            'VAT ${baht2(line.vatSatang / 100)}'
            '${cn ? '' : ' · ${_remark(line)}'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.secondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.satang, this.strong = false});
  final String label;
  final int satang;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
      fontSize: strong ? 16 : 14,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 8),
          Text(baht2(satang / 100), style: style),
        ],
      ),
    );
  }
}
