// QuotesScreen — ใบเสนอราคา (Quotes Manager).
//
// Flutter port of QuotesManager (pos/Quote.jsx). Lists saved quotes with a
// status filter (ทั้งหมด / ยังใช้ได้ / หมดอายุ / แปลงแล้ว) + search by quote-no
// or customer name, and per-row actions: convert (→ ขาย), edit (✎), duplicate
// (⎘), preview (ดู), delete (🗑). Header tools: ⬇ CSV export (csvSafe) and
// 🧹 ล้าง (purge old). Tapping a row or ดู opens the A4 quotation preview
// (QuoteA4View) which carries its own print/convert affordances.
//
// Quotes NEVER touch stock — all reads/writes go through QuotesRepository.
// Convert/edit hand the quote to the checkout cart via PendingQuoteCubit then
// navigate to `/` (see that cubit's note).

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/csv_safe.dart';
import '../../core/utils/file_export.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/quotes_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/aggregates.dart';
import '../blocs/pending_quote_cubit.dart';
import '../widgets/app_card.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/quote_a4_view.dart';
import '../widgets/search_field.dart';
import '../widgets/thai_format.dart';

enum _QuoteFilter { all, open, expired, converted }

class QuotesScreen extends StatefulWidget {
  const QuotesScreen({super.key});

  @override
  State<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends State<QuotesScreen> {
  _QuoteFilter _filter = _QuoteFilter.all;
  String _search = '';
  // Created in initState/_refresh — never inline in build.
  late Future<List<QuoteWithItems>> _quotesFuture;

  @override
  void initState() {
    super.initState();
    _quotesFuture = context.read<QuotesRepository>().getQuotes();
  }

  void _refresh() => setState(
    () => _quotesFuture = context.read<QuotesRepository>().getQuotes(),
  );

  // ── filtering (mirrors JSX `filtered`) ──
  List<QuoteWithItems> _applyFilter(List<QuoteWithItems> all) {
    final s = _search.trim().toLowerCase();
    return all.where((qi) {
      final q = qi.quote;
      final expired = q.isExpired;
      final converted = q.isConverted;
      if (_filter == _QuoteFilter.open && (converted || expired)) return false;
      if (_filter == _QuoteFilter.expired && (converted || !expired)) {
        return false;
      }
      if (_filter == _QuoteFilter.converted && !converted) return false;
      if (s.isEmpty) return true;
      return q.quoteNo.toLowerCase().contains(s) ||
          (q.customerName ?? '').toLowerCase().contains(s);
    }).toList();
  }

  // ── row actions ──
  Future<void> _handleDelete(QuoteRow q) async {
    final repo = context.read<QuotesRepository>();
    final ok = await showConfirm(
      context,
      'ลบใบเสนอราคา',
      'ลบใบเสนอราคา ${q.quoteNo} ?',
      danger: true,
    );
    if (!ok) return;
    await repo.deleteQuote(q.id);
    _refresh();
  }

  Future<void> _handleDuplicate(QuoteRow q) async {
    final dup = await context.read<QuotesRepository>().duplicateQuote(q.id);
    if (dup != null) _refresh();
  }

  Future<void> _handleEdit(QuoteWithItems qi) async {
    final q = qi.quote;
    if (q.isConverted) {
      _snack('ใบนี้แปลงเป็นการขายแล้ว แก้ไขไม่ได้');
      return;
    }
    final repo = context.read<QuotesRepository>();
    final ok = await showConfirm(
      context,
      'แก้ไขใบเสนอราคา',
      'แก้ไข ${q.quoteNo} ? ระบบจะลบใบเดิมและรอให้บันทึกใหม่หลังแก้ไข',
    );
    if (!ok) return;
    await repo.deleteQuote(q.id);
    _loadToCart(qi);
  }

  Future<void> _handleConvert(QuoteWithItems qi) async {
    final q = qi.quote;
    final repo = context.read<QuotesRepository>();
    final ok = await showConfirm(
      context,
      'แปลงเป็นการขาย',
      'แปลง ${q.quoteNo} เป็นการขาย? ระบบจะใส่รายการนี้กลับเข้าตะกร้า',
    );
    if (!ok) return;
    await repo.updateQuote(
      q.id,
      QuotesCompanion(
        status: const Value('converted'),
        convertedAt: Value(DateTime.now()),
      ),
    );
    _loadToCart(qi);
  }

  /// Hand the quote to checkout (pending-cart cubit) and navigate home.
  void _loadToCart(QuoteWithItems qi) {
    context.read<PendingQuoteCubit>().set(qi);
    if (mounted) context.go(AppRoutes.checkout);
  }

  Future<void> _handlePurgeOld() async {
    final repo = context.read<QuotesRepository>();
    final days = await _promptDays();
    if (days == null || days < 1) return;
    final n = await repo.purgeOldQuotes(olderThanDays: days);
    _refresh();
    _snack(n > 0 ? 'ลบ $n ใบเสนอราคา' : 'ไม่มีรายการที่ตรงตามเงื่อนไข');
  }

  Future<int?> _promptDays() async {
    final controller = TextEditingController(text: '90');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ล้างรายการเก่า'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ลบใบเสนอราคาที่หมดอายุ/แปลงแล้วเกินกี่วัน?'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(suffixText: 'วัน'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(int.tryParse(controller.text.trim())),
            child: const Text('ตกลง'),
          ),
        ],
      ),
    );
  }

  // ── CSV export (parity with JSX handleExportCSV: csvSafe + BOM) ──
  Future<void> _handleExportCSV(List<QuoteWithItems> all) async {
    if (all.isEmpty) {
      _snack('ไม่มีข้อมูล');
      return;
    }
    final rows = <List<Object?>>[
      [
        'Quote No',
        'Date',
        'Valid Until',
        'Status',
        'Customer',
        'Mechanic',
        'Items',
        'Subtotal',
        'Discount',
        'Total',
        'Cashier',
      ],
    ];
    for (final qi in all) {
      final q = qi.quote;
      final expired = q.isExpired;
      final status = q.isConverted
          ? 'converted'
          : (expired ? 'expired' : 'open');
      rows.add([
        q.quoteNo,
        _isoDate(q.date),
        _isoDate(q.validUntil),
        status,
        q.customerName ?? '',
        '',
        qi.items.length,
        q.subtotal ?? 0,
        q.discount ?? 0,
        q.total ?? 0,
        '',
      ]);
    }
    final csv = rows
        .map((r) {
          return r
              .map((v) {
                final s = csvSafe(v);
                return RegExp('[",\n]').hasMatch(s)
                    ? '"${s.replaceAll('"', '""')}"'
                    : s;
              })
              .join(',');
        })
        .join('\n');

    try {
      final fileName = 'quotes_${_isoDate(DateTime.now())}.csv';
      // Prefix the UTF-8 BOM exactly like the JS Blob (﻿).
      final path = await exportTextFile(filename: fileName, content: '﻿$csv');
      _snack(path != null ? 'บันทึกไฟล์: $path' : 'ดาวน์โหลด $fileName แล้ว');
    } catch (e) {
      _snack('บันทึกไฟล์ไม่สำเร็จ');
    }
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _openPreview(QuoteWithItems qi) async {
    final settings = await context.read<SettingsRepository>().getSettings();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _QuotePreviewPage(
          quote: qi,
          settings: settings,
          onConvert: () {
            Navigator.of(context).pop();
            _handleConvert(qi);
          },
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<QuoteWithItems>>(
        future: _quotesFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return Center(child: Text('โหลดข้อมูลไม่สำเร็จ: ${snap.error}'));
          }
          final all = snap.data!;
          final openValid = all
              .where((qi) => !qi.quote.isConverted && !qi.quote.isExpired)
              .toList();
          final totalOpen = openValid.length;
          final totalValue = openValid.fold<double>(
            0,
            (s, qi) => s + (qi.quote.total ?? 0),
          );
          final filtered = _applyFilter(all);

          return Column(
            children: [
              _Header(
                totalOpen: totalOpen,
                totalValue: totalValue,
                onExport: () => _handleExportCSV(all),
                onPurge: _handlePurgeOld,
              ),
              _FilterBar(
                filter: _filter,
                onFilter: (f) => setState(() => _filter = f),
                onSearch: (q) => setState(() => _search = q),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? EmptyState(
                        icon: Icons.request_quote_outlined,
                        message: all.isEmpty
                            ? 'ยังไม่มีใบเสนอราคา · กดปุ่มในหน้าขายเพื่อบันทึก'
                            : 'ไม่พบรายการ',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _QuoteRow(
                          item: filtered[i],
                          expired: filtered[i].quote.isExpired,
                          converted: filtered[i].quote.isConverted,
                          onPreview: () => _openPreview(filtered[i]),
                          onConvert: () => _handleConvert(filtered[i]),
                          onEdit: () => _handleEdit(filtered[i]),
                          onDuplicate: () =>
                              _handleDuplicate(filtered[i].quote),
                          onDelete: () => _handleDelete(filtered[i].quote),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Header (title + open count/value + tool buttons) ──
class _Header extends StatelessWidget {
  final int totalOpen;
  final double totalValue;
  final VoidCallback onExport;
  final VoidCallback onPurge;

  const _Header({
    required this.totalOpen,
    required this.totalValue,
    required this.onExport,
    required this.onPurge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '📋 ใบเสนอราคา',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.orange,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$totalOpen ใบยังไม่หมดอายุ · ${baht(totalValue)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.steelBlue,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: onExport,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('CSV'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onPurge,
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: const Text('ล้าง'),
          ),
        ],
      ),
    );
  }
}

// ── Filter pills + search ──
class _FilterBar extends StatelessWidget {
  final _QuoteFilter filter;
  final ValueChanged<_QuoteFilter> onFilter;
  final ValueChanged<String> onSearch;

  const _FilterBar({
    required this.filter,
    required this.onFilter,
    required this.onSearch,
  });

  static const _labels = <_QuoteFilter, String>{
    _QuoteFilter.all: 'ทั้งหมด',
    _QuoteFilter.open: 'ยังใช้ได้',
    _QuoteFilter.expired: 'หมดอายุ',
    _QuoteFilter.converted: 'แปลงแล้ว',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _labels.entries.map((e) {
              final active = filter == e.key;
              return ChoiceChip(
                label: Text(e.value),
                selected: active,
                showCheckmark: false,
                selectedColor: AppColors.orange,
                labelStyle: TextStyle(
                  color: active ? AppColors.white : AppColors.steelBlue,
                  fontWeight: FontWeight.w700,
                ),
                onSelected: (_) => onFilter(e.key),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          SearchField(
            hint: '🔍 ค้นเลขที่ / ลูกค้า / ช่าง',
            onChanged: onSearch,
          ),
        ],
      ),
    );
  }
}

// ── One quote row ──
class _QuoteRow extends StatelessWidget {
  final QuoteWithItems item;
  final bool expired;
  final bool converted;
  final VoidCallback onPreview;
  final VoidCallback onConvert;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  const _QuoteRow({
    required this.item,
    required this.expired,
    required this.converted,
    required this.onPreview,
    required this.onConvert,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final q = item.quote;
    final validDays = expired
        ? 0
        : (q.validUntil.difference(DateTime.now()).inMilliseconds / 86400000)
              .round()
              .clamp(0, 1 << 31);
    final customer = (q.customerName != null && q.customerName!.isNotEmpty)
        ? q.customerName!
        : 'ลูกค้าทั่วไป';

    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // main (tap → preview)
          Expanded(
            child: InkWell(
              onTap: onPreview,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          q.quoteNo,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppColors.orange,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _tag(converted, expired, validDays),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    customer,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${item.items.length} รายการ · ${thaiDate(q.date)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.steelBlue,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // right (amount + actions)
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                baht(q.total ?? 0),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  if (!converted && !expired)
                    _actionBtn(
                      '→ ขาย',
                      AppColors.successLight,
                      onConvert,
                      filled: true,
                      tooltip: 'แปลงเป็นการขาย',
                    ),
                  if (!converted)
                    _iconBtn(
                      Icons.edit,
                      AppColors.warning,
                      onEdit,
                      'แก้ไข (ลบของเก่า ใส่ตะกร้า)',
                    ),
                  _iconBtn(
                    Icons.copy,
                    AppColors.info,
                    onDuplicate,
                    'ทำซ้ำ (ต่ออายุใหม่)',
                  ),
                  _actionBtn('ดู', AppColors.orange, onPreview),
                  _iconBtn(
                    Icons.delete_outline,
                    AppColors.error,
                    onDelete,
                    'ลบ',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tag(bool converted, bool expired, int validDays) {
    if (converted) {
      return _pill('✓ แปลงแล้ว', AppColors.successLight, filled: true);
    }
    if (expired) {
      return _pill('หมดอายุ', AppColors.error, filled: true);
    }
    return _pill('ยังใช้ได้ $validDays วัน', AppColors.steelBlue);
  }

  Widget _pill(String label, Color color, {bool filled = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: filled ? AppColors.white : null,
        ),
      ),
    );
  }

  Widget _actionBtn(
    String label,
    Color color,
    VoidCallback onTap, {
    bool filled = false,
    String? tooltip,
  }) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(5),
          border: filled
              ? null
              : Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: filled ? AppColors.white : color,
          ),
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }

  Widget _iconBtn(
    IconData icon,
    Color color,
    VoidCallback onTap,
    String tooltip,
  ) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}

// ── A4 preview page (hosts QuoteA4View + convert action) ──
class _QuotePreviewPage extends StatelessWidget {
  final QuoteWithItems quote;
  final SettingsRowData settings;
  final VoidCallback onConvert;

  const _QuotePreviewPage({
    required this.quote,
    required this.settings,
    required this.onConvert,
  });

  @override
  Widget build(BuildContext context) {
    final q = quote.quote;
    final isExpired = q.isExpired;
    final canConvert = q.status == 'open' && !isExpired;
    return Scaffold(
      appBar: AppBar(
        title: Text(q.quoteNo),
        actions: [
          if (canConvert)
            TextButton.icon(
              onPressed: onConvert,
              icon: const Icon(Icons.check, color: AppColors.successLight),
              label: const Text(
                '✓ แปลงเป็นการขาย',
                style: TextStyle(color: AppColors.successLight),
              ),
            ),
        ],
      ),
      body: QuoteA4View(quote: q, items: quote.items, settings: settings),
    );
  }
}
