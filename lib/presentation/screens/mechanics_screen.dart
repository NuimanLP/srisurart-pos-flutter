// MechanicsScreen — ช่าง · Mechanics management.
//
// Ported for behaviour parity from
//   D:/Beestation/.../pos/MechanicsScreen.jsx
//
// Reproduces: mechanic registry list + search, tabs (ทั้งหมด / มียอดค้าง),
// add/edit/delete (mechanicsRepoProvider, auto M### code), credit limit +
// creditBalance display with over-limit warning, the credit-payment intake
// (addCreditPayment → reduces balance, records a CP receipt), the detail panel
// with totalSales / totalCredit (ลดให้ช่าง) / totalMarkup (ส่วนต่างช่าง) stats,
// and the merged sales + payments account history.
//
// Layout: master list on the left, detail panel on the right when a mechanic is
// selected (wide); on narrow screens the detail opens as a full-screen sheet.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/mechanics_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../domain/models/aggregates.dart';
import '../widgets/app_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/money_text.dart';
import '../widgets/search_field.dart';

// Status colors used in the JSX (kept literal for parity).
const Color _credit = Color(0xFFD4820A); // ยอดค้าง / ลดให้ช่าง
const Color _green = Color(0xFF2ECC71); // รับชำระ / ส่วนต่าง
const Color _red = Color(0xFFC0392B); // เกินวงเงิน
const Color _saleOrange = Color(0xFFE8601C);

class MechanicsScreen extends StatefulWidget {
  const MechanicsScreen({super.key});

  @override
  State<MechanicsScreen> createState() => _MechanicsScreenState();
}

class _MechanicsScreenState extends State<MechanicsScreen> {
  String _search = '';
  String _tab = 'all'; // 'all' | 'overdue'
  String? _selectedId;

  // Created in initState/_refresh — never inline in build.
  late Future<List<MechanicRow>> _mechanicsFuture;
  late Future<List<CreditPaymentRow>> _creditPaymentsFuture;
  late Future<List<SaleWithItems>> _salesFuture;

  @override
  void initState() {
    super.initState();
    _mechanicsFuture = context.read<MechanicsRepository>().getMechanics();
    _creditPaymentsFuture =
        context.read<MechanicsRepository>().getCreditPayments();
    _salesFuture = context.read<SalesRepository>().getSales();
  }

  void _refresh() {
    setState(() {
      _mechanicsFuture = context.read<MechanicsRepository>().getMechanics();
      _creditPaymentsFuture =
          context.read<MechanicsRepository>().getCreditPayments();
    });
  }

  List<MechanicRow> _filtered(List<MechanicRow> mechanics) {
    final q = _search.toLowerCase();
    return mechanics.where((m) {
      if (q.isEmpty) return true;
      return (m.nameTH ?? '').contains(q) ||
          (m.nickname ?? '').contains(q) ||
          (m.phone ?? '').contains(q) ||
          m.code.toLowerCase().contains(q) ||
          (m.shopName ?? '').toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<MechanicRow>>(
        future: _mechanicsFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return Center(child: Text('โหลดข้อมูลไม่สำเร็จ: ${snap.error}'));
          }
          final mechanics = snap.data!;
          final selected = _selectedId == null
              ? null
              : mechanics.where((m) => m.id == _selectedId).firstOrNull;
          // Selection may have been deleted externally.
          if (_selectedId != null && selected == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _selectedId = null);
            });
          }

          final isWide = MediaQuery.of(context).size.width >= 1000;
          final list = _buildList(mechanics, selected);

          if (!isWide) {
            // Narrow: list only; detail opens as a route/sheet on tap.
            return list;
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: list),
              if (selected != null)
                SizedBox(
                  width: 420,
                  child: _DetailPanel(
                    mechanic: selected,
                    salesFuture: _salesFuture,
                    paymentsFuture: _creditPaymentsFuture,
                    onClose: () => setState(() => _selectedId = null),
                    onPayCredit: () => _openPayCredit(selected),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ── LIST ──────────────────────────────────────────────────────────────────
  Widget _buildList(List<MechanicRow> mechanics, MechanicRow? selected) {
    final filtered = _filtered(mechanics);
    final totalOutstanding =
        mechanics.fold<double>(0, (s, m) => s + m.creditBalance);
    final overLimitCount = mechanics
        .where((m) => m.creditBalance > m.creditLimit && m.creditLimit > 0)
        .length;
    final overdueCount = mechanics.where((m) => m.creditBalance > 0).length;
    final visible = _tab == 'overdue'
        ? filtered.where((m) => m.creditBalance > 0).toList()
        : filtered;

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ช่าง · Mechanics',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${mechanics.length} คน · ยอดค้างรวม ',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          baht(totalOutstanding),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _credit,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (overLimitCount > 0)
                          Text(
                            ' · ⚠ เกินวงเงิน $overLimitCount คน',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _red,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              AppButton(
                label: '+ เพิ่มช่าง',
                onPressed: _openNew,
              ),
            ],
          ),
        ),
        // Tabs.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TabButton(
                  label: 'ทั้งหมด (${mechanics.length})',
                  active: _tab == 'all',
                  onTap: () => setState(() => _tab = 'all'),
                ),
                _TabButton(
                  label: 'มียอดค้าง ($overdueCount)',
                  active: _tab == 'overdue',
                  onTap: () => setState(() => _tab = 'overdue'),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        // Search.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
          child: SearchField(
            hint: '🔍 ค้นหาชื่อ / ชื่อเล่น / เบอร์ / รหัส',
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        // Rows.
        Expanded(
          child: visible.isEmpty
              ? const EmptyState(message: 'ไม่พบช่าง')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final m = visible[i];
                    return _MechanicRowTile(
                      mechanic: m,
                      selected: selected?.id == m.id,
                      onTap: () => _onSelect(m),
                      onEdit: () => _openEdit(m),
                      onDelete: () => _remove(m),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _onSelect(MechanicRow m) {
    final isWide = MediaQuery.of(context).size.width >= 1000;
    setState(() => _selectedId = m.id);
    if (!isWide) {
      // Narrow: open detail as a full-screen sheet.
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _DetailSheet(
            mechanicId: m.id,
            mechanicsFuture: _mechanicsFuture,
            salesFuture: _salesFuture,
            paymentsFuture: _creditPaymentsFuture,
            onPayCredit: _openPayCredit,
          ),
        ),
      );
    }
  }

  // ── ADD / EDIT ──────────────────────────────────────────────────────────
  Future<void> _openNew() => _openForm(null);

  Future<void> _openEdit(MechanicRow m) => _openForm(m);

  Future<void> _openForm(MechanicRow? editing) async {
    final repo = context.read<MechanicsRepository>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _MechanicFormDialog(editing: editing, repo: repo),
    );
    if (saved == true) _refresh();
  }

  Future<void> _remove(MechanicRow m) async {
    final repo = context.read<MechanicsRepository>();
    final ok = await showConfirm(
      context,
      'ลบช่าง',
      'ลบช่าง "${m.nameTH ?? ''}"?',
      danger: true,
    );
    if (!ok) return;
    await repo.deleteMechanic(m.id);
    if (_selectedId == m.id) {
      setState(() => _selectedId = null);
    }
    _refresh();
  }

  // ── CREDIT PAYMENT ────────────────────────────────────────────────────────
  Future<void> _openPayCredit(MechanicRow mechanic) async {
    final repo = context.read<MechanicsRepository>();
    final paid = await showDialog<bool>(
      context: context,
      builder: (_) => _PayCreditDialog(mechanic: mechanic, repo: repo),
    );
    if (paid == true) {
      setState(() {
        _mechanicsFuture = context.read<MechanicsRepository>().getMechanics();
        _creditPaymentsFuture =
            context.read<MechanicsRepository>().getCreditPayments();
        _salesFuture = context.read<SalesRepository>().getSales();
      });
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB BUTTON
// ─────────────────────────────────────────────────────────────────────────────
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
              color: active ? _saleOrange : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 0.5,
            color: active ? _saleOrange : Theme.of(context).hintColor,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIST ROW TILE
// ─────────────────────────────────────────────────────────────────────────────
class _MechanicRowTile extends StatelessWidget {
  final MechanicRow mechanic;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MechanicRowTile({
    required this.mechanic,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final m = mechanic;
    final theme = Theme.of(context);
    final bal = m.creditBalance;
    final lim = m.creditLimit;
    final overLimit = lim > 0 && bal > lim;
    final ratio = lim > 0 ? (bal / lim).clamp(0.0, 1.0) : 0.0;

    Color rowBg = Colors.transparent;
    if (overLimit) {
      rowBg = _red.withValues(alpha: 0.06);
    } else if (selected) {
      rowBg = _saleOrange.withValues(alpha: 0.08);
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        color: rowBg,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Code.
            SizedBox(
              width: 64,
              child: Text(
                m.code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: _saleOrange,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Name + nickname.
            Expanded(
              flex: 3,
              child: RichText(
                text: TextSpan(
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                  children: [
                    TextSpan(text: '🔧 ${m.nameTH ?? ''}'),
                    if ((m.nickname ?? '').isNotEmpty)
                      TextSpan(
                        text: '  (${m.nickname})',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Shop / phone.
            Expanded(
              flex: 2,
              child: Text(
                (m.shopName ?? '').isNotEmpty ? m.shopName! : '—',
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                m.phone ?? '',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
            // ยอดซื้อ.
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: MoneyText(m.totalSales),
              ),
            ),
            // ยอดค้าง.
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: bal > 0
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MoneyText(
                            bal,
                            color: _credit,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          if (overLimit)
                            const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Text('⚠', style: TextStyle(color: _red)),
                            ),
                        ],
                      )
                    : Text('—', style: TextStyle(color: theme.hintColor)),
              ),
            ),
            // วงเงิน + bar.
            Expanded(
              flex: 2,
              child: lim > 0
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(baht(lim),
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 3,
                            backgroundColor: theme.dividerColor,
                            color: overLimit
                                ? _red
                                : (ratio > 0.8 ? _credit : _green),
                          ),
                        ),
                      ],
                    )
                  : Align(
                      alignment: Alignment.centerRight,
                      child:
                          Text('—', style: TextStyle(color: theme.hintColor)),
                    ),
            ),
            // Actions.
            IconButton(
              tooltip: 'แก้ไข',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: onEdit,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'ลบ',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onDelete,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DETAIL SHEET (narrow) — watches the live mechanic by id.
// ─────────────────────────────────────────────────────────────────────────────
class _DetailSheet extends StatelessWidget {
  final String mechanicId;
  final Future<List<MechanicRow>> mechanicsFuture;
  final Future<List<SaleWithItems>> salesFuture;
  final Future<List<CreditPaymentRow>> paymentsFuture;
  final Future<void> Function(MechanicRow) onPayCredit;
  const _DetailSheet({
    required this.mechanicId,
    required this.mechanicsFuture,
    required this.salesFuture,
    required this.paymentsFuture,
    required this.onPayCredit,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('รายละเอียดช่าง')),
      body: FutureBuilder<List<MechanicRow>>(
        future: mechanicsFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          final m =
              snap.data!.where((x) => x.id == mechanicId).firstOrNull;
          if (m == null) {
            return const EmptyState(message: 'ไม่พบช่าง');
          }
          return _DetailPanel(
            mechanic: m,
            salesFuture: salesFuture,
            paymentsFuture: paymentsFuture,
            onClose: () => Navigator.of(context).maybePop(),
            onPayCredit: () => onPayCredit(m),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DETAIL PANEL
// ─────────────────────────────────────────────────────────────────────────────
class _DetailPanel extends StatelessWidget {
  final MechanicRow mechanic;
  final Future<List<SaleWithItems>> salesFuture;
  final Future<List<CreditPaymentRow>> paymentsFuture;
  final VoidCallback onClose;
  final VoidCallback onPayCredit;

  const _DetailPanel({
    required this.mechanic,
    required this.salesFuture,
    required this.paymentsFuture,
    required this.onClose,
    required this.onPayCredit,
  });

  @override
  Widget build(BuildContext context) {
    final m = mechanic;
    final theme = Theme.of(context);
    final bal = m.creditBalance;
    final lim = m.creditLimit;
    final overLimit = lim > 0 && bal > lim;
    final ratio = lim > 0 ? (bal / lim).clamp(0.0, 1.0) : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(20),
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
                      '🔧 ${m.nameTH ?? ''}',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${m.code} · ${(m.shopName ?? '').isNotEmpty ? m.shopName : (m.phone ?? '')}',
                      style: theme.textTheme.bodySmall,
                    ),
                    if ((m.note ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '"${m.note}"',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Credit card.
          if (bal > 0 || lim > 0)
            _CreditCard(
              bal: bal,
              lim: lim,
              overLimit: overLimit,
              ratio: ratio,
              onPay: bal > 0 ? onPayCredit : null,
            ),
          // Stats grid.
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: 'ยอดซื้อสะสม',
                  value: m.totalSales,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatBox(
                  label: 'ลดให้ช่าง',
                  value: m.totalCredit,
                  color: _credit,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatBox(
                  label: 'ส่วนต่างช่าง',
                  value: m.totalMarkup,
                  color: _green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // History.
          _AccountHistory(
            mechanic: m,
            salesFuture: salesFuture,
            paymentsFuture: paymentsFuture,
          ),
        ],
      ),
    );
  }
}

class _CreditCard extends StatelessWidget {
  final double bal;
  final double lim;
  final bool overLimit;
  final double ratio;
  final VoidCallback? onPay;

  const _CreditCard({
    required this.bal,
    required this.lim,
    required this.overLimit,
    required this.ratio,
    required this.onPay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = overLimit ? _red : _credit;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: overLimit ? 0.10 : 0.08),
        border: Border.all(color: accent, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ยอดเครดิตค้างชำระ ${overLimit ? '⚠ เกินวงเงิน' : ''}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        letterSpacing: 1.1,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      baht(bal),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 32,
                        height: 1,
                        color: accent,
                      ),
                    ),
                    if (lim > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'วงเงิน ${baht(lim)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              if (onPay != null)
                FilledButton.icon(
                  onPressed: onPay,
                  icon: const Text('💵'),
                  label: const Text('รับชำระ'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    foregroundColor: Colors.white,
                  ),
                ),
            ],
          ),
          if (lim > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: theme.dividerColor,
                  color: overLimit ? _red : (ratio > 0.8 ? _credit : _green),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final double value;
  final Color? color;
  const _StatBox({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c == null
            ? theme.colorScheme.surface
            : c.withValues(alpha: 0.06),
        border: Border.all(
          color: c == null ? theme.dividerColor : c.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.0,
              color: c ?? theme.hintColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            baht(value),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 22,
              color: c ?? theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ACCOUNT HISTORY — merged sales + payments, newest first (slice 40).
// ─────────────────────────────────────────────────────────────────────────────
class _AccountHistory extends StatelessWidget {
  final MechanicRow mechanic;
  final Future<List<SaleWithItems>> salesFuture;
  final Future<List<CreditPaymentRow>> paymentsFuture;
  const _AccountHistory({
    required this.mechanic,
    required this.salesFuture,
    required this.paymentsFuture,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<SaleWithItems>>(
      future: salesFuture,
      builder: (context, salesSnap) {
        return FutureBuilder<List<CreditPaymentRow>>(
          future: paymentsFuture,
          builder: (context, paysSnap) {
            if (salesSnap.connectionState != ConnectionState.done ||
                paysSnap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final sales = (salesSnap.data ?? <SaleWithItems>[])
                .where((s) => s.sale.mechanicId == mechanic.id)
                .toList();
            final pays = (paysSnap.data ?? <CreditPaymentRow>[])
                .where((p) => p.mechanicId == mechanic.id)
                .toList();

            // Merge by date, newest first.
            final merged = <_HistoryEntry>[
              ...sales.map((s) => _HistoryEntry.sale(s)),
              ...pays.map((p) => _HistoryEntry.payment(p)),
            ]..sort((a, b) => b.date.compareTo(a.date));
            final shown = merged.take(40).toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ประวัติเดินบัญชี (${sales.length} ขาย · ${pays.length} รับชำระ)',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          letterSpacing: 1.1,
                          color: theme.hintColor,
                        ),
                      ),
                      const Divider(height: 12),
                    ],
                  ),
                ),
                if (merged.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('ยังไม่มีประวัติ',
                          style: TextStyle(color: theme.hintColor)),
                    ),
                  )
                else
                  ...shown.map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: e.isPayment
                            ? _PaymentRow(payment: e.payment!)
                            : _SaleRow(sale: e.sale!),
                      )),
              ],
            );
          },
        );
      },
    );
  }
}

class _HistoryEntry {
  final DateTime date;
  final bool isPayment;
  final CreditPaymentRow? payment;
  final SaleWithItems? sale;

  _HistoryEntry.payment(CreditPaymentRow p)
      : payment = p,
        sale = null,
        isPayment = true,
        date = p.date;

  _HistoryEntry.sale(SaleWithItems s)
      : sale = s,
        payment = null,
        isPayment = false,
        date = s.sale.date;
}

String _historyDateTime(DateTime d) {
  // Matches new Date(...).toLocaleString('th-TH'): d/M/พ.ศ. HH:mm:ss style.
  final be = d.year + 543;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day}/${d.month}/$be ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class _PaymentRow extends StatelessWidget {
  final CreditPaymentRow payment;
  const _PaymentRow({required this.payment});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = payment;
    final note = (p.note ?? '').isNotEmpty ? ' · ${p.note}' : '';
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: _green, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(9, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.receiptNo,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: _green,
                  ),
                ),
                const SizedBox(height: 2),
                Text(_historyDateTime(p.date),
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  '💵 รับชำระเครดิต$note',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '−${baht(p.amount)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: _green,
                ),
              ),
              Text('ลดยอดค้าง',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SaleRow extends StatelessWidget {
  final SaleWithItems sale;
  const _SaleRow({required this.sale});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = sale.sale;
    final d = s.mechanicDelta ?? 0;
    final isCredit = s.paymentMethod == 'เครดิตช่าง';
    final itemCount = sale.items.length;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: isCredit
            ? const Border(left: BorderSide(color: _credit, width: 3))
            : null,
      ),
      padding: isCredit
          ? const EdgeInsets.fromLTRB(9, 10, 12, 10)
          : const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                    fontSize: 12,
                    color: _saleOrange,
                  ),
                ),
                const SizedBox(height: 2),
                Text(_historyDateTime(s.date),
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  '$itemCount รายการ${isCredit ? ' · 🔧 เครดิต' : ' · ${s.paymentMethod}'}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isCredit ? '+' : ''}${baht(s.total)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: isCredit ? _credit : theme.colorScheme.onSurface,
                ),
              ),
              if (d.abs() > 0.01)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${d > 0 ? '↑ +' : '↓ '}${baht(d.abs())} ${d > 0 ? 'ส่วนต่าง' : 'ลดให้'}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: d > 0 ? _green : _credit,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FORM DIALOG (add / edit)
// ─────────────────────────────────────────────────────────────────────────────
class _MechanicFormDialog extends StatefulWidget {
  final MechanicRow? editing;
  final MechanicsRepository repo;
  const _MechanicFormDialog({required this.editing, required this.repo});

  @override
  State<_MechanicFormDialog> createState() => _MechanicFormDialogState();
}

class _MechanicFormDialogState extends State<_MechanicFormDialog> {
  late final TextEditingController _nameTH;
  late final TextEditingController _nickname;
  late final TextEditingController _phone;
  late final TextEditingController _shopName;
  late final TextEditingController _creditLimit;
  late final TextEditingController _note;
  String? _nameError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final m = widget.editing;
    _nameTH = TextEditingController(text: m?.nameTH ?? '');
    _nickname = TextEditingController(text: m?.nickname ?? '');
    _phone = TextEditingController(text: m?.phone ?? '');
    _shopName = TextEditingController(text: m?.shopName ?? '');
    _creditLimit = TextEditingController(
        text: m == null ? '0' : _numText(m.creditLimit));
    _note = TextEditingController(text: m?.note ?? '');
  }

  static String _numText(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _nameTH.dispose();
    _nickname.dispose();
    _phone.dispose();
    _shopName.dispose();
    _creditLimit.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameTH.text.trim().isEmpty) {
      setState(() => _nameError = 'กรุณากรอกชื่อช่าง');
      return;
    }
    setState(() => _busy = true);
    final creditLimit = double.tryParse(_creditLimit.text.trim()) ?? 0;
    final patch = MechanicsCompanion(
      nameTH: Value(_nameTH.text.trim()),
      nickname: Value(_nickname.text.trim()),
      shopName: Value(_shopName.text.trim()),
      phone: Value(_phone.text.trim()),
      note: Value(_note.text.trim()),
      creditLimit: Value(creditLimit),
    );
    if (widget.editing != null) {
      await widget.repo.updateMechanic(widget.editing!.id, patch);
    } else {
      await widget.repo.addMechanic(patch);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing != null;
    return AlertDialog(
      title: Text(editing ? 'แก้ไขข้อมูลช่าง' : 'เพิ่มช่างใหม่'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextFieldLite(
                label: 'ชื่อ-สกุล (ภาษาไทย) *',
                controller: _nameTH,
                autofocus: true,
                errorText: _nameError,
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppTextFieldLite(
                      label: 'ชื่อเล่น',
                      controller: _nickname,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppTextFieldLite(
                      label: 'เบอร์โทร',
                      controller: _phone,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              AppTextFieldLite(
                label: 'ชื่ออู่ / ร้านซ่อม',
                controller: _shopName,
              ),
              const SizedBox(height: 12),
              AppTextFieldLite(
                label: 'วงเงินเครดิต (บาท) — 0 = ไม่ให้เครดิต',
                controller: _creditLimit,
                numeric: true,
                helperText: 'ระบบจะเตือนเมื่อยอดค้างเกินวงเงิน',
              ),
              const SizedBox(height: 12),
              AppTextFieldLite(
                label: 'หมายเหตุ',
                controller: _note,
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'ยกเลิก',
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: editing ? 'บันทึก' : 'เพิ่ม',
          busy: _busy,
          onPressed: _busy ? null : _save,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PAY-CREDIT DIALOG
// ─────────────────────────────────────────────────────────────────────────────
class _PayCreditDialog extends StatefulWidget {
  final MechanicRow mechanic;
  final MechanicsRepository repo;
  const _PayCreditDialog({required this.mechanic, required this.repo});

  @override
  State<_PayCreditDialog> createState() => _PayCreditDialogState();
}

class _PayCreditDialogState extends State<_PayCreditDialog> {
  late final TextEditingController _amount;
  String _method = 'เงินสด';
  final TextEditingController _note = TextEditingController();
  bool _busy = false;

  double get _balance => widget.mechanic.creditBalance;

  static String _numText(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: _numText(_balance));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amount.text.trim()) ?? 0;
    if (amt <= 0) {
      await showConfirm(
        context,
        'จำนวนเงินไม่ถูกต้อง',
        'กรุณากรอกจำนวนเงินที่ถูกต้อง',
        confirmLabel: 'ตกลง',
        cancelLabel: 'ปิด',
      );
      return;
    }
    if (amt > _balance) {
      final ok = await showConfirm(
        context,
        'ยืนยันรับเงิน',
        'จำนวนเงิน ${baht(amt)} เกินยอดค้าง ${baht(_balance)}\n\nยืนยันรับเงิน?',
      );
      if (!ok) return;
    }
    setState(() => _busy = true);
    // Repo addCreditPayment accepts only mechanicId/amount/note. We fold the
    // chosen method into the note so it appears in the account history line
    // ("รับชำระเครดิต · <method> · <note>"), matching the JSX display.
    final typed = _note.text.trim();
    final combinedNote = typed.isEmpty ? _method : '$_method · $typed';
    await widget.repo.addCreditPayment(
      mechanicId: widget.mechanic.id,
      amount: amt,
      note: combinedNote,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('รับชำระ ${baht(amt)} เรียบร้อย')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amt = double.tryParse(_amount.text.trim()) ?? 0;
    final after = (_balance - amt).clamp(0.0, double.infinity);

    return AlertDialog(
      title: Text('💵 รับชำระเครดิต — ${widget.mechanic.nameTH ?? ''}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Balance summary.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _credit.withValues(alpha: 0.08),
                  border: Border.all(color: _credit.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('ยอดค้างปัจจุบัน',
                            style: theme.textTheme.bodySmall),
                        Text(
                          baht(_balance),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 24,
                            height: 1,
                            color: _credit,
                          ),
                        ),
                      ],
                    ),
                    if (amt > 0) ...[
                      const Divider(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('ยอดค้างหลังรับชำระ',
                              style: theme.textTheme.bodySmall),
                          Text(
                            baht(after),
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                              color: after == 0 ? _green : _credit,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              // Amount.
              AppTextFieldLite(
                label: 'จำนวนเงินที่รับ *',
                controller: _amount,
                numeric: true,
                autofocus: true,
                textStyle: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final v in [100, 500, 1000, 2000, 5000])
                    _QuickChip(
                      label: '+฿$v',
                      onTap: () => setState(() => _amount.text = '$v'),
                    ),
                  _QuickChip(
                    label: 'เต็มจำนวน',
                    onTap: () =>
                        setState(() => _amount.text = _numText(_balance)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Method.
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'วิธีชำระ',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 1.0,
                    color: theme.hintColor,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final m in ['เงินสด', 'โอน/QR'])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _MethodButton(
                          label: m,
                          active: _method == m,
                          onTap: () => setState(() => _method = m),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              // Note.
              AppTextFieldLite(
                label: 'หมายเหตุ',
                controller: _note,
                hint: 'เช่น เคลียร์บิลเดือน ม.ค.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'ยกเลิก',
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: '✓ บันทึกการรับเงิน',
          busy: _busy,
          onPressed: _busy ? null : _submit,
        ),
      ],
    );
  }
}

class _QuickChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QuickChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: theme.hintColor,
        side: BorderSide(color: theme.dividerColor),
      ),
      child: Text(label,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? _saleOrange : Colors.transparent,
          border: Border.all(
            color: active ? _saleOrange : theme.dividerColor,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: active ? Colors.white : theme.hintColor,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppTextFieldLite — local labeled field supporting helper/error/custom style.
// (The shared AppTextField doesn't expose helperText / a custom text style, so
//  this small local widget covers the form/payment fields here.)
// ─────────────────────────────────────────────────────────────────────────────
class AppTextFieldLite extends StatelessWidget {
  final String? label;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final TextEditingController? controller;
  final bool numeric;
  final bool autofocus;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final TextStyle? textStyle;

  const AppTextFieldLite({
    super.key,
    this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.controller,
    this.numeric = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.onChanged,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Text(
              label!,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 1.0,
                color: theme.hintColor,
              ),
            ),
          ),
        TextField(
          controller: controller,
          autofocus: autofocus,
          maxLines: maxLines,
          style: textStyle,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            helperText: helperText,
            errorText: errorText,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }
}
