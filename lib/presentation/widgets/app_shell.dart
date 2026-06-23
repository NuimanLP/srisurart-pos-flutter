// AppShell — the persistent topbar + nav frame around every routed screen.
//
// Ports the POS.html nav: a NavigationRail on wide screens / Drawer on narrow.
// The router passes the active child via the `child` parameter (ShellRoute).
// Destinations correspond to the AppRoutes paths.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';

class _NavDest {
  final String path;
  final IconData icon;
  final String label;
  const _NavDest(this.path, this.icon, this.label);
}

const List<_NavDest> _destinations = [
  _NavDest(AppRoutes.checkout, Icons.point_of_sale, 'ขายสินค้า'),
  _NavDest(AppRoutes.products, Icons.inventory_2, 'สินค้า'),
  _NavDest(AppRoutes.purchaseOrders, Icons.shopping_cart, 'สั่งซื้อ'),
  _NavDest(AppRoutes.vehicleSearch, Icons.directions_car, 'ค้นหารุ่น'),
  _NavDest(AppRoutes.customers, Icons.people, 'ลูกค้า'),
  _NavDest(AppRoutes.mechanics, Icons.build, 'ช่าง'),
  _NavDest(AppRoutes.returns, Icons.assignment_return, 'คืนสินค้า'),
  _NavDest(AppRoutes.quotes, Icons.description, 'ใบเสนอราคา'),
  _NavDest(AppRoutes.reports, Icons.bar_chart, 'รายงาน'),
  _NavDest(AppRoutes.cashDrawer, Icons.account_balance_wallet, 'ลิ้นชัก'),
  _NavDest(AppRoutes.settings, Icons.settings, 'ตั้งค่า'),
];

class AppShell extends StatelessWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  int _selectedIndex(BuildContext context) {
    final loc = GoRouterState.of(context).uri.path;
    final idx = _destinations.indexWhere((d) =>
        d.path == AppRoutes.checkout ? loc == d.path : loc.startsWith(d.path));
    return idx < 0 ? 0 : idx;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedIndex(context);
    final wide = MediaQuery.sizeOf(context).width >= 800;

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: selected,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => context.go(_destinations[i].path),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }

    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              for (var i = 0; i < _destinations.length; i++)
                ListTile(
                  leading: Icon(_destinations[i].icon),
                  title: Text(_destinations[i].label),
                  selected: i == selected,
                  onTap: () {
                    Navigator.pop(context);
                    context.go(_destinations[i].path);
                  },
                ),
            ],
          ),
        ),
      ),
      appBar: AppBar(title: Text(_destinations[selected].label)),
      body: child,
    );
  }
}
