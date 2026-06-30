// AppShell — the persistent topbar + nav frame around every routed screen.
//
// Ports the POS.html shell: a navy topbar with a 3px orange bottom border
// (shop name on the left, cashier + date on the right, a theme toggle), plus
// the 11-destination nav. NavigationRail on wide (>=1000px); a Drawer on narrow.
// The router passes the active child via the `child` parameter (ShellRoute).
// The active route is highlighted via GoRouterState.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../providers/providers.dart';
import 'thai_format.dart';
import 'theme_controller.dart';

class _NavDest {
  final String path;
  final IconData icon;
  final String label;
  const _NavDest(this.path, this.icon, this.label);
}

// Order + Thai labels match the POS.html nav.
const List<_NavDest> _destinations = [
  _NavDest(AppRoutes.checkout, Icons.point_of_sale, 'ขายสินค้า'),
  _NavDest(AppRoutes.products, Icons.inventory_2, 'สินค้า/สต็อก'),
  _NavDest(AppRoutes.purchaseOrders, Icons.shopping_cart, 'สั่งซื้อ'),
  _NavDest(AppRoutes.vehicleSearch, Icons.directions_car, 'ค้นหารุ่น'),
  _NavDest(AppRoutes.customers, Icons.people, 'ลูกค้า'),
  _NavDest(AppRoutes.mechanics, Icons.build, 'ช่าง'),
  _NavDest(AppRoutes.returns, Icons.assignment_return, 'คืนสินค้า'),
  _NavDest(AppRoutes.quotes, Icons.description, 'ใบเสนอราคา'),
  _NavDest(AppRoutes.reports, Icons.bar_chart, 'รายงาน'),
  _NavDest(AppRoutes.settings, Icons.settings, 'ตั้งค่า'),
  _NavDest(AppRoutes.cashDrawer, Icons.account_balance_wallet, 'ลิ้นชัก'),
];

class AppShell extends ConsumerWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  int _selectedIndex(BuildContext context) {
    final loc = GoRouterState.of(context).uri.path;
    final idx = _destinations.indexWhere((d) =>
        d.path == AppRoutes.checkout ? loc == d.path : loc.startsWith(d.path));
    return idx < 0 ? 0 : idx;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = _selectedIndex(context);
    // Persistent NavigationRail from tablet width up; Drawer below. Lowered
    // from 1000 to AppBreakpoints.rail (760) so iPad portrait gets the Rail.
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.rail;

    if (wide) {
      return Scaffold(
        body: Column(
          children: [
            _TopBar(title: _destinations[selected].label),
            Expanded(
              child: Row(
                children: [
                  _Rail(selected: selected),
                  const VerticalDivider(width: 1),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      drawer: _NavDrawer(selected: selected),
      body: Column(
        children: [
          _TopBar(title: _destinations[selected].label, showMenu: true),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  final int selected;
  const _Rail({required this.selected});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height - 68,
        ),
        child: IntrinsicHeight(
          child: NavigationRail(
            selectedIndex: selected,
            labelType: NavigationRailLabelType.all,
            backgroundColor: AppColors.navyDeep,
            selectedIconTheme: const IconThemeData(color: AppColors.orange),
            selectedLabelTextStyle: const TextStyle(
              color: AppColors.orange,
              fontWeight: FontWeight.w700,
            ),
            unselectedIconTheme:
                const IconThemeData(color: AppColors.gray300),
            unselectedLabelTextStyle:
                const TextStyle(color: AppColors.gray300),
            onDestinationSelected: (i) =>
                context.go(_destinations[i].path),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  label: Text(d.label),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavDrawer extends StatelessWidget {
  final int selected;
  const _NavDrawer({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.navyDeep,
      child: SafeArea(
        child: ListView(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.orange, width: 3),
                ),
              ),
              child: Center(
                child: Text(
                  'Srisurart POS',
                  style: TextStyle(
                    color: AppColors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                  ),
                ),
              ),
            ),
            for (var i = 0; i < _destinations.length; i++)
              ListTile(
                leading: Icon(
                  _destinations[i].icon,
                  color: i == selected
                      ? AppColors.orange
                      : AppColors.gray300,
                ),
                title: Text(
                  _destinations[i].label,
                  style: TextStyle(
                    color: i == selected
                        ? AppColors.orange
                        : AppColors.gray300,
                    fontWeight:
                        i == selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                selected: i == selected,
                onTap: () {
                  Navigator.pop(context);
                  context.go(_destinations[i].path);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerStatefulWidget {
  final String title;
  final bool showMenu;
  const _TopBar({required this.title, this.showMenu = false});

  @override
  ConsumerState<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<_TopBar> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    // Live clock. Tick every second but only rebuild when the displayed
    // minute (or day) actually changes, so we don't rebuild the topbar's
    // StreamBuilders 60×/minute just to show HH:mm.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = DateTime.now();
      if (next.minute != _now.minute || next.day != _now.day) {
        setState(() => _now = next);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsRepoProvider).watchSettings();
    final mode = ref.watch(themeModeProvider);
    final now = _now;

    final topPadding = MediaQuery.of(context).padding.top;

    return Container(
      constraints: BoxConstraints(minHeight: 68 + topPadding),
      decoration: const BoxDecoration(
        color: AppColors.navyDeep,
        border: Border(
          bottom: BorderSide(color: AppColors.orange, width: 3),
        ),
      ),
      padding: EdgeInsets.only(top: topPadding, left: 16, right: 16),
      child: Row(
        children: [
          if (widget.showMenu)
            Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu, color: AppColors.white),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
          Expanded(
            child: StreamBuilder(
              stream: settings,
              builder: (context, snap) {
                final shopName = snap.data?.shopName ?? 'Srisurart';
                final shopEN = snap.data?.shopNameEN;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shopName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        letterSpacing: 0.04,
                      ),
                    ),
                    if (shopEN != null && shopEN.isNotEmpty)
                      Text(
                        shopEN,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.steelBlue,
                          fontSize: 11,
                          letterSpacing: 0.06,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          IconButton(
            tooltip: mode == ThemeMode.dark ? 'โหมดสว่าง' : 'โหมดมืด',
            icon: Icon(
              mode == ThemeMode.dark
                  ? Icons.light_mode
                  : Icons.dark_mode,
              color: AppColors.white,
            ),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
          const SizedBox(width: 8),
          // Fixed-size (NOT Flexible): a Flexible here would share the Row's
          // free space 50/50 with the Expanded shop name and float the cluster
          // to the topbar's centre. As a plain ConstrainedBox the Expanded shop
          // name absorbs all the slack and this stays pinned to the right edge;
          // maxWidth + ellipsis still keep a long cashier name from overflowing.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: StreamBuilder(
              stream: settings,
              builder: (context, snap) {
                final cashier = snap.data?.cashierName;
                return Container(
                  padding: const EdgeInsets.only(left: 12),
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Colors.white24),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        (cashier == null || cashier.isEmpty)
                            ? 'Cashier'
                            : cashier,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        '${DateFormat('EEE', 'th').format(now)} '
                        '${thaiDate(now)} · ${thaiTime(now)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
