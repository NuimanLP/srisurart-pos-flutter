// ReportsScreen — Sales Dashboard. Port of pos/ReportsScreen.jsx.
//
// KPIs: net revenue = sales in range MINUS credit notes (returns) in range
// (covers partial returns AND voided bills), top products by qty, revenue by
// category, recent sales, low-stock alert — with a today/7-day/month/all range
// selector. Data pulled through salesRepoProvider.getSales +
// returnsRepoProvider.getReturns + productsRepoProvider.getAll. Category bar
// colors come from ProductsRepository.catColor.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../domain/models/aggregates.dart';
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

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  _Range _range = _Range.today;
  // Created in initState — never inline in build — so it doesn't refetch on
  // every rebuild (e.g. every range-selector tap).
  late Future<_ReportsData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_ReportsData> _loadData() async {
    final salesRepo = context.read<SalesRepository>();
    final returnsRepo = context.read<ReturnsRepository>();
    final productsRepo = context.read<ProductsRepository>();

    final sales = await salesRepo.getSales();
    final returns = await returnsRepo.getReturns();
    final products = await productsRepo.getAll();

    // Pre-resolve a color per distinct category we will plot (catColor is async).
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<_ReportsData>(
        future: _dataFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return Center(child: Text('เกิดข้อผิดพลาด: ${snap.error}'));
          }
          return _ReportsView(
            data: snap.data!,
            range: _range,
            onRangeChanged: (r) => setState(() => _range = r),
          );
        },
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
        final weekAgo = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 7));
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

    final totalRevenue = filtered.fold<double>(0, (s, t) => s + t.sale.total);
    // Credit notes in the same range reduce real revenue (partial returns AND
    // voided bills).
    final totalRefunds = data.returns
        .where((r) => _inRange(r.ret.date, range, now))
        .fold<double>(0, (s, r) => s + r.ret.refundTotal);
    final netRevenue = totalRevenue - totalRefunds;
    final totalTransactions = filtered.length;
    final avgTicket = totalTransactions > 0
        ? (totalRevenue / totalTransactions).round()
        : 0;
    final totalItems = filtered.fold<int>(
      0,
      (s, t) => s + t.items.fold<int>(0, (a, i) => a + i.qty),
    );

    // Top products by qty sold (keyed by partNo, like the JS).
    final soldMap = <String, _Sold>{};
    for (final t in filtered) {
      for (final item in t.items) {
        final key = item.partNo ?? '';
        final entry = soldMap.putIfAbsent(key, () => _Sold(name: item.name));
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
    final lowStock = data.products.where((p) => p.stock <= p.minStock).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeBar(range: range, onChanged: onRangeChanged),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
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
                    const SizedBox(height: 20),
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
            if (i > 0) const SizedBox(height: 16),
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
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }

  // ── Top Products ──────────────────────────────────────────────────────────
  Widget _topProductsCard(
    BuildContext context,
    List<MapEntry<String, _Sold>> top,
  ) {
    return _ReportCard(
      icon: Icons.emoji_events_rounded,
      iconColor: const Color(0xFFFFB300),
      title: 'สินค้าขายดี',
      subtitle: 'Top Products',
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
                    isLast: i == top.length - 1,
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
      icon: Icons.donut_small_rounded,
      iconColor: AppColors.navyLight,
      title: 'รายได้ตามประเภท',
      subtitle: 'Revenue by Category',
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
            const SizedBox(height: 20),
            _LowStockHeader(count: lowStock.length),
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
      icon: Icons.receipt_long_rounded,
      iconColor: AppColors.orange,
      title: 'รายการล่าสุด',
      subtitle: 'Recent Sales',
      child: recent.isEmpty
          ? const _EmptyLine('ยังไม่มีรายการ')
          : Column(
              children: [
                for (int i = 0; i < recent.length; i++)
                  _RecentRow(recent[i], isLast: i == recent.length - 1),
              ],
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
    (_Range.today, 'วันนี้', Icons.today_rounded),
    (_Range.week, '7 วัน', Icons.date_range_rounded),
    (_Range.month, 'เดือนนี้', Icons.calendar_month_rounded),
    (_Range.all, 'ทั้งหมด', Icons.all_inclusive_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.navy.withValues(alpha: 0.6) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Report title with icon
          Icon(Icons.analytics_rounded, size: 22, color: AppColors.orange),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'รายงานยอดขาย',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: isDark ? Colors.white : AppColors.navy,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Range pill buttons — scrolls horizontally when the screen is
          // narrower than the full strip (phone sizes).
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : AppColors.gray100,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < _options.length; i++) ...[
                      _RangeButton(
                        label: _options[i].$2,
                        icon: _options[i].$3,
                        active: range == _options[i].$1,
                        onTap: () => onChanged(_options[i].$1),
                      ),
                    ],
                  ],
                ),
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
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _RangeButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Material(
        color: active ? AppColors.orange : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        elevation: active ? 2 : 0,
        shadowColor: AppColors.orange.withValues(alpha: 0.3),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: active
                      ? Colors.white
                      : (isDark ? AppColors.steelBlue : AppColors.gray500),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: 0.5,
                    color: active
                        ? Colors.white
                        : (isDark ? AppColors.steelBlue : AppColors.gray500),
                  ),
                ),
              ],
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
        icon: Icons.account_balance_wallet_rounded,
        iconGradient: const [Color(0xFFFF8A3D), Color(0xFFE8601C)],
        label: 'รายได้สุทธิ',
        value: baht(netRevenue),
        valueColor: AppColors.orange,
        sub: totalRefunds > 0
            ? 'ขาย ${baht(totalRevenue)} − คืน ${baht(totalRefunds)}'
            : null,
        isPrimary: true,
      ),
      _StatCard(
        icon: Icons.receipt_rounded,
        iconGradient: const [Color(0xFF4ECDC4), Color(0xFF2BA8A4)],
        label: 'จำนวนบิล',
        value: thaiInt(totalTransactions),
        sub: 'transactions',
      ),
      _StatCard(
        icon: Icons.trending_up_rounded,
        iconGradient: const [Color(0xFF667EEA), Color(0xFF4A5CD9)],
        label: 'ยอดเฉลี่ย/บิล',
        value: baht(avgTicket),
        sub: 'avg ticket',
      ),
      _StatCard(
        icon: Icons.inventory_2_rounded,
        iconGradient: const [Color(0xFF6DD5ED), Color(0xFF2193B0)],
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
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      childAspectRatio: narrow ? 1.9 : 2.2,
      children: cards,
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final List<Color> iconGradient;
  final String label;
  final String value;
  final String? sub;
  final Color? valueColor;
  final bool isPrimary;
  const _StatCard({
    required this.icon,
    required this.iconGradient,
    required this.label,
    required this.value,
    this.sub,
    this.valueColor,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPrimary
              ? AppColors.orange.withValues(alpha: 0.3)
              : (isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : AppColors.gray100),
          width: isPrimary ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isPrimary
                ? AppColors.orange.withValues(alpha: isDark ? 0.08 : 0.06)
                : Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
            blurRadius: isPrimary ? 16 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icon badge
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: iconGradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: iconGradient.first.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
          const SizedBox(height: 12),
          // Value + label scale together
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
                      color:
                          valueColor ??
                          (isDark ? Colors.white : AppColors.navy),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: isDark ? AppColors.steelBlue : AppColors.gray500,
                    ),
                  ),
                  // sub lives inside the FittedBox so it scales down with the
                  // value/label instead of overflowing short grid cells.
                  if (sub != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      sub!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? AppColors.steelBlue.withValues(alpha: 0.7)
                            : AppColors.gray400,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Generic report card (scrollable, max height like the JS card) ─────────────
class _ReportCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget child;
  const _ReportCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxHeight: 480),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : AppColors.gray100,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Card header with icon
          Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : AppColors.gray100,
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 17, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : AppColors.navy,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.8,
                          color: isDark
                              ? AppColors.steelBlue
                              : AppColors.gray400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: child,
            ),
          ),
        ],
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
  final bool isLast;
  const _TopProductRow({
    required this.rank,
    required this.partNo,
    required this.name,
    required this.revenue,
    required this.qty,
    this.isLast = false,
  });

  Color _rankColor() {
    switch (rank) {
      case 1:
        return const Color(0xFFFFB300); // gold
      case 2:
        return const Color(0xFF90A4AE); // silver
      case 3:
        return const Color(0xFFCD7F32); // bronze
      default:
        return AppColors.gray300;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final rColor = _rankColor();
    final isTopThree = rank <= 3;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : AppColors.gray100.withValues(alpha: 0.7),
                ),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Rank badge
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: isTopThree
                  ? rColor.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: isTopThree
                  ? null
                  : Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : AppColors.gray200,
                    ),
            ),
            alignment: Alignment.center,
            child: isTopThree
                ? Icon(Icons.emoji_events_rounded, size: 16, color: rColor)
                : Text(
                    '$rank',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.steelBlue : AppColors.gray400,
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
                    color: isDark ? Colors.white : AppColors.navy,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  partNo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.orangeLight,
                    fontFamily: 'monospace',
                    fontSize: 11,
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
                  color: AppColors.orange,
                ),
              ),
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : AppColors.gray100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$qty ชิ้น',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isDark ? AppColors.steelBlue : AppColors.gray500,
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
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Color dot
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.3),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: isDark ? Colors.white : AppColors.navy,
                  ),
                ),
              ),
              Text(
                baht(value),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : AppColors.gray100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [color, color.withValues(alpha: 0.7)],
                      ),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.25),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Low stock header ──────────────────────────────────────────────────────────
class _LowStockHeader extends StatelessWidget {
  final int count;
  const _LowStockHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Text(
            'สต็อกต่ำ · Low Stock ($count)',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.warning,
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
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : AppColors.gray100.withValues(alpha: 0.7),
          ),
        ),
      ),
      child: Row(
        children: [
          // Status indicator
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: out ? AppColors.error : AppColors.warning,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (out ? AppColors.error : AppColors.warning).withValues(
                    alpha: 0.4,
                  ),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  product.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : AppColors.navy,
                  ),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (out ? AppColors.error : AppColors.warning).withValues(
                alpha: 0.12,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              out ? 'หมด' : '${product.stock} ชิ้น',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: out ? AppColors.error : AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final SaleWithItems sale;
  final bool isLast;
  const _RecentRow(this.sale, {this.isLast = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final s = sale.sale;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : AppColors.gray100.withValues(alpha: 0.7),
                ),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Receipt icon badge
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.orange.withValues(alpha: 0.12)
                  : AppColors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.receipt_outlined,
              size: 17,
              color: AppColors.orange,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.receiptNo,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.orange,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      Icons.access_time_rounded,
                      size: 12,
                      color: isDark ? AppColors.steelBlue : AppColors.gray400,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        thaiDateTime(s.date),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? AppColors.steelBlue
                              : AppColors.gray400,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    _InfoChip(
                      label: '${sale.items.length} รายการ',
                      isDark: isDark,
                    ),
                    const SizedBox(width: 6),
                    _InfoChip(label: s.paymentMethod, isDark: isDark),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            baht(s.total),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : AppColors.navy,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small info chip for recent row metadata.
class _InfoChip extends StatelessWidget {
  final String label;
  final bool isDark;
  const _InfoChip({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : AppColors.gray100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: isDark ? AppColors.steelBlue : AppColors.gray500,
        ),
      ),
    );
  }
}
