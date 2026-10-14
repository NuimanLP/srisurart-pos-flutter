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

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/server_error_resolver.dart';
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
import '../widgets/sync_status_builder.dart';
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

  void _refresh() => setState(() {
    _quotesFuture = context.read<QuotesRepository>().getQuotes();
  });

  // ── filtering (mirrors JSX `filtered`) ──
  static bool _inFilter(QuoteRow q, _QuoteFilter filter) {
    final expired = q.isExpired;
    final converted = q.isConverted;
    if (filter == _QuoteFilter.open && (converted || expired)) return false;
    if (filter == _QuoteFilter.expired && (converted || !expired)) {
      return false;
    }
    if (filter == _QuoteFilter.converted && !converted) return false;
    return true;
  }

  List<QuoteWithItems> _applyFilter(List<QuoteWithItems> all) {
    final s = _search.trim().toLowerCase();
    return all.where((qi) {
      final q = qi.quote;
      if (!_inFilter(q, _filter)) return false;
      if (s.isEmpty) return true;
      return q.quoteNo.toLowerCase().contains(s) ||
          (q.customerName ?? '').toLowerCase().contains(s);
    }).toList();
  }

  // ── row actions ──
  Future<void> _handleDelete(QuoteRow q) async {
    if (context.isDegraded) {
      _snack('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถลบใบเสนอราคาได้');
      return;
    }
    final repo = context.read<QuotesRepository>();
    final ok = await showConfirm(
      context,
      'ลบใบเสนอราคา',
      'ลบใบเสนอราคา ${q.quoteNo} ?',
      danger: true,
    );
    if (!ok) return;
    try {
      await repo.deleteQuote(q.id);
    } catch (e) {
      _snackError(e);
      return;
    }
    _refresh();
  }

  Future<void> _handleDuplicate(QuoteRow q) async {
    if (context.isDegraded) {
      _snack('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถทำซ้ำใบเสนอราคาได้');
      return;
    }
    final repo = context.read<QuotesRepository>();
    try {
      final dup = await repo.duplicateQuote(q.id);
      if (dup != null) _refresh();
    } catch (e) {
      _snackError(e);
    }
  }

  Future<void> _handleEdit(QuoteWithItems qi) async {
    if (context.isDegraded) {
      _snack('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถแก้ไขใบเสนอราคาได้');
      return;
    }
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
    try {
      await repo.deleteQuote(q.id);
    } catch (e) {
      _snackError(e);
      return;
    }
    _loadToCart(qi);
  }

  Future<void> _handleConvert(QuoteWithItems qi) async {
    if (context.isDegraded) {
      _snack('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถแปลงใบเสนอราคาได้');
      return;
    }
    final q = qi.quote;
    final ok = await showConfirm(
      context,
      'แปลงเป็นการขาย',
      'แปลง ${q.quoteNo} เป็นการขาย? ระบบจะใส่รายการนี้กลับเข้าตะกร้า',
    );
    if (!ok) return;
    // #27 (owner, 2026-10-03, option (ข)): nothing is written here. The quote
    // stays open until the cart is actually sold — checkout sends its id with
    // the bill, and the bill marks it converted in the same transaction. The
    // cashier may edit the cart first; it still converts this quote.
    _loadToCart(qi, forSale: true);
  }

  /// Hand the quote to checkout (pending-cart cubit) and navigate home.
  void _loadToCart(QuoteWithItems qi, {bool forSale = false}) {
    context.read<PendingQuoteCubit>().set(qi, forSale: forSale);
    if (mounted) context.go(AppRoutes.checkout);
  }

  Future<void> _handlePurgeOld() async {
    if (context.isDegraded) {
      _snack('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถล้างใบเสนอราคาได้');
      return;
    }
    final repo = context.read<QuotesRepository>();
    final days = await _promptDays();
    if (days == null || days < 1) return;
    final int n;
    try {
      n = await repo.purgeOldQuotes(olderThanDays: days);
    } catch (e) {
      _snackError(e);
      return;
    }
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

  Future<void> _openPreview(
    QuoteWithItems qi, {
    bool isDegraded = false,
  }) async {
    final SettingsRowData settings;
    try {
      settings = await context.read<SettingsRepository>().getSettings();
    } catch (e) {
      _snackError(e);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _QuotePreviewPage(
          quote: qi,
          settings: settings,
          isDegraded: isDegraded,
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

  /// A failed action shows the counter's Thai sentence — never a raw
  /// `ApiException`/URL — and leaves the screen usable.
  void _snackError(Object e) =>
      _snack(ServerErrorResolver.resolveCounterError(e));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SyncStatusBuilder(
        builder: (context, status, isDegraded) {
          return FutureBuilder<List<QuoteWithItems>>(
            future: _quotesFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const LoadingView();
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline,
                  message: 'โหลดข้อมูลไม่สำเร็จ: ${snap.error}',
                  action: OutlinedButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('ลองใหม่อีกครั้ง'),
                  ),
                );
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

              final header = _Header(
                totalOpen: totalOpen,
                totalValue: totalValue,
                onExport: () => _handleExportCSV(all),
                onPurge: _handlePurgeOld,
                isDegraded: isDegraded,
              );
              final filterBar = _FilterBar(
                filter: _filter,
                counts: {
                  for (final f in _QuoteFilter.values)
                    f: all.where((qi) => _inFilter(qi.quote, f)).length,
                },
                onFilter: (f) => setState(() => _filter = f),
                onSearch: (q) => setState(() => _search = q),
              );
              // Rows built once; the list is a sliver on short screens.
              Widget row(int i) => _QuoteRow(
                item: filtered[i],
                expired: filtered[i].quote.isExpired,
                converted: filtered[i].quote.isConverted,
                onPreview: () =>
                    _openPreview(filtered[i], isDegraded: isDegraded),
                onConvert: () => _handleConvert(filtered[i]),
                onEdit: () => _handleEdit(filtered[i]),
                onDuplicate: () => _handleDuplicate(filtered[i].quote),
                onDelete: () => _handleDelete(filtered[i].quote),
                isDegraded: isDegraded,
              );
              final empty = EmptyState(
                icon: Icons.request_quote_outlined,
                message: all.isEmpty
                    ? 'ยังไม่มีใบเสนอราคา · กดปุ่มในหน้าขายเพื่อบันทึก'
                    : 'ไม่พบรายการ',
              );

              return LayoutBuilder(
                builder: (context, c) {
                  // Short screen (2x–3x zoom, phone landscape): header +
                  // filters would leave no room for the list — scroll
                  // them away with it instead of pinning them.
                  if (c.maxHeight < 520) {
                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(child: header),
                        SliverToBoxAdapter(child: filterBar),
                        if (filtered.isEmpty)
                          SliverFillRemaining(child: empty)
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            sliver: SliverList.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) => row(i),
                            ),
                          ),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      header,
                      filterBar,
                      Expanded(
                        child: filtered.isEmpty
                            ? empty
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  16,
                                ),
                                itemCount: filtered.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) => row(i),
                              ),
                      ),
                    ],
                  );
                },
              );
            },
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
  final bool isDegraded;

  const _Header({
    required this.totalOpen,
    required this.totalValue,
    required this.onExport,
    required this.onPurge,
    this.isDegraded = false,
  });

  @override
  Widget build(BuildContext context) {
    final title = Column(
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
          style: const TextStyle(fontSize: 13, color: AppColors.steelBlue),
        ),
      ],
    );
    final tools = [
      OutlinedButton.icon(
        onPressed: onExport,
        icon: const Icon(Icons.download, size: 18),
        label: const Text('CSV'),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        onPressed: isDegraded ? null : onPurge,
        icon: const Icon(Icons.cleaning_services_outlined, size: 18),
        label: const Text('ล้างเก่า'),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: LayoutBuilder(
        builder: (context, c) {
          // Phone: the tool buttons go under the title instead of squeezing it.
          if (c.maxWidth < 480) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 8),
                Row(children: tools),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: title),
              ...tools,
            ],
          );
        },
      ),
    );
  }
}

// ── Filter pills + search ──
class _FilterBar extends StatelessWidget {
  final _QuoteFilter filter;
  final Map<_QuoteFilter, int> counts;
  final ValueChanged<_QuoteFilter> onFilter;
  final ValueChanged<String> onSearch;

  const _FilterBar({
    required this.filter,
    required this.counts,
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
              final fg = active ? AppColors.white : AppColors.steelBlue;
              return ChoiceChip(
                // The count sits in its own Text so the label stays findable
                // as-is; it tells staff whether a filter is worth opening.
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(e.value),
                    const SizedBox(width: 6),
                    Text(
                      '${counts[e.key] ?? 0}',
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                selected: active,
                showCheckmark: false,
                selectedColor: AppColors.orange,
                labelStyle: TextStyle(color: fg, fontWeight: FontWeight.w700),
                onSelected: (_) => onFilter(e.key),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          SearchField(hint: 'ค้นเลขที่ / ลูกค้า / ช่าง', onChanged: onSearch),
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
  final bool isDegraded;

  const _QuoteRow({
    required this.item,
    required this.expired,
    required this.converted,
    required this.onPreview,
    required this.onConvert,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
    this.isDegraded = false,
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

    final info = InkWell(
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
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 2),
          Text(
            '${item.items.length} รายการ · ${thaiDate(q.date)}',
            style: const TextStyle(fontSize: 12, color: AppColors.steelBlue),
          ),
        ],
      ),
    );
    final amount = Text(
      baht(q.total ?? 0),
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
    );
    final actions = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!converted && !expired)
          _actionBtn(
            '→ ขาย',
            AppColors.successLight,
            isDegraded ? null : onConvert,
            filled: true,
            tooltip: 'แปลงเป็นการขาย',
          ),
        if (!converted)
          _iconBtn(
            Icons.edit,
            AppColors.warning,
            isDegraded ? null : onEdit,
            'แก้ไข (ลบของเก่า ใส่ตะกร้า)',
          ),
        _iconBtn(
          Icons.copy,
          AppColors.info,
          isDegraded ? null : onDuplicate,
          'ทำซ้ำ (ต่ออายุใหม่)',
        ),
        _actionBtn('ดู', AppColors.orange, onPreview),
        // #27 Q2 (owner, 2026-10-03): a converted quote is the record
        // a bill was sold from — the server refuses to delete it.
        if (!converted)
          _iconBtn(
            Icons.delete_outline,
            AppColors.error,
            isDegraded ? null : onDelete,
            'ลบ',
          ),
      ],
    );

    return AppCard(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, c) {
          // Phone / zoomed: a 5-button cluster beside the text starves the
          // quote number and customer — put the actions on their own row.
          if (c.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 12),
                    amount,
                  ],
                ),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: info),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [amount, const SizedBox(height: 6), actions],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tag(bool converted, bool expired, int validDays) {
    if (converted) {
      return _pill('✓ แปลงแล้ว', AppColors.successLight, filled: true);
    }
    if (expired) {
      return _pill(
        'หมดอายุ',
        AppColors.error,
        filled: true,
        icon: Icons.timer_off_outlined,
      );
    }
    // Same label; the colour alone warns that the quote is about to lapse.
    return _pill(
      'ยังใช้ได้ $validDays วัน',
      validDays <= 3 ? AppColors.warning : AppColors.steelBlue,
      icon: Icons.schedule,
    );
  }

  Widget _pill(
    String label,
    Color color, {
    bool filled = false,
    IconData? icon,
  }) {
    final fg = filled ? AppColors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: filled ? null : Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(
    String label,
    Color color,
    VoidCallback? onTap, {
    bool filled = false,
    String? tooltip,
  }) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
            fontSize: 13,
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
    VoidCallback? onTap,
    String tooltip,
  ) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Icon(icon, size: 20, color: color),
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
  final bool isDegraded;

  const _QuotePreviewPage({
    required this.quote,
    required this.settings,
    required this.onConvert,
    this.isDegraded = false,
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
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: isDegraded ? null : onConvert,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: AppColors.white,
                  disabledBackgroundColor: AppColors.navyLight,
                  disabledForegroundColor: AppColors.gray300,
                ),
                child: const Text('✓ แปลงเป็นการขาย'),
              ),
            ),
        ],
      ),
      body: QuoteA4View(quote: q, items: quote.items, settings: settings),
    );
  }
}
