// go_router configuration for the Srisurart POS.
//
// Every screen lives inside the AppShell (NavigationRail/Drawer). The home route
// '/' is the Checkout (ขายสินค้า) screen, matching POS.html's default screen.

import 'package:go_router/go_router.dart';

import '../../presentation/screens/cash_drawer_screen.dart';
import '../../presentation/screens/checkout_screen.dart';
import '../../presentation/screens/customers_screen.dart';
import '../../presentation/screens/mechanics_screen.dart';
import '../../presentation/screens/products_screen.dart';
import '../../presentation/screens/purchase_orders_screen.dart';
import '../../presentation/screens/quotes_screen.dart';
import '../../presentation/screens/reports_screen.dart';
import '../../presentation/screens/returns_screen.dart';
import '../../presentation/screens/settings_screen.dart';
import '../../presentation/screens/vehicle_search_screen.dart';
import '../../presentation/widgets/app_shell.dart';

/// Centralised route-path constants — referenced by AppShell and screens.
class AppRoutes {
  AppRoutes._();
  static const String checkout = '/';
  static const String products = '/products';
  static const String purchaseOrders = '/purchase-orders';
  static const String vehicleSearch = '/vehicle-search';
  static const String customers = '/customers';
  static const String mechanics = '/mechanics';
  static const String returns = '/returns';
  static const String quotes = '/quotes';
  static const String reports = '/reports';
  static const String settings = '/settings';
  static const String cashDrawer = '/cash-drawer';
}

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.checkout,
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: AppRoutes.checkout,
          builder: (context, state) => const CheckoutScreen(),
        ),
        GoRoute(
          path: AppRoutes.products,
          builder: (context, state) => const ProductsScreen(),
        ),
        GoRoute(
          path: AppRoutes.purchaseOrders,
          builder: (context, state) => const PurchaseOrdersScreen(),
        ),
        GoRoute(
          path: AppRoutes.vehicleSearch,
          builder: (context, state) => const VehicleSearchScreen(),
        ),
        GoRoute(
          path: AppRoutes.customers,
          builder: (context, state) => const CustomersScreen(),
        ),
        GoRoute(
          path: AppRoutes.mechanics,
          builder: (context, state) => const MechanicsScreen(),
        ),
        GoRoute(
          path: AppRoutes.returns,
          builder: (context, state) => const ReturnsScreen(),
        ),
        GoRoute(
          path: AppRoutes.quotes,
          builder: (context, state) => const QuotesScreen(),
        ),
        GoRoute(
          path: AppRoutes.reports,
          builder: (context, state) => const ReportsScreen(),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: AppRoutes.cashDrawer,
          builder: (context, state) => const CashDrawerScreen(),
        ),
      ],
    ),
  ],
);
