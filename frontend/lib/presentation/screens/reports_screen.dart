// ReportsScreen — Sales Dashboard. Port of pos/ReportsScreen.jsx.
//
// KPIs: net revenue = counted sales in range MINUS credit notes (returns) in
// range — the closing report's rule (`domain/reports/net_sales.dart`): a
// manual void is dropped, an auto-void stays and its credit note subtracts.
// Bills, avg/bill (net ÷ bills, like the server's avgTicket), items and top
// products by net qty use the same set. Also revenue by category, recent
// sales, low-stock alert — with a today/7-day/month/all range
// selector. Data pulled through salesRepoProvider.getSales +
// returnsRepoProvider.getReturns (bounded to the selected range at the query,
// #417) + productsRepoProvider.getAll. Category bar colors come from
// ProductsRepository.catColor.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../domain/models/aggregates.dart';
import '../../domain/reports/net_sales.dart'
    show NetSales, ReturnLite, TopItem, toReportLites;
import '../widgets/app_button.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/status_chip.dart';
import '../widgets/thai_format.dart';

enum ReportRange { today, week, month, all }

/// Query bounds for [range] ([from] inclusive, [to] exclusive; null = open).
/// Selects exactly the rows the JS `inRange(iso)` bucketed: today = this
/// calendar day; week = from midnight 7 days ago with NO upper bound (the JS
/// never capped it, so future-dated rows count); month = this calendar month;
/// all = everything.
({DateTime? from, DateTime? to}) reportRangeBounds(
  ReportRange range,
  DateTime now,
) {
  switch (range) {
    case ReportRange.today:
      final d = dayBounds(now);
      return (from: d.from, to: d.to);
    case ReportRange.week:
      final weekAgo = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 7));
      return (from: weekAgo, to: null);
    case ReportRange.month:
      return (
        from: DateTime(now.year, now.month, 1),
        to: DateTime(now.year, now.month + 1, 1),
      );
    case ReportRange.all:
      return (from: null, to: null);
  }
}

/// Revenue per category over [sales]' lines: product matched by partNo →
/// category, else its zone, else อื่นๆ (first catalogue match wins, like the
/// original linear scan). The lookup map is built once, not per line.
///
/// [returns] (the period's credit notes, from `toReportLites`) subtract each
/// returned line's qty × price from the category of its product — the same
/// per-line rule as [NetSales.topItems] and the server's `byCategory`
/// (`return_events`) — so a fully returned bill leaves no revenue behind.
/// A category whose net is 0 drops out (the server's `HAVING`).
Map<String, double> revenueByCategory(
  List<SaleWithItems> sales,
  List<ProductRow> products, {
  List<ReturnLite> returns = const [],
}) {
  final byPartNo = <String, ProductRow>{};
  for (final p in products) {
    byPartNo.putIfAbsent(p.partNo, () => p);
  }
  final zoneMap = <String, double>{};
  void add(String? partNo, int qty, double price, int sign) {
    final p = byPartNo[partNo];
    final z = (p?.category.isNotEmpty ?? false)
        ? p!.category
        : (p?.zone ?? 'อื่นๆ');
    zoneMap[z] = (zoneMap[z] ?? 0) + sign * qty * price;
  }

  for (final t in sales) {
    for (final item in t.items) {
      add(item.partNo, item.qty, item.price, 1);
    }
  }
  for (final r in returns) {
    for (final i in r.items) {
      add(i.partNo, i.qty, i.price, -1);
    }
  }
  zoneMap.removeWhere((_, v) => v.abs() < 0.005);
  return zoneMap;
}

/// Bundled data the reports screen needs in one async pass. [sales] and
/// [returns] are already limited to the selected range.
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
  ReportRange _range = ReportRange.today;
  // Created in initState — never inline in build — so it doesn't refetch on
  // every rebuild (e.g. every range-selector tap).
  late Future<_ReportsData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData(_range);
  }

  Future<_ReportsData> _loadData(ReportRange range) async {
    final salesRepo = context.read<SalesRepository>();
    final returnsRepo = context.read<ReturnsRepository>();
    final productsRepo = context.read<ProductsRepository>();

    final bounds = reportRangeBounds(range, DateTime.now());
    final sales = await salesRepo.getSales(from: bounds.from, to: bounds.to);
    final returns = await returnsRepo.getReturns(
      from: bounds.from,
      to: bounds.to,
    );
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
    // The range bar stays put while a new range loads — only the body below
    // it waits — so a tap never blanks the whole page.
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RangeBar(
            range: _range,
            onChanged: (r) => setState(() {
              _range = r;
              _dataFuture = _loadData(r);
            }),
          ),
          Expanded(
            child: FutureBuilder<_ReportsData>(
              future: _dataFuture,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const LoadingView();
                }
                if (snap.hasError) {
                  return EmptyState(
                    icon: Icons.error_outline,
                    message: 'เกิดข้อผิดพลาด: ${snap.error}',
                    action: AppButton.secondary(
                      label: 'ลองใหม่อีกครั้ง',
                      icon: Icons.refresh,
                      onPressed: () => setState(() {
                        _dataFuture = _loadData(_range);
                      }),
                    ),
                  );
                }
                return _ReportsView(data: snap.data!);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportsView extends StatelessWidget {
  final _ReportsData data;
  const _ReportsView({required this.data});

  Color _hex(String h) {
    final v = h.replaceFirst('#', '');
    return Color(int.parse('FF$v', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    // Rows arrive already bounded to [range] by the repository query. Every
    // range reaches up to now, as [countedSales] needs.
    final lites = toReportLites(
      sales: data.sales,
      returns: data.returns,
      products: data.products,
    );
    // The closing report's rule ([NetSales]): manual voids dropped, auto-voids
    // kept with their credit notes subtracted. No profit shown here, so no
    // tax rate.
    final net = NetSales.of(lites.sales, lites.returns);
    final countedIds = {for (final s in net.counted) s.id};
    final counted = data.sales
        .where((s) => countedIds.contains(s.sale.id))
        .toList();

    final totalRevenue = counted.fold<double>(0, (s, t) => s + t.sale.total);
    final totalRefunds = data.returns.fold<double>(
      0,
      (s, r) => s + r.ret.refundTotal,
    );
    final netRevenue = net.netRevenue;
    final totalTransactions = net.billCount;
    final avgTicket = net.avgPerBill.round();
    final totalItems = net.netItems;

    // Top products by net qty sold (keyed by partNo, like the JS).
    final topList = ([
      ...net.topItems,
    ]..sort((a, b) => b.qty - a.qty)).take(8).toList();

    // Recent transactions (getSales is newest-first) — every bill, voids too.
    final recent = data.sales.take(10).toList();

    // Category revenue (match product by partNo → category/zone, else อื่นๆ)
    // over the counted bills, net of the period's credit notes.
    final zoneMap = revenueByCategory(
      counted,
      data.products,
      returns: lites.returns,
    );
    final zones = zoneMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final double maxZoneVal = zones.isNotEmpty ? zones.first.value : 1.0;

    // Low stock alert.
    final lowStock = data.products.where((p) => p.stock <= p.minStock).toList();

    return LayoutBuilder(
      builder: (context, outer) {
        final phone = AppBreakpoints.isPhone(outer.maxWidth);
        return SingleChildScrollView(
          padding: EdgeInsets.all(phone ? 16 : 24),
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
                      _topProductsCard(context, topList, narrow),
                      _categoryCard(
                        context,
                        zones,
                        maxZoneVal,
                        lowStock,
                        narrow,
                      ),
                      _recentCard(context, recent, narrow),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
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
    List<TopItem> top,
    bool narrow,
  ) {
    return _ReportCard(
      fitContent: narrow,
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
                    partNo: top[i].partNo,
                    name: top[i].name,
                    revenue: top[i].revenue,
                    qty: top[i].qty,
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
    bool narrow,
  ) {
    return _ReportCard(
      fitContent: narrow,
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
  Widget _recentCard(
    BuildContext context,
    List<SaleWithItems> recent,
    bool narrow,
  ) {
    return _ReportCard(
      fitContent: narrow,
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

// ── Range selector bar ────────────────────────────────────────────────────────
class _RangeBar extends StatelessWidget {
  final ReportRange range;
  final ValueChanged<ReportRange> onChanged;
  const _RangeBar({required this.range, required this.onChanged});

  static const _options = [
    (ReportRange.today, 'วันนี้', Icons.today_rounded),
    (ReportRange.week, '7 วัน', Icons.date_range_rounded),
    (ReportRange.month, 'เดือนนี้', Icons.calendar_month_rounded),
    (ReportRange.all, 'ทั้งหมด', Icons.all_inclusive_rounded),
  ];

  /// The dates the selected range covers, from the same [reportRangeBounds]
  /// the query uses — display only. Numeric (`thaiDateSlash`): it needs no
  /// intl locale data, so the bar renders even before any is loaded.
  static String periodLabel(ReportRange range, DateTime now) {
    final b = reportRangeBounds(range, now);
    switch (range) {
      case ReportRange.today:
        return thaiDateSlash(b.from!);
      case ReportRange.week:
        return '${thaiDateSlash(b.from!)} – วันนี้'; // agent ร่าง
      case ReportRange.month:
        return '${thaiDateSlash(b.from!)} – '
            '${thaiDateSlash(b.to!.subtract(const Duration(days: 1)))}';
      case ReportRange.all:
        return 'ทุกรายการที่บันทึกไว้'; // agent ร่าง
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final phone = AppBreakpoints.isPhone(constraints.maxWidth);
        final title = Row(
          children: [
            Icon(Icons.analytics_rounded, size: 22, color: AppColors.orange),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'รายงานยอดขาย',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: isDark ? Colors.white : AppColors.navy,
                    ),
                  ),
                  Text(
                    periodLabel(range, DateTime.now()),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isDark ? AppColors.steelBlue : AppColors.gray500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        // Phone: every range is always on screen — four equal segments under
        // the title, never a sideways scroll that hides "วันนี้".
        final pills = Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : AppColors.gray100,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: phone ? MainAxisSize.max : MainAxisSize.min,
            children: [
              for (final o in _options)
                phone
                    ? Expanded(
                        child: _RangeButton(
                          label: o.$2,
                          icon: o.$3,
                          compact: true,
                          active: range == o.$1,
                          onTap: () => onChanged(o.$1),
                        ),
                      )
                    : _RangeButton(
                        label: o.$2,
                        icon: o.$3,
                        active: range == o.$1,
                        onTap: () => onChanged(o.$1),
                      ),
            ],
          ),
        );
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: phone ? 16 : 24,
            vertical: phone ? 12 : 16,
          ),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.navy.withValues(alpha: 0.6)
                : AppColors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: phone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [title, const SizedBox(height: 10), pills],
                )
              : Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    // Wide but zoomed: still scrolls rather than overflow.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.65,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: pills,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _RangeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  /// Phone segment: label only (scaled to fit), a full 44 dp touch height.
  final bool compact;
  const _RangeButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = Text(
      label,
      maxLines: 1,
      style: theme.textTheme.labelLarge?.copyWith(
        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
        letterSpacing: 0.5,
        color: active
            ? Colors.white
            : (isDark ? AppColors.steelBlue : AppColors.gray500),
      ),
    );
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
            constraints: BoxConstraints(minHeight: compact ? 44 : 38),
            padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 14),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact)
                  Icon(
                    icon,
                    size: 15,
                    color: active
                        ? Colors.white
                        : (isDark ? AppColors.steelBlue : AppColors.gray500),
                  ),
                if (!compact) ...[const SizedBox(width: 5), text],
                // Inside the wide bar's sideways scroll a Flexible would see
                // an unbounded width, so only the phone segment scales.
                if (compact)
                  Flexible(
                    child: FittedBox(fit: BoxFit.scaleDown, child: text),
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
    final primary = _StatCard(
      icon: Icons.account_balance_wallet_rounded,
      iconGradient: const [AppColors.orangeLight, AppColors.orange],
      label: 'รายได้สุทธิ',
      value: baht(netRevenue),
      valueColor: AppColors.orange,
      sub: totalRefunds > 0
          ? 'ขาย ${baht(totalRevenue)} − คืน ${baht(totalRefunds)}'
          : null,
      isPrimary: true,
    );
    final others = <Widget>[
      _StatCard(
        icon: Icons.receipt_rounded,
        iconGradient: const [AppColors.navyHover, AppColors.navyMid],
        label: 'จำนวนบิล',
        value: thaiInt(totalTransactions),
        sub: 'transactions',
        compact: narrow,
      ),
      _StatCard(
        icon: Icons.trending_up_rounded,
        iconGradient: const [AppColors.steelBlue, AppColors.navyLight],
        label: 'ยอดเฉลี่ย/บิล',
        value: baht(avgTicket),
        sub: 'avg ticket',
        compact: narrow,
      ),
      _StatCard(
        icon: Icons.inventory_2_rounded,
        iconGradient: const [AppColors.successLight, AppColors.forestGreen],
        label: 'ชิ้นสินค้าที่ขาย',
        value: thaiInt(totalItems),
        sub: 'items sold',
        compact: narrow,
      ),
    ];

    // Desktop (4 columns) keeps its original `childAspectRatio` look.
    if (!narrow) {
      return GridView(
        key: const Key('reports-kpis'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 2.2,
        ),
        children: [primary, ...others],
      );
    }

    // Narrow: the number the owner looks for first — net revenue — gets the
    // full width; the other three sit under it in one row.
    // #463: fixed heights (never a `childAspectRatio`) so a 390 px card is
    // never squeezed below what its FittedBox value/label stack needs.
    return Column(
      key: const Key('reports-kpis'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 140, child: primary),
        const SizedBox(height: 12),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 120,
          ),
          children: others,
        ),
      ],
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

  /// Three-across phone tile: tighter padding and a smaller icon badge.
  final bool compact;
  const _StatCard({
    required this.icon,
    required this.iconGradient,
    required this.label,
    required this.value,
    this.sub,
    this.valueColor,
    this.isPrimary = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: compact
          ? const EdgeInsets.all(12)
          : const EdgeInsets.fromLTRB(20, 16, 20, 16),
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
            width: compact ? 28 : 36,
            height: compact ? 28 : 36,
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
            child: Icon(icon, size: compact ? 15 : 18, color: Colors.white),
          ),
          SizedBox(height: compact ? 8 : 12),
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

  /// Stacked (phone/narrow) layout: grow to the content instead of capping
  /// the height with an inner scroll — a scroll inside the page scroll traps
  /// a finger that only meant to scroll the page.
  final bool fitContent;
  const _ReportCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.child,
    this.fitContent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const bodyPadding = EdgeInsets.fromLTRB(20, 12, 20, 20);
    return Container(
      constraints: fitContent
          ? const BoxConstraints()
          : const BoxConstraints(maxHeight: 480),
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
          if (fitContent)
            Padding(padding: bodyPadding, child: child)
          else
            Flexible(
              child: SingleChildScrollView(padding: bodyPadding, child: child),
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
                // #477: at 390px width, a plain `Row` of two `_InfoChip`s
                // overflowed once the payment-method chip held a long string
                // (e.g. "เครดิตช่าง") at the largest font scale — `Wrap` lets
                // the second chip fall to its own line instead of forcing
                // the Row past the Expanded's width.
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    _InfoChip(
                      label: '${sale.items.length} รายการ',
                      isDark: isDark,
                    ),
                    _InfoChip(label: s.paymentMethod, isDark: isDark),
                    // A voided bill (manual, or auto-voided by a full return)
                    // must not read like a live sale.
                    if (s.voided) StatusChip.of('voided'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // #477: the total (unbounded width, w800 titleMedium) could still
          // squeeze the Expanded column below its content's needed width at
          // 390px on a six-figure sale — Flexible + ellipsis lets it shrink
          // instead of forcing the Row to overflow.
          Flexible(
            child: Text(
              baht(s.total),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : AppColors.navy,
              ),
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
