// ReportsScreen — Sales Dashboard. Port of pos/ReportsScreen.jsx.
//
// KPIs: net revenue = sales in range MINUS credit notes (returns) in range
// (covers partial returns AND voided bills), top products by qty, revenue by
// category, recent sales, low-stock alert — with a today/7-day/month/all range
// selector. Data pulled through salesRepoProvider.getSales +
// returnsRepoProvider.getReturns + productsRepoProvider.getAll. Category bar
// colors come from ProductsRepository.catColor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../domain/models/aggregates.dart';
import '../providers/providers.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/thai_format.dart';

enum _Range { today, week, month, all }

/// Bundled data the reports screen needs in one async pass.
class _ReportsData {
  final List<SaleWithItems> sales;
  final List<ReturnWithItems> returns;
  final List<ProductRow> products;
  final Map<String, String> catColors; // category name → hex color
  const _ReportsData({
    required this.sales,
    required this.returns,
    required this.products,
    required this.catColors,
  });
}

final _reportsDataProvider = FutureProvider.autoDispose<_ReportsData>((ref) async {
  final sales = await ref.watch(salesRepoProvider).getSales();
  final returns = await ref.watch(returnsRepoProvider).getReturns();
  final products = await ref.watch(productsRepoProvider).getAll();

  // Pre-resolve a color per distinct category we will plot (catColor is async).
  final productsRepo = ref.watch(productsRepoProvider);
  final cats = <String>{};
  for (final p in products) {
    final c = p.category.isNotEmpty ? p.category : (p.zone ?? 'อื่นๆ');
    cats.add(c);
  }
  cats.add('อื่นๆ');
  final catColors = <String, String>{};
  for (final c in cats) {
    catColors[c] = await productsRepo.catColor(c);
  }

  return _ReportsData(
    sales: sales,
    returns: returns,
    products: products,
    catColors: catColors,
  );
});

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _Range _range = _Range.today;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_reportsDataProvider);
    return Scaffold(
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => Center(child: Text('เกิดข้อผิดพลาด: $e')),
        data: (data) => _ReportsView(
          data: data,
          range: _range,
          onRangeChanged: (r) => setState(() => _range = r),
        ),
      ),
    );
  }
}

class _ReportsView extends StatelessWidget {
  final _ReportsData data;
  final _Range range;
  final ValueChanged<_Range> onRangeChanged;
  const _ReportsView({
    required this.data,
    required this.range,
    required this.onRangeChanged,
  });

  // Port of inRange(iso): bucket a date into the selected range.
  bool _inRange(DateTime d, _Range range, DateTime now) {
    switch (range) {
      case _Range.today:
        return d.year == now.year && d.month == now.month && d.day == now.day;
      case _Range.week:
        final weekAgo = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 7));
        return !d.isBefore(weekAgo);
      case _Range.month:
        return d.year == now.year && d.month == now.month;
      case _Range.all:
        return true;
    }
  }

  Color _hex(String h) {
    final v = h.replaceFirst('#', '');
    return Color(int.parse('FF$v', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

    final filtered = data.sales
        .where((s) => _inRange(s.sale.date, range, now))
        .toList();

    final totalRevenue =
        filtered.fold<double>(0, (s, t) => s + t.sale.total);
    // Credit notes in the same range reduce real revenue (partial returns AND
    // voided bills).
    final totalRefunds = data.returns
        .where((r) => _inRange(r.ret.date, range, now))
        .fold<double>(0, (s, r) => s + r.ret.refundTotal);
    final netRevenue = totalRevenue - totalRefunds;
    final totalTransactions = filtered.length;
    final avgTicket =
        totalTransactions > 0 ? (totalRevenue / totalTransactions).round() : 0;
    final totalItems = filtered.fold<int>(
        0, (s, t) => s + t.items.fold<int>(0, (a, i) => a + i.qty));

    // Top products by qty sold (keyed by partNo, like the JS).
    final soldMap = <String, _Sold>{};
    for (final t in filtered) {
      for (final item in t.items) {
        final key = item.partNo ?? '';
        final entry =
            soldMap.putIfAbsent(key, () => _Sold(name: item.name));
        entry.qty += item.qty;
        entry.revenue += item.qty * item.price;
      }
    }
    final topProducts = soldMap.entries.toList()
      ..sort((a, b) => b.value.qty - a.value.qty);
    final topList = topProducts.take(8).toList();

    // Recent transactions (getSales is newest-first).
    final recent = filtered.take(10).toList();

    // Category revenue (match product by partNo → category/zone, else อื่นๆ).
    final zoneMap = <String, double>{};
    for (final t in filtered) {
      for (final item in t.items) {
        ProductRow? p;
        for (final pr in data.products) {
          if (pr.partNo == item.partNo) {
            p = pr;
            break;
          }
        }
        final z = (p?.category.isNotEmpty ?? false)
            ? p!.category
            : (p?.zone ?? 'อื่นๆ');
        zoneMap[z] = (zoneMap[z] ?? 0) + item.qty * item.price;
      }
    }
    final zones = zoneMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final double maxZoneVal = zones.isNotEmpty ? zones.first.value : 1.0;

    // Low stock alert.
    final lowStock =
        data.products.where((p) => p.stock <= p.minStock).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeBar(
          range: range,
          onChanged: onRangeChanged,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 900;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _KpiRow(
                      narrow: narrow,
                      netRevenue: netRevenue,
                      totalRevenue: totalRevenue,
                      totalRefunds: totalRefunds,
                      totalTransactions: totalTransactions,
                      avgTicket: avgTicket,
                      totalItems: totalItems,
                    ),
                    const SizedBox(height: 16),
                    _columns(
                      narrow: narrow,
                      children: [
                        _topProductsCard(context, topList),
                        _categoryCard(context, zones, maxZoneVal, lowStock),
                        _recentCard(context, recent),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _columns({required bool narrow, required List<Widget> children}) {
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            children[i],
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }

  // ── Top Products ──────────────────────────────────────────────────────────
  Widget _topProductsCard(BuildContext context, List<MapEntry<String, _Sold>> top) {
    return _ReportCard(
      title: 'สินค้าขายดี · Top Products',
      child: top.isEmpty
          ? const _EmptyLine('ยังไม่มีข้อมูลการขาย')
          : Column(
              children: [
                for (int i = 0; i < top.length; i++)
                  _TopProductRow(
                    rank: i + 1,
                    partNo: top[i].key,
                    name: top[i].value.name,
                    revenue: top[i].value.revenue,
                    qty: top[i].value.qty,
                  ),
              ],
            ),
    );
  }

  // ── Revenue by Category + Low Stock ───────────────────────────────────────
  Widget _categoryCard(
    BuildContext context,
    List<MapEntry<String, double>> zones,
    double maxZoneVal,
    List<ProductRow> lowStock,
  ) {
    return _ReportCard(
      title: 'รายได้ตามประเภท · Revenue by Category',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (zones.isEmpty)
            const _EmptyLine('ยังไม่มีข้อมูล')
          else
            for (final z in zones)
              _CategoryBar(
                label: z.key,
                value: z.value,
                fraction: maxZoneVal == 0 ? 0 : (z.value / maxZoneVal),
                color: _hex(data.catColors[z.key] ?? '#1E4A80'),
              ),
          if (lowStock.isNotEmpty) ...[
            const SizedBox(height: 24),
            _CardTitle(
              '⚠ สต็อกต่ำ · Low Stock (${lowStock.length})',
              color: AppColors.warning,
            ),
            const SizedBox(height: 8),
            for (final p in lowStock.take(5)) _LowStockRow(p),
          ],
        ],
      ),
    );
  }

  // ── Recent Sales ──────────────────────────────────────────────────────────
  Widget _recentCard(BuildContext context, List<SaleWithItems> recent) {
    return _ReportCard(
      title: 'รายการล่าสุด · Recent Sales',
      child: recent.isEmpty
          ? const _EmptyLine('ยังไม่มีรายการ')
          : Column(
              children: [for (final t in recent) _RecentRow(t)],
            ),
    );
  }
}

class _Sold {
  final String name;
  int qty = 0;
  double revenue = 0;
  _Sold({required this.name});
}

// ── Range selector bar ────────────────────────────────────────────────────────
class _RangeBar extends StatelessWidget {
  final _Range range;
  final ValueChanged<_Range> onChanged;
  const _RangeBar({required this.range, required this.onChanged});

  static const _options = [
    (_Range.today, 'วันนี้'),
    (_Range.week, '7 วัน'),
    (_Range.month, 'เดือนนี้'),
    (_Range.all, 'ทั้งหมด'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Row(
        children: [
          Flexible(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final o in _options)
                  _RangeButton(
                    label: o.$2,
                    active: range == o.$1,
                    onTap: () => onChanged(o.$1),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'รายงานยอดขาย · Sales Report',
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: theme.colorScheme.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RangeButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _RangeButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: active ? AppColors.orange : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? AppColors.orange : theme.dividerColor,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: active ? Colors.white : theme.colorScheme.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ── KPI cards ─────────────────────────────────────────────────────────────────
class _KpiRow extends StatelessWidget {
  final bool narrow;
  final double netRevenue;
  final double totalRevenue;
  final double totalRefunds;
  final int totalTransactions;
  final int avgTicket;
  final int totalItems;

  const _KpiRow({
    required this.narrow,
    required this.netRevenue,
    required this.totalRevenue,
    required this.totalRefunds,
    required this.totalTransactions,
    required this.avgTicket,
    required this.totalItems,
  });

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _StatCard(
        label: 'รายได้สุทธิ',
        value: baht(netRevenue),
        valueColor: AppColors.orange,
        sub: totalRefunds > 0
            ? 'ขาย ${baht(totalRevenue)} − คืน ${baht(totalRefunds)}'
            : null,
      ),
      _StatCard(
        label: 'จำนวนบิล',
        value: thaiInt(totalTransactions),
        sub: 'transactions',
      ),
      _StatCard(
        label: 'ยอดเฉลี่ย/บิล',
        value: baht(avgTicket),
        sub: 'avg ticket',
      ),
      _StatCard(
        label: 'ชิ้นสินค้าที่ขาย',
        value: thaiInt(totalItems),
        sub: 'items sold',
      ),
    ];

    final crossAxisCount = narrow ? 2 : 4;
    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
      childAspectRatio: narrow ? 2.0 : 2.3,
      children: cards,
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? valueColor;
  const _StatCard({
    required this.label,
    required this.value,
    this.sub,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only value+label scale together; the sub stays at fixed size so a
          // long 'ขาย ฿..−คืน ฿..' subtitle can't drag the headline smaller
          // than sibling cards.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: valueColor ?? theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.secondary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Generic report card (scrollable, max height like the JS card) ─────────────
class _ReportCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _ReportCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 440),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
            child: _CardTitle(title),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  final String text;
  final Color? color;
  const _CardTitle(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: color ?? theme.colorScheme.secondary,
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  final String message;
  const _EmptyLine(this.message);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: EmptyState(message: message),
    );
  }
}

class _TopProductRow extends StatelessWidget {
  final int rank;
  final String partNo;
  final String name;
  final double revenue;
  final int qty;
  const _TopProductRow({
    required this.rank,
    required this.partNo,
    required this.name,
    required this.revenue,
    required this.qty,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              '#$rank',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.secondary.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  partNo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.orangeLight,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                baht(revenue),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.orangeLight,
                ),
              ),
              Text(
                '$qty ชิ้น',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.secondary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  final String label;
  final double value;
  final double fraction;
  final Color color;
  const _CategoryBar({
    required this.label,
    required this.value,
    required this.fraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                baht(value),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.orangeLight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(
                  height: 6,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                ),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(height: 6, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LowStockRow extends StatelessWidget {
  final ProductRow product;
  const _LowStockRow(this.product);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final out = product.stock == 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  product.name,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  product.partNo,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.orange,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${product.stock} ชิ้น',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: out ? AppColors.error : AppColors.warning,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final SaleWithItems sale;
  const _RecentRow(this.sale);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = sale.sale;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.receiptNo,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.orangeLight,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  thaiDateTime(s.date),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.secondary),
                ),
                const SizedBox(height: 1),
                Text(
                  '${sale.items.length} รายการ · ${s.paymentMethod}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            baht(s.total),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
