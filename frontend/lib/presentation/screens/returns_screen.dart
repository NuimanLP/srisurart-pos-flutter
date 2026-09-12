// ReturnsScreen — คืนสินค้า / Returns / Void Bill / Credit Notes.
//
// Flutter port of pos/ReturnsScreen.jsx (384 lines). Behaviour parity:
//  • LEFT pane: tabs ค้นหาบิล / ประวัติการคืน. Search bills by receiptNo /
//    mechanicName / item name (no query → 50 most recent; query → up to 200).
//    History tab lists credit notes (CN) newest-first.
//  • RIGHT pane: pick a bill → choose lines + qty to refund, respecting
//    remaining = sold − alreadyRefunded (salesRepoProvider.getRefundedQty),
//    pick refund method (เงินสด / โอน / หักจากเครดิต when mechanic), reason,
//    submit → returnsRepoProvider.createReturn(ReturnInput). Plus ยกเลิกบิลทั้งบิล.
//  • The repository handles over-refund Thai error, proportional discount
//    reversal and auto-void; the screen surfaces the resulting CreditNote.
//
// Money via baht()/MoneyText. IDs/doc-numbers come from the repository.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/aggregates.dart';
import '../widgets/app_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/search_field.dart';
import '../widgets/thai_format.dart';

typedef _ReturnsData = ({
  List<SaleWithItems> sales,
  List<ReturnWithItems> returns,
});

enum _Tab { search, history }

class ReturnsScreen extends StatefulWidget {
  const ReturnsScreen({super.key});

  @override
  State<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends State<ReturnsScreen> {
  _Tab _tab = _Tab.search;
  String _search = '';
  SaleWithItems? _selected;
  final Map<String, int> _refundQtys = {}; // productId → qty to refund
  String _refundMethod = 'เงินสด';
  String _reason = '';
  bool _busy = false;
  final TextEditingController _reasonCtl = TextEditingController();
  // Created in initState/_refreshAll — never inline in build.
  late Future<_ReturnsData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_ReturnsData> _loadData() async {
    final salesRepo = context.read<SalesRepository>();
    final returnsRepo = context.read<ReturnsRepository>();
    final sales = await salesRepo.getSales();
    final returns = await returnsRepo.getReturns();
    return (sales: sales, returns: returns);
  }

  @override
  void dispose() {
    _reasonCtl.dispose();
    super.dispose();
  }

  void _refreshAll() => setState(() {
    _dataFuture = _loadData();
  });

  void _selectSale(SaleWithItems s) {
    setState(() {
      _selected = s;
      _refundQtys.clear();
      for (final i in s.items) {
        _refundQtys[i.productId] = 0;
      }
      _reason = '';
      _reasonCtl.text = '';
      // Credit sales default to "หักจากเครดิต" — prevents double refund.
      _refundMethod = s.sale.paymentMethod == 'เครดิตช่าง'
          ? 'หักจากเครดิต'
          : 'เงินสด';
    });
  }

  void _setQty(String pid, int val, int max) {
    final v = val < 0 ? 0 : (val > max ? max : val);
    setState(() => _refundQtys[pid] = v);
  }

  // ── Derived refund lines + amounts (mirror the JSX computation). ──
  List<ReturnLineInput> _refundItems() {
    final s = _selected;
    if (s == null) return const [];
    return [
      for (final i in s.items)
        if ((_refundQtys[i.productId] ?? 0) > 0)
          ReturnLineInput(
            productId: i.productId,
            name: i.name,
            qty: _refundQtys[i.productId]!,
            price: i.price,
            originalQty: i.qty,
          ),
    ];
  }

  double _refundSubtotal(List<ReturnLineInput> items) =>
      items.fold<double>(0, (s, i) => s + i.price * i.qty);

  double _refundTotal(List<ReturnLineInput> items) {
    final s = _selected!;
    final sub = _refundSubtotal(items);
    final ratio = s.sale.subtotal > 0
        ? (s.sale.discount) / s.sale.subtotal
        : 0.0;
    final disc = round2(sub * ratio);
    return round2(sub - disc);
  }

  double _refundDiscount(List<ReturnLineInput> items) {
    final s = _selected!;
    final sub = _refundSubtotal(items);
    final ratio = s.sale.subtotal > 0
        ? (s.sale.discount) / s.sale.subtotal
        : 0.0;
    return round2(sub * ratio);
  }

  Future<void> _submit(Map<String, int> refunded) async {
    if (_busy) return;
    final s = _selected!;
    final items = _refundItems();
    if (items.isEmpty) {
      _toast('กรุณาเลือกสินค้าที่จะคืน');
      return;
    }
    if (s.sale.paymentMethod == 'เครดิตช่าง' && _refundMethod == 'เงินสด') {
      final ok = await showConfirm(
        context,
        'คืนเป็นเงินสด?',
        'บิลนี้เป็นการขายเครดิต — การคืนเป็นเงินสดจะไม่ลดยอดเครดิตของช่าง\n\nแนะนำให้ใช้ "หักจากเครดิต" เพื่อลดยอดที่ค้าง\n\nยืนยันคืนเป็นเงินสด?',
        danger: true,
      );
      if (!ok) return;
    }
    final total = _refundTotal(items);
    if (!mounted) return;
    final ok = await showConfirm(
      context,
      'ยืนยันการคืนสินค้า',
      'ยืนยันการคืนสินค้า ${items.length} รายการ มูลค่า ${baht(total)}?\n\nสต็อกจะถูกคืน + ยอดลูกค้า/ช่างจะถูกลบออก',
      danger: true,
    );
    if (!ok) return;
    await _doReturn(items);
  }

  Future<void> _voidWholeBill(Map<String, int> refunded) async {
    if (_busy || _selected == null) return;
    final s = _selected!;
    final allRemaining = <ReturnLineInput>[
      for (final i in s.items)
        if (i.qty - (refunded[i.productId] ?? 0) > 0)
          ReturnLineInput(
            productId: i.productId,
            name: i.name,
            qty: i.qty - (refunded[i.productId] ?? 0),
            price: i.price,
            originalQty: i.qty,
          ),
    ];
    if (allRemaining.isEmpty) {
      _toast('บิลนี้คืนหมดแล้ว');
      return;
    }
    final ok = await showConfirm(
      context,
      'ยกเลิกบิลทั้งบิล',
      'ยกเลิกบิล ${s.sale.receiptNo} ทั้งบิล?\n\nคืนสินค้าทุกรายการ + คืนเงินทั้งหมด',
      danger: true,
    );
    if (!ok) return;
    await _doReturn(
      allRemaining,
      reasonOverride: _reason.isNotEmpty ? _reason : 'ยกเลิกบิลทั้งบิล',
    );
  }

  Future<void> _doReturn(
    List<ReturnLineInput> items, {
    String? reasonOverride,
  }) async {
    final s = _selected!;
    final repo = context.read<ReturnsRepository>();
    setState(() => _busy = true);
    try {
      final cn = await repo.createReturn(
        ReturnInput(
          saleId: s.sale.id,
          items: items,
          refundMethod: _refundMethod,
          reason: reasonOverride ?? _reason,
        ),
      );
      if (!mounted) return;
      setState(() {
        _selected = null;
        _refundQtys.clear();
        _reason = '';
        _reasonCtl.text = '';
      });
      _refreshAll();
      await _showCreditNote(_cnFromRow(cn, items));
    } catch (e) {
      if (mounted) _toast('เกิดข้อผิดพลาด: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _msg(Object e) =>
      e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Pairs the freshly-created ReturnRow with the line inputs used (the row
  /// alone carries no items aggregate). For history taps we already have items.
  ReturnWithItems _cnFromRow(ReturnRow cn, List<ReturnLineInput> items) {
    return ReturnWithItems(cn, [
      for (final i in items)
        ReturnItemRow(
          rowId: 0,
          returnId: cn.id,
          productId: i.productId,
          name: i.name,
          qty: i.qty,
          price: i.price,
          originalQty: i.originalQty,
        ),
    ]);
  }

  Future<void> _showCreditNote(ReturnWithItems cn) async {
    final settings = await context.read<SettingsRepository>().getSettings();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _CreditNoteDialog(cn: cn, settings: settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      body: FutureBuilder<_ReturnsData>(
        future: _dataFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return Center(child: Text('โหลดข้อมูลไม่สำเร็จ: ${snap.error}'));
          }
          final sales = snap.data!.sales;
          final returns = snap.data!.returns;

          final left = _LeftPane(
            tab: _tab,
            sales: sales,
            returns: returns,
            search: _search,
            selectedId: _selected?.sale.id,
            onTab: (t) => setState(() => _tab = t),
            onSearch: (q) => setState(() => _search = q),
            onSelectSale: _selectSale,
            onOpenCreditNote: (cn) async {
              final settingsRepo = context.read<SettingsRepository>();
              final settings = await settingsRepo.getSettings();
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (_) => _CreditNoteDialog(cn: cn, settings: settings),
              );
            },
          );
          final right = _selected == null
              ? const _EmptyDetail()
              : _RefundDetail(
                  key: ValueKey(_selected!.sale.id),
                  sale: _selected!,
                  refundQtys: _refundQtys,
                  refundMethod: _refundMethod,
                  reasonController: _reasonCtl,
                  busy: _busy,
                  onClose: () => setState(() => _selected = null),
                  onSetQty: _setQty,
                  onMethod: (m) => setState(() => _refundMethod = m),
                  onReason: (r) => _reason = r,
                  refundItems: _refundItems,
                  refundSubtotal: _refundSubtotal,
                  refundDiscount: _refundDiscount,
                  refundTotal: _refundTotal,
                  onSubmit: _submit,
                  onVoid: _voidWholeBill,
                );

          final divider = VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).dividerColor,
          );

          return wide
              ? Row(
                  children: [
                    SizedBox(width: 460, child: left),
                    divider,
                    Expanded(child: right),
                  ],
                )
              : (_selected == null ? left : right);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LEFT PANE — header + tabs + (search list | history list).
// ─────────────────────────────────────────────────────────────────────────────
class _LeftPane extends StatelessWidget {
  final _Tab tab;
  final List<SaleWithItems> sales;
  final List<ReturnWithItems> returns;
  final String search;
  final String? selectedId;
  final ValueChanged<_Tab> onTab;
  final ValueChanged<String> onSearch;
  final void Function(SaleWithItems sale) onSelectSale;
  final ValueChanged<ReturnWithItems> onOpenCreditNote;

  const _LeftPane({
    required this.tab,
    required this.sales,
    required this.returns,
    required this.search,
    required this.selectedId,
    required this.onTab,
    required this.onSearch,
    required this.onSelectSale,
    required this.onOpenCreditNote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalRefund = returns.fold<double>(
      0,
      (s, r) => s + r.ret.refundTotal,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'คืนสินค้า · Returns',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${returns.length} ใบลดหนี้ · มูลค่าคืนรวม ${baht(totalRefund)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Tabs.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _TabButton(
                label: 'ค้นหาบิล',
                active: tab == _Tab.search,
                onTap: () => onTab(_Tab.search),
              ),
              _TabButton(
                label: 'ประวัติการคืน (${returns.length})',
                active: tab == _Tab.history,
                onTap: () => onTab(_Tab.history),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tab == _Tab.search
              ? _SearchTab(
                  sales: sales,
                  search: search,
                  selectedId: selectedId,
                  onSearch: onSearch,
                  onSelectSale: onSelectSale,
                )
              : _HistoryTab(returns: returns, onOpen: onOpenCreditNote),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: active ? AppColors.orange : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: active
                ? AppColors.orange
                : Theme.of(context).colorScheme.secondary,
          ),
        ),
      ),
    );
  }
}

// ── Search tab: search box + scrollable sale cards. ──
class _SearchTab extends StatelessWidget {
  final List<SaleWithItems> sales;
  final String search;
  final String? selectedId;
  final ValueChanged<String> onSearch;
  final void Function(SaleWithItems sale) onSelectSale;

  const _SearchTab({
    required this.sales,
    required this.search,
    required this.selectedId,
    required this.onSearch,
    required this.onSelectSale,
  });

  @override
  Widget build(BuildContext context) {
    final q = search.toLowerCase();
    final matching = sales.where((s) {
      if (search.isEmpty) return true;
      final r = s.sale;
      return r.receiptNo.toLowerCase().contains(q) ||
          (r.mechanicName ?? '').contains(search) ||
          s.items.any((i) => i.name.toLowerCase().contains(q));
    }).toList();
    final filtered = search.isNotEmpty
        ? matching.take(200).toList()
        : matching.take(50).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: SearchField(
            hint: '🔍 ค้นเลขที่บิล RC... / ชื่อสินค้า / ชื่อช่าง',
            autofocus: true,
            onChanged: onSearch,
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const EmptyState(message: 'ไม่พบบิล')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  itemCount: filtered.length,
                  itemBuilder: (_, idx) => _SaleCard(
                    sale: filtered[idx],
                    active: filtered[idx].sale.id == selectedId,
                    onSelectSale: onSelectSale,
                  ),
                ),
        ),
      ],
    );
  }
}

class _SaleCard extends StatefulWidget {
  final SaleWithItems sale;
  final bool active;
  final void Function(SaleWithItems sale) onSelectSale;

  const _SaleCard({
    required this.sale,
    required this.active,
    required this.onSelectSale,
  });

  @override
  State<_SaleCard> createState() => _SaleCardState();
}

class _SaleCardState extends State<_SaleCard> {
  // Already-refunded qty (productId → qty) for this sale — created once in
  // initState — never inline in build.
  late Future<Map<String, int>> _refundedFuture;

  @override
  void initState() {
    super.initState();
    _refundedFuture = context.read<SalesRepository>().getRefundedQty(
      widget.sale.sale.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sale = widget.sale;
    final active = widget.active;
    final s = sale.sale;
    return FutureBuilder<Map<String, int>>(
      future: _refundedFuture,
      builder: (context, snap) {
        final refunded = snap.data ?? const <String, int>{};
        final totalRefunded = refunded.values.fold<int>(0, (a, b) => a + b);
        final totalQty = sale.items.fold<int>(0, (a, i) => a + i.qty);
        final isVoided = s.voided;
        final isPartial = totalRefunded > 0 && !isVoided;

        return Opacity(
          opacity: isVoided ? 0.5 : 1,
          child: Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: active ? AppColors.orange : theme.dividerColor,
                width: active ? 2 : 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: isVoided ? null : () => widget.onSelectSale(sale),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.receiptNo,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: AppColors.orange,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            thaiDateTime(s.date),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${sale.items.length} รายการ · ${s.paymentMethod}'
                            '${s.mechanicName != null ? ' · 🔧 ${s.mechanicName}' : ''}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          baht(s.total),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (isVoided)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _Pill(
                              '✕ ยกเลิกแล้ว',
                              color: AppColors.error,
                            ),
                          ),
                        if (isPartial)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _Pill(
                              '↻ คืนบางส่วน $totalRefunded/$totalQty',
                              color: AppColors.warning,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ── History tab: list of credit notes. ──
class _HistoryTab extends StatelessWidget {
  final List<ReturnWithItems> returns;
  final ValueChanged<ReturnWithItems> onOpen;
  const _HistoryTab({required this.returns, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (returns.isEmpty) {
      return const EmptyState(message: 'ยังไม่มีประวัติการคืนสินค้า');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      itemCount: returns.length,
      itemBuilder: (_, idx) {
        final rw = returns[idx];
        final r = rw.ret;
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.dividerColor),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onOpen(rw),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.cnNo,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: AppColors.error,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'อ้างอิง ${r.receiptNo} · ${thaiDateTime(r.date)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${rw.items.length} รายการ · ${r.refundMethod}'
                          '${r.mechanicName != null ? ' · 🔧 ${r.mechanicName}' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (r.reason.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '"${r.reason}"',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    '−${baht(r.refundTotal)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RIGHT PANE — refund detail for the selected sale.
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '↻',
              style: TextStyle(
                fontSize: 48,
                color: theme.colorScheme.secondary.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'เลือกบิลที่ต้องการคืน',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                'ค้นหาเลขที่บิล RC... ทางซ้าย แล้วเลือกรายการสินค้าที่ต้องการคืน ระบบจะคืนสต็อกและลบยอดออกอัตโนมัติ',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RefundDetail extends StatefulWidget {
  final SaleWithItems sale;
  final Map<String, int> refundQtys;
  final String refundMethod;
  final TextEditingController reasonController;
  final bool busy;
  final VoidCallback onClose;
  final void Function(String pid, int val, int max) onSetQty;
  final ValueChanged<String> onMethod;
  final ValueChanged<String> onReason;
  final List<ReturnLineInput> Function() refundItems;
  final double Function(List<ReturnLineInput>) refundSubtotal;
  final double Function(List<ReturnLineInput>) refundDiscount;
  final double Function(List<ReturnLineInput>) refundTotal;
  final Future<void> Function(Map<String, int>) onSubmit;
  final Future<void> Function(Map<String, int>) onVoid;

  const _RefundDetail({
    super.key,
    required this.sale,
    required this.refundQtys,
    required this.refundMethod,
    required this.reasonController,
    required this.busy,
    required this.onClose,
    required this.onSetQty,
    required this.onMethod,
    required this.onReason,
    required this.refundItems,
    required this.refundSubtotal,
    required this.refundDiscount,
    required this.refundTotal,
    required this.onSubmit,
    required this.onVoid,
  });

  @override
  State<_RefundDetail> createState() => _RefundDetailState();
}

class _RefundDetailState extends State<_RefundDetail> {
  // Already-refunded qty for this sale — created once in initState — never
  // inline in build.
  late Future<Map<String, int>> _refundedFuture;

  @override
  void initState() {
    super.initState();
    _refundedFuture = context.read<SalesRepository>().getRefundedQty(
      widget.sale.sale.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.sale.sale;

    return FutureBuilder<Map<String, int>>(
      future: _refundedFuture,
      builder: (context, snap) {
        final refunded = snap.data ?? const <String, int>{};

        final items = widget.refundItems();
        final sub = widget.refundSubtotal(items);
        final disc = widget.refundDiscount(items);
        final total = widget.refundTotal(items);

        final methods = <String>[
          'เงินสด',
          'โอน',
          if (s.mechanicId != null) 'หักจากเครดิต',
        ];

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.receiptNo,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${thaiDateTime(s.date)} · ${s.paymentMethod}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                        if (s.mechanicName != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '🔧 ${s.mechanicName}',
                              style: const TextStyle(
                                color: AppColors.warning,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                    tooltip: 'ปิด',
                  ),
                ],
              ),
              const Divider(height: 24),
              Text(
                'เลือกรายการที่จะคืน',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(height: 10),
              // Item list.
              Expanded(
                child: ListView.separated(
                  itemCount: widget.sale.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, idx) {
                    final i = widget.sale.items[idx];
                    final refundedQty = refunded[i.productId] ?? 0;
                    final remaining = i.qty - refundedQty;
                    final current = widget.refundQtys[i.productId] ?? 0;
                    final fully = remaining <= 0;
                    return _ItemRow(
                      item: i,
                      refundedQty: refundedQty,
                      remaining: remaining,
                      current: current,
                      fully: fully,
                      onSetQty: widget.onSetQty,
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              // Summary + actions.
              _SummaryBox(
                sub: sub,
                disc: disc,
                total: total,
                methods: methods,
                refundMethod: widget.refundMethod,
                reasonController: widget.reasonController,
                busy: widget.busy,
                itemCount: items.length,
                onMethod: widget.onMethod,
                onReason: widget.onReason,
                onSubmit: () => widget.onSubmit(refunded),
                onVoid: () => widget.onVoid(refunded),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ItemRow extends StatelessWidget {
  final SaleItemRow item;
  final int refundedQty;
  final int remaining;
  final int current;
  final bool fully;
  final void Function(String pid, int val, int max) onSetQty;

  const _ItemRow({
    required this.item,
    required this.refundedQty,
    required this.remaining,
    required this.current,
    required this.fully,
    required this.onSetQty,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlighted = current > 0;

    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Wrap(
          children: [
            Text(
              'ขายไป ${item.qty} × ${baht(item.price)}',
              style: theme.textTheme.bodySmall,
            ),
            if (refundedQty > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '· คืนแล้ว $refundedQty',
                  style: const TextStyle(
                    color: AppColors.error,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            if (fully)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Text(
                  '· คืนหมดแล้ว',
                  style: TextStyle(
                    color: AppColors.error,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ],
    );

    final stepper = _QtyStepper(
      productId: item.productId,
      current: current,
      remaining: remaining,
      fully: fully,
      onSetQty: onSetQty,
    );

    final amount = SizedBox(
      width: 90,
      child: Text(
        current > 0 ? '−${baht(item.price * current)}' : '—',
        textAlign: TextAlign.right,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 16,
          color: current > 0 ? AppColors.error : theme.colorScheme.secondary,
        ),
      ),
    );

    return Opacity(
      opacity: fully ? 0.4 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: highlighted
              ? AppColors.error.withValues(alpha: 0.06)
              : theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: highlighted
                ? AppColors.error.withValues(alpha: 0.3)
                : theme.dividerColor,
          ),
        ),
        // Below ~520dp the ~300dp stepper+amount cluster can starve the name to
        // zero and overflow, so stack: row1 = name + amount, row2 = stepper.
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: nameBlock),
                      const SizedBox(width: 8),
                      amount,
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: stepper),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: nameBlock),
                stepper,
                const SizedBox(width: 8),
                amount,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QtyStepper extends StatefulWidget {
  final String productId;
  final int current;
  final int remaining;
  final bool fully;
  final void Function(String pid, int val, int max) onSetQty;

  const _QtyStepper({
    required this.productId,
    required this.current,
    required this.remaining,
    required this.fully,
    required this.onSetQty,
  });

  @override
  State<_QtyStepper> createState() => _QtyStepperState();
}

class _QtyStepperState extends State<_QtyStepper> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: '${widget.current}');
  }

  @override
  void didUpdateWidget(_QtyStepper old) {
    super.didUpdateWidget(old);
    if (widget.current.toString() != _ctl.text) {
      _ctl.text = '${widget.current}';
      _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canDec = !widget.fully && widget.current > 0;
    final canInc = !widget.fully && widget.current < widget.remaining;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepBtn(
          label: '−',
          enabled: canDec,
          onTap: () => widget.onSetQty(
            widget.productId,
            widget.current - 1,
            widget.remaining,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 50,
          child: TextField(
            controller: _ctl,
            enabled: !widget.fully,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            ),
            onChanged: (v) => widget.onSetQty(
              widget.productId,
              int.tryParse(v) ?? 0,
              widget.remaining,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text('/ ${widget.remaining}', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
        _StepBtn(
          label: '+',
          enabled: canInc,
          onTap: () => widget.onSetQty(
            widget.productId,
            widget.current + 1,
            widget.remaining,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: canInc
              ? () => widget.onSetQty(
                  widget.productId,
                  widget.remaining,
                  widget.remaining,
                )
              : null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: const Size(0, 44),
          ),
          child: const Text(
            'คืนหมด',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _StepBtn extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _StepBtn({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 44dp touch target (was 28dp) — the primary refund-qty control on touch.
    return SizedBox(
      width: 44,
      height: 44,
      child: OutlinedButton(
        onPressed: enabled ? onTap : null,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SummaryBox extends StatelessWidget {
  final double sub;
  final double disc;
  final double total;
  final List<String> methods;
  final String refundMethod;
  final TextEditingController reasonController;
  final bool busy;
  final int itemCount;
  final ValueChanged<String> onMethod;
  final ValueChanged<String> onReason;
  final VoidCallback onSubmit;
  final VoidCallback onVoid;

  const _SummaryBox({
    required this.sub,
    required this.disc,
    required this.total,
    required this.methods,
    required this.refundMethod,
    required this.reasonController,
    required this.busy,
    required this.itemCount,
    required this.onMethod,
    required this.onReason,
    required this.onSubmit,
    required this.onVoid,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryRow(label: 'ยอดคืน', value: baht(sub)),
          if (disc > 0)
            _SummaryRow(label: 'หักส่วนลดตามสัดส่วน', value: '−${baht(disc)}'),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(width: 2, color: theme.dividerColor),
                ),
              ),
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'คืนเงินทั้งสิ้น',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '−${baht(total)}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Refund method.
          _FieldLabel('วิธีคืนเงิน'),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var k = 0; k < methods.length; k++) ...[
                if (k > 0) const SizedBox(width: 8),
                Expanded(
                  child: _MethodButton(
                    label: methods[k],
                    active: refundMethod == methods[k],
                    onTap: () => onMethod(methods[k]),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // Reason.
          _FieldLabel('เหตุผล (ไม่บังคับ)'),
          const SizedBox(height: 6),
          TextField(
            controller: reasonController,
            onChanged: onReason,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'เช่น ลูกค้าเปลี่ยนใจ, สินค้าชำรุด, ขายผิดรุ่น',
            ),
          ),
          const SizedBox(height: 18),
          // Actions. Below ~480dp the fixed void button + Expanded submit can't
          // both fit, so stack full-width buttons (submit on top, destructive
          // void below) instead of two cramped red buttons side by side.
          LayoutBuilder(
            builder: (context, c) {
              final submit = AppButton(
                label: busy
                    ? 'กำลังบันทึก…'
                    : '↻ คืน $itemCount รายการ · ${baht(total)}',
                icon: busy ? null : Icons.refresh,
                busy: busy,
                variant: AppButtonVariant.danger,
                fullWidth: true,
                onPressed: (itemCount == 0 || busy) ? null : onSubmit,
              );
              if (c.maxWidth < 480) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    submit,
                    const SizedBox(height: 8),
                    AppButton(
                      label: '✕ ยกเลิกบิลทั้งบิล',
                      variant: AppButtonVariant.danger,
                      fullWidth: true,
                      onPressed: busy ? null : onVoid,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  AppButton(
                    label: '✕ ยกเลิกบิลทั้งบิล',
                    variant: AppButtonVariant.danger,
                    onPressed: busy ? null : onVoid,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: submit),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
        color: theme.colorScheme.secondary,
      ),
    );
  }
}

class _MethodButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _MethodButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: active ? AppColors.orange : null,
        foregroundColor: active ? Colors.white : theme.colorScheme.secondary,
        side: BorderSide(color: active ? AppColors.orange : theme.dividerColor),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CREDIT NOTE DIALOG — view + print the CN (ใบลดหนี้).
// ─────────────────────────────────────────────────────────────────────────────
class _CreditNoteDialog extends StatelessWidget {
  final ReturnWithItems cn;
  final SettingsRowData settings;
  const _CreditNoteDialog({required this.cn, required this.settings});

  @override
  Widget build(BuildContext context) {
    final r = cn.ret;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Receipt paper (always light, like the JS thermal paper).
            Flexible(
              child: SingleChildScrollView(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(20),
                  child: DefaultTextStyle(
                    style: const TextStyle(color: Colors.black, fontSize: 12),
                    child: _cnBody(r),
                  ),
                ),
              ),
            ),
            // Actions.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  AppButton.secondary(
                    label: 'ปิด',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppButton(
                      label: '🖨 พิมพ์ใบลดหนี้',
                      fullWidth: true,
                      onPressed: () => _printCreditNote(cn, settings),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cnBody(ReturnRow r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header.
        Container(
          padding: const EdgeInsets.only(bottom: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(width: 2, color: Colors.black)),
          ),
          child: Column(
            children: [
              Text(
                settings.shopName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                ),
              ),
              if (settings.address != null)
                Text(
                  settings.address!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              if (settings.phone != null)
                Text(
                  'โทร ${settings.phone}',
                  style: const TextStyle(fontSize: 11),
                ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  border: Border.all(width: 2, color: AppColors.error),
                ),
                child: const Text(
                  'ใบลดหนี้ · CREDIT NOTE',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: AppColors.error,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _kv('เลขที่', r.cnNo, mono: true, bold: true),
        _kv('อ้างอิงบิล', r.receiptNo, mono: true),
        _kv('วันที่', thaiDateTime(r.date)),
        if (r.mechanicName != null) _kv('ช่าง', '🔧 ${r.mechanicName}'),
        // Items.
        Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.black),
              bottom: BorderSide(color: Colors.black),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final i in cn.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        i.name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${i.qty} × ${baht(i.price)}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            baht(i.qty * i.price),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _kv('ยอดคืน', baht(r.refundSubtotal)),
        if (r.refundDiscount > 0)
          _kv('หักส่วนลดตามสัดส่วน', '−${baht(r.refundDiscount)}'),
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.only(top: 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(width: 2, color: Colors.black)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'คืนเงินทั้งสิ้น',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              Text(
                baht(r.refundTotal),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _kv('วิธีคืน', r.refundMethod, bold: true),
        if (r.reason.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            color: const Color(0xFFF5F5F5),
            child: Text(
              'เหตุผล: ${r.reason}',
              style: const TextStyle(fontSize: 11),
            ),
          ),
        Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.only(top: 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Colors.black)),
          ),
          child: const Column(
            children: [
              Text(
                '*** เอกสารใบลดหนี้นี้ใช้แสดงเป็นหลักฐานการคืนสินค้า ***',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: Color(0xFF666666)),
              ),
              Text(
                'กรุณาเก็บไว้คู่กับใบเสร็จต้นฉบับ',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: Color(0xFF666666)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v, {bool mono = false, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(fontSize: 11)),
          Text(
            v,
            style: TextStyle(
              fontSize: 11,
              fontFamily: mono ? 'monospace' : null,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Print the credit note as a thermal-width PDF (the JS window.print()). ──
Future<void> _printCreditNote(
  ReturnWithItems cn,
  SettingsRowData settings,
) async {
  final r = cn.ret;
  final font = await PdfGoogleFonts.sarabunRegular();
  final fontBold = await PdfGoogleFonts.sarabunBold();
  final doc = pw.Document();

  pw.Widget kv(String k, String v, {bool bold = false}) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Text(k, style: const pw.TextStyle(fontSize: 8)),
      pw.Text(
        v,
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    ],
  );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.roll57,
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(
            child: pw.Text(
              settings.shopName,
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (settings.address != null)
            pw.Center(
              child: pw.Text(
                settings.address!,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          if (settings.phone != null)
            pw.Center(
              child: pw.Text(
                'โทร ${settings.phone}',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 6),
          pw.Center(
            child: pw.Text(
              'ใบลดหนี้ · CREDIT NOTE',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Divider(),
          kv('เลขที่', r.cnNo, bold: true),
          kv('อ้างอิงบิล', r.receiptNo),
          kv('วันที่', thaiDateTime(r.date)),
          if (r.mechanicName != null) kv('ช่าง', r.mechanicName!),
          pw.Divider(),
          for (final i in cn.items)
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Text(
                  i.name,
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      '${i.qty} x ${baht(i.price)}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.Text(
                      baht(i.qty * i.price),
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ],
                ),
                pw.SizedBox(height: 3),
              ],
            ),
          pw.Divider(),
          kv('ยอดคืน', baht(r.refundSubtotal)),
          if (r.refundDiscount > 0)
            kv('หักส่วนลดตามสัดส่วน', '-${baht(r.refundDiscount)}'),
          pw.SizedBox(height: 4),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'คืนเงินทั้งสิ้น',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                baht(r.refundTotal),
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
          kv('วิธีคืน', r.refundMethod, bold: true),
          if (r.reason.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                'เหตุผล: ${r.reason}',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 8),
          pw.Center(
            child: pw.Text(
              '*** เอกสารใบลดหนี้นี้ใช้แสดงเป็นหลักฐานการคืนสินค้า ***',
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 7),
            ),
          ),
          pw.Center(
            child: pw.Text(
              'กรุณาเก็บไว้คู่กับใบเสร็จต้นฉบับ',
              style: const pw.TextStyle(fontSize: 7),
            ),
          ),
        ],
      ),
    ),
  );

  await Printing.layoutPdf(onLayout: (format) async => doc.save());
}
