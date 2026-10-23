// DrawerExpenseSummary — "เงินสดออกไปไหน": one month's cash-drawer `out`
// entries grouped by the category prefix of their note
// (`domain/reports/drawer_expense.dart`). Owned by cash_drawer_screen.dart
// (CONTRACT §5), opened from its header like the closing report.
//
// Reads the LOCAL drawer entries through ShiftsRepository (getCashDrawer +
// getShiftHistory — both Drift on the Drift and the API build): the API build
// keeps the entries this device recorded, not other devices' (there is no
// shift/drawer pull), hence the "this device" footnote.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/shifts_repository.dart';
import '../../domain/reports/drawer_expense.dart';
import 'empty_state.dart';
import 'thai_format.dart';

/// Opens the monthly cash-out summary as a modal dialog.
Future<void> showDrawerExpenseSummary(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: const DrawerExpenseSummaryView(),
      ),
    ),
  );
}

class DrawerExpenseSummaryView extends StatefulWidget {
  const DrawerExpenseSummaryView({super.key});

  @override
  State<DrawerExpenseSummaryView> createState() =>
      _DrawerExpenseSummaryViewState();
}

class _DrawerExpenseSummaryViewState extends State<DrawerExpenseSummaryView> {
  late final Future<List<DrawerEntryRow>> _entries;
  late final DateTime _thisMonth;
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _thisMonth = DateTime(now.year, now.month);
    _month = _thisMonth;
    _entries = _load(context.read<ShiftsRepository>());
  }

  /// Every local drawer entry: the current shift's and every archived one's.
  static Future<List<DrawerEntryRow>> _load(ShiftsRepository repo) async {
    final current = await repo.getCashDrawer();
    final history = await repo.getShiftHistory();
    final byId = <String, DrawerEntryRow>{
      for (final s in [?current, ...history])
        for (final e in s.entries) e.id: e,
    };
    return byId.values.toList();
  }

  void _shift(int months) => setState(() {
    _month = DateTime(_month.year, _month.month + months);
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'เงินสดออกไปไหน',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'ปิด',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'เดือนก่อน',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _shift(-1),
            ),
            Flexible(
              child: Text(
                thaiMonthYear(_month),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: 'เดือนถัดไป',
              icon: const Icon(Icons.chevron_right),
              onPressed: _month.isBefore(_thisMonth) ? () => _shift(1) : null,
            ),
          ],
        ),
        const Divider(height: 1),
        Flexible(
          child: FutureBuilder<List<DrawerEntryRow>>(
            future: _entries,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('เกิดข้อผิดพลาด: ${snap.error}'),
                );
              }
              return _body(
                context,
                summariseDrawerOut(snap.data!, monthKey(_month)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, DrawerExpenseSummary s) {
    final theme = Theme.of(context);
    if (s.count == 0) {
      return const EmptyState(message: 'ไม่มีรายการเงินออกในเดือนนี้');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in s.groups)
            _row(context, g.group, g.count, g.satang, bold: false),
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.dividerColor, width: 2),
              ),
            ),
            child: _row(
              context,
              'รวมเงินออกทั้งเดือน',
              s.count,
              s.totalSatang,
              bold: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'นับเฉพาะรายการเงินออกที่บันทึกในเครื่องนี้',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.steelBlue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    int count,
    int satang, {
    required bool bold,
  }) {
    final theme = Theme.of(context);
    final weight = bold ? FontWeight.w800 : FontWeight.w600;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: bold
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: weight,
                  ),
                ),
                Text(
                  '${thaiInt(count)} รายการ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.steelBlue,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                baht(satang / 100),
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: weight,
                  color: bold ? null : AppColors.error,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
