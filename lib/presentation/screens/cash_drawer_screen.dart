// CashDrawerScreen — Cash Drawer Management (เปิด-ปิดลิ้นชัก).
//
// Flutter port of pos/CashDrawer.jsx. Reproduces:
//   • open shift (starting cash, with quick-amount chips),
//   • cash in / out entries (shiftsRepoProvider.addDrawerEntry),
//   • the expected-cash summary (starting + cash sales + cash credit payments
//     − cash refunds − cash out + cash in),
//   • close shift (physical cash count + variance vs expected),
//   • blocks new money entries after close (addDrawerEntry throws the Thai
//     message once the shift is closed — we surface it).
// Plus a button to open the daily ClosingReport popup.
//
// State is read THROUGH the repo providers (never AppDatabase). The cash-drawer
// math mirrors db.js exactly; Thai strings are copied verbatim from the JSX.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../domain/models/aggregates.dart';
import '../providers/providers.dart';
import '../providers/shift_providers.dart';
import '../widgets/app_button.dart';
import '../widgets/closing_report.dart';
import '../widgets/empty_state.dart';

String _today() => DateTime.now().toIso8601String().substring(0, 10);

/// Aggregated read-model for the cash-drawer screen.
class _DrawerData {
  /// The active shift for TODAY, or null (no shift opened today).
  final ShiftWithEntries? shift;
  final double cashSalesTotal;
  final double cashRefundsToday;
  final double cashCreditPaymentsToday;
  const _DrawerData({
    required this.shift,
    required this.cashSalesTotal,
    required this.cashRefundsToday,
    required this.cashCreditPaymentsToday,
  });

  double get totalOut => round2((shift?.entries ?? [])
      .where((e) => e.type == 'out')
      .fold<double>(0, (s, e) => s + e.amount));
  double get totalIn => round2((shift?.entries ?? [])
      .where((e) => e.type == 'in')
      .fold<double>(0, (s, e) => s + e.amount));
  double get startingCash => shift?.shift.startingCash ?? 0;

  double get expectedCash => round2(startingCash +
      cashSalesTotal +
      cashCreditPaymentsToday -
      cashRefundsToday -
      totalOut +
      totalIn);
}

final _drawerDataProvider = FutureProvider.autoDispose<_DrawerData>((ref) async {
  final today = _today();
  final drawer = await ref.watch(shiftsRepoProvider).getCashDrawer();
  // db.js: only treat the drawer as today's shift if its date matches today.
  final shift =
      (drawer != null && drawer.shift.dateStr == today) ? drawer : null;

  final salesAgg = await ref.watch(salesRepoProvider).getSales();
  final cashSalesTotal = salesAgg
      .where((s) =>
          s.sale.date.toIso8601String().substring(0, 10) == today &&
          s.sale.paymentMethod == 'เงินสด')
      .fold<double>(0, (sum, s) => sum + s.sale.total);

  final returns = await ref.watch(returnsRepoProvider).getReturns();
  final cashRefundsToday = returns
      .where((r) =>
          r.ret.date.toIso8601String().substring(0, 10) == today &&
          r.ret.refundMethod == 'เงินสด')
      .fold<double>(0, (s, r) => s + r.ret.refundTotal);

  // The Drift CreditPayments table has no `method` column (the JS filtered
  // p.method === 'เงินสด'); we treat every same-day credit settlement as a
  // cash drawer inflow.
  final creditPayments =
      await ref.watch(mechanicsRepoProvider).getCreditPayments();
  final cashCreditPaymentsToday = creditPayments
      .where((p) => p.date.toIso8601String().substring(0, 10) == today)
      .fold<double>(0, (s, p) => s + p.amount);

  return _DrawerData(
    shift: shift,
    cashSalesTotal: cashSalesTotal,
    cashRefundsToday: cashRefundsToday,
    cashCreditPaymentsToday: cashCreditPaymentsToday,
  );
});

class CashDrawerScreen extends ConsumerStatefulWidget {
  const CashDrawerScreen({super.key});

  @override
  ConsumerState<CashDrawerScreen> createState() => _CashDrawerScreenState();
}

class _CashDrawerScreenState extends ConsumerState<CashDrawerScreen> {
  final _startCtl = TextEditingController();
  final _amountCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  final _physCtl = TextEditingController();
  String _entryType = 'out'; // 'out' | 'in'
  int _tab = 0; // 0 = รายการเงิน, 1 = ปิดลิ้นชัก
  bool _busy = false;

  @override
  void dispose() {
    _startCtl.dispose();
    _amountCtl.dispose();
    _noteCtl.dispose();
    _physCtl.dispose();
    super.dispose();
  }

  void _refresh() => ref.invalidate(_drawerDataProvider);

  Future<void> _handleOpen() async {
    final v = double.tryParse(_startCtl.text) ?? 0;
    if (!(v > 0)) {
      _toast('กรุณากรอกเงินตั้งต้นให้ถูกต้อง');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(shiftsRepoProvider).openShift(v);
      _startCtl.clear();
      _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleAddEntry(_DrawerData d) async {
    if (d.shift?.shift.closedAt != null) {
      _toast('ปิดลิ้นชักแล้ว — ไม่สามารถบันทึกรายการเงินเพิ่มได้');
      return;
    }
    final amount = double.tryParse(_amountCtl.text) ?? 0;
    if (amount <= 0) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(shiftsRepoProvider)
          .addDrawerEntry(_entryType, amount, _noteCtl.text);
      _amountCtl.clear();
      _noteCtl.clear();
      _refresh();
    } catch (e) {
      _toast(_clean(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleClose() async {
    final v = double.tryParse(_physCtl.text) ?? -1;
    if (!(v >= 0)) return;
    setState(() => _busy = true);
    try {
      await ref.read(shiftsRepoProvider).closeShift(v);
      _physCtl.clear();
      _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final asyncData = ref.watch(_drawerDataProvider);
    return Scaffold(
      body: asyncData.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('เกิดข้อผิดพลาด: $e')),
        data: (d) => _content(context, d),
      ),
    );
  }

  Widget _content(BuildContext context, _DrawerData d) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          // Wrap so the title and the closing-report action reflow onto two
          // lines on narrow (phone) widths instead of a horizontal overflow.
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 10,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('💵 ลิ้นชักเงินสด · Cash Drawer',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(_thaiDateLong(now),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.steelBlue)),
                ],
              ),
              AppButton.secondary(
                label: '📊 สรุปยอดปิดร้าน',
                onPressed: () => showClosingReport(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: d.shift == null
              ? _noShift(context)
              : _shiftOpen(context, d),
        ),
      ],
    );
  }

  // ── No shift yet ───────────────────────────────────────────────────────
  Widget _noShift(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💰', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('ยังไม่ได้เปิดร้านวันนี้',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('กรอกเงินตั้งต้นในลิ้นชักก่อนเริ่มขาย',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.steelBlue)),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                Text('เงินตั้งต้น ฿',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: AppColors.steelBlue)),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _startCtl,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(
                        isDense: true, hintText: '0'),
                    onSubmitted: (_) => _handleOpen(),
                  ),
                ),
                AppButton(
                  label: 'เปิดร้าน',
                  busy: _busy,
                  onPressed: _handleOpen,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [500, 1000, 2000, 3000]
                  .map((n) => _quickChip(
                      baht(n), () => setState(() => _startCtl.text = '$n')))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Shift open: tabs ───────────────────────────────────────────────────
  Widget _shiftOpen(BuildContext context, _DrawerData d) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab bar
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              _tabButton('💵 รายการเงิน', 0),
              _tabButton('🔒 ปิดลิ้นชัก', 1),
            ],
          ),
        ),
        Expanded(
          child: _tab == 0 ? _drawerTab(context, d) : _closeTab(context, d),
        ),
      ],
    );
  }

  Widget _tabButton(String label, int index) {
    final active = _tab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? AppColors.orange : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: active ? AppColors.orange : AppColors.steelBlue,
            ),
          ),
        ),
      ),
    );
  }

  // ── Tab 1: รายการเงิน ──────────────────────────────────────────────────
  Widget _drawerTab(BuildContext context, _DrawerData d) {
    final shift = d.shift!;
    final closed = shift.shift.closedAt != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final left = _drawerLeft(context, d, closed);
        final right = _drawerRight(context, d);
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 24),
              SizedBox(width: 300, child: right),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [left, const SizedBox(height: 24), right],
        );
      }),
    );
  }

  Widget _drawerLeft(BuildContext context, _DrawerData d, bool closed) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary cards
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.8,
          children: [
            _summCard('เงินตั้งต้น', d.startingCash, AppColors.steelBlue),
            _summCard('ยอดขายเงินสด', d.cashSalesTotal, AppColors.successLight),
            _summCard('รับชำระเครดิต (สด)', d.cashCreditPaymentsToday,
                AppColors.successLight),
            _summCard('คืนเงินสด', d.cashRefundsToday, AppColors.error),
            _summCard('เงินออก', d.totalOut, AppColors.error),
            _summCard('เงินเข้า (เพิ่ม)', d.totalIn, AppColors.warning),
          ],
        ),
        const SizedBox(height: 14),
        // Expected
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.orange.withValues(alpha: 0.08),
            border: Border.all(color: AppColors.orange.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('เงินในลิ้นชักที่ควรมี',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.steelBlue)),
              Text(baht(d.expectedCash),
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        // Add entry form (dimmed + disabled when closed)
        Opacity(
          opacity: closed ? 0.45 : 1,
          child: IgnorePointer(
            ignoring: closed,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sectionTitle(
                    'บันทึกการเคลื่อนเงิน${closed ? ' — ปิดลิ้นชักแล้ว' : ''}'),
                Row(
                  children: [
                    Expanded(
                      child: _typeButton('💸 เงินออก', 'out'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _typeButton('💰 เงินเข้า', 'in'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: TextField(
                        controller: _amountCtl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(
                            isDense: true, hintText: 'จำนวนเงิน'),
                        onSubmitted: (_) => _handleAddEntry(d),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _noteCtl,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'หมายเหตุ เช่น จ่ายซัพ / เติมทอน / ค่าน้ำมัน',
                        ),
                        onSubmitted: (_) => _handleAddEntry(d),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppButton.secondary(
                      label: '+ เพิ่ม',
                      onPressed: () => _handleAddEntry(d),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [100, 200, 500, 1000, 2000]
                      .map((n) => _quickChip(baht(n),
                          () => setState(() => _amountCtl.text = '$n')))
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _drawerRight(BuildContext context, _DrawerData d) {
    final theme = Theme.of(context);
    final shift = d.shift!;
    final entries = shift.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('ประวัติรายการวันนี้'),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'เปิดร้าน ${_hhmm(shift.shift.openedAt)} · ตั้งต้น ${baht(d.startingCash)}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.steelBlue),
          ),
        ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: EmptyState(message: 'ยังไม่มีรายการ'),
          ),
        for (final e in entries) _entryRow(context, e),
      ],
    );
  }

  Widget _entryRow(BuildContext context, DrawerEntryRow e) {
    final theme = Theme.of(context);
    final isOut = e.type == 'out';
    final accent = isOut ? AppColors.error : AppColors.successLight;
    final note = (e.note == null || e.note!.isEmpty)
        ? (isOut ? 'เงินออก' : 'เงินเข้า')
        : e.note!;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(note,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(_hhmm(e.createdAt),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.steelBlue)),
              ],
            ),
          ),
          Text('${isOut ? '−' : '+'}${baht(e.amount)}',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, color: accent)),
        ],
      ),
    );
  }

  // ── Tab 2: ปิดลิ้นชัก ──────────────────────────────────────────────────
  Widget _closeTab(BuildContext context, _DrawerData d) {
    final theme = Theme.of(context);
    final shift = d.shift!;
    final closed = shift.shift.closedAt != null;
    final phys = round2(double.tryParse(_physCtl.text) ?? 0);
    final variance = round2(phys - d.expectedCash);
    final hasPhys = _physCtl.text.isNotEmpty;
    final varColor = variance == 0
        ? AppColors.successLight
        : variance > 0
            ? AppColors.warning
            : AppColors.error;
    final varLabel = variance == 0
        ? '✓ ตรงยอด'
        : variance > 0
            ? 'เงินเกิน +${baht(variance.abs())}'
            : 'เงินขาด −${baht(variance.abs())}';

    // The breakdown rows (label, value, alwaysShow) — filter like the JSX.
    final rows = <List<Object>>[
      ['เงินตั้งต้น', d.startingCash, true],
      ['+ ยอดขายเงินสด', d.cashSalesTotal, true],
      ['+ รับชำระเครดิต (เงินสด)', d.cashCreditPaymentsToday, false],
      ['− คืนเงินสด', d.cashRefundsToday, false],
      ['+ เงินเพิ่มระหว่างวัน', d.totalIn, false],
      ['− เงินออกระหว่างวัน', d.totalOut, false],
    ].where((r) => (r[2] as bool) || (r[1] as double) > 0).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (closed)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.successLight.withValues(alpha: 0.12),
                    border: Border.all(
                        color: AppColors.successLight.withValues(alpha: 0.4)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '✓ ปิดลิ้นชักแล้วเวลา ${_hhmm(shift.shift.closedAt!)} · นับจริง ${baht(shift.shift.physicalCash ?? 0)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.successLight,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              _sectionTitle('สรุปยอดเงินสด'),
              for (final r in rows)
                Container(
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: theme.dividerColor)),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(r[0] as String,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.steelBlue)),
                      Text(baht(r[1] as double),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  border: Border(
                      top: BorderSide(color: theme.dividerColor, width: 2)),
                ),
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('เงินที่ควรมีในลิ้นชัก',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(baht(d.expectedCash),
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _fieldLabel('นับเงินสดจริงได้ ฿'),
              TextField(
                controller: _physCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.right,
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                decoration:
                    const InputDecoration(isDense: true, hintText: '0'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              if (hasPhys)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: varColor.withValues(alpha: 0.12),
                    border: Border.all(color: varColor, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('ผลต่าง',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text(varLabel,
                          style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800, color: varColor)),
                    ],
                  ),
                ),
              AppButton(
                label: '🔒 ยืนยันปิดลิ้นชัก',
                busy: _busy,
                fullWidth: true,
                onPressed: hasPhys ? _handleClose : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── small reusable widgets ─────────────────────────────────────────────
  Widget _summCard(String label, double value, Color color) {
    return Builder(builder: (context) {
      final theme = Theme.of(context);
      return Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(baht(value),
                style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800, color: color, height: 1)),
            const SizedBox(height: 3),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.steelBlue)),
          ],
        ),
      );
    });
  }

  Widget _typeButton(String label, String value) {
    final active = _entryType == value;
    final isOut = value == 'out';
    Color? bg;
    Color? border;
    Color? fg;
    if (active) {
      if (isOut) {
        bg = AppColors.error.withValues(alpha: 0.15);
        border = AppColors.error.withValues(alpha: 0.5);
        fg = const Color(0xFFE57373);
      } else {
        bg = AppColors.successLight.withValues(alpha: 0.15);
        border = AppColors.successLight.withValues(alpha: 0.5);
        fg = const Color(0xFF81C784);
      }
    }
    return Builder(builder: (context) {
      final theme = Theme.of(context);
      return InkWell(
        onTap: () => setState(() => _entryType = value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: bg ?? theme.colorScheme.surface,
            border: Border.all(color: border ?? theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: fg ?? AppColors.steelBlue)),
        ),
      );
    });
  }

  Widget _quickChip(String label, VoidCallback onTap) {
    return Builder(builder: (context) {
      final theme = Theme.of(context);
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700, color: AppColors.steelBlue)),
        ),
      );
    });
  }

  Widget _sectionTitle(String title) => Builder(builder: (context) {
        final theme = Theme.of(context);
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Text(title,
              style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: AppColors.steelBlue)),
        );
      });

  Widget _fieldLabel(String text) => Builder(builder: (context) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(text,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700, color: AppColors.steelBlue)),
        );
      });
}

// ── date/time helpers (long Thai date for the header) ────────────────────────
const _thMonths = [
  'มกราคม',
  'กุมภาพันธ์',
  'มีนาคม',
  'เมษายน',
  'พฤษภาคม',
  'มิถุนายน',
  'กรกฎาคม',
  'สิงหาคม',
  'กันยายน',
  'ตุลาคม',
  'พฤศจิกายน',
  'ธันวาคม',
];

String _thaiDateLong(DateTime d) =>
    '${d.day} ${_thMonths[d.month - 1]} ${d.year + 543}';

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
