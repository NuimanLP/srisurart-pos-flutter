// go_router configuration for the Srisurart POS.
//
// Every screen lives inside the AppShell (NavigationRail/Drawer). The home route
// '/' is the Checkout (ขายสินค้า) screen, matching POS.html's default screen.
//
// #143: with `USE_API_WRITES` on, [buildAppRouter] is given the AuthCubit and
// adds `/login` (outside the shell) plus a redirect that holds every other
// route behind a signed-in session. With the flag off the shop's Drift build
// uses [appRouter], which is exactly the router it always had.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../../presentation/blocs/auth_cubit.dart';

import '../../presentation/screens/cash_drawer_screen.dart';
import '../../presentation/screens/checkout_screen.dart';
import '../../presentation/screens/customers_screen.dart';
import '../../presentation/screens/devices_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/mechanics_screen.dart';
import '../../presentation/screens/owner_review_screen.dart';
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
  static const String ownerReview = '/owner-review';
  static const String devices = '/devices';

  /// #143 — registered only on the API build (see [buildAppRouter]).
  static const String login = '/login';
}

/// The Drift-only shop build's router: the 11 routes, no auth, no redirect.
final GoRouter appRouter = buildAppRouter();

/// Builds the app router.
///
/// With [auth] null this is the router the shop has always run. With [auth]
/// given (the API build) it also registers [AppRoutes.login] and redirects by
/// [authRedirect], re-evaluated on every AuthCubit state via [refresh].
GoRouter buildAppRouter({
  AuthCubit? auth,
  Listenable? refresh,
  String initialLocation = AppRoutes.checkout,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: auth == null ? null : refresh,
    redirect: auth == null
        ? null
        : (context, state) => authRedirect(auth.state, state.uri),
    routes: [
      if (auth != null)
        GoRoute(
          path: AppRoutes.login,
          builder: (context, state) => const LoginScreen(),
        ),
      _buildShell(),
    ],
  );
}

/// Where the router must go for [auth] at [location], or null to stay.
///
/// Anything but [Authenticated] — including [AuthInitial] while the stored
/// session is still being read, and [AuthLoading] during a login — belongs on
/// the login route, which remembers the requested location in `?from=`. A
/// signed-in session on the login route is sent back there.
String? authRedirect(AuthState auth, Uri location) {
  final onLogin = location.path == AppRoutes.login;
  if (auth is Authenticated) {
    return onLogin ? safeReturnPath(location.queryParameters['from']) : null;
  }
  if (onLogin) return null;
  final from = location.toString();
  return Uri(
    path: AppRoutes.login,
    queryParameters: from == AppRoutes.checkout ? null : {'from': from},
  ).toString();
}

/// The `?from=` value if it is an in-app path, otherwise the home route.
///
/// On the web `from` is in the address bar and anyone can write it, so only a
/// relative path is followed — never a scheme, a `//host`, or the login route
/// itself (which would loop).
@visibleForTesting
String safeReturnPath(String? from) {
  if (from == null || !from.startsWith('/') || from.startsWith('//')) {
    return AppRoutes.checkout;
  }
  final uri = Uri.tryParse(from);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.path == AppRoutes.login) {
    return AppRoutes.checkout;
  }
  return from;
}

/// Adapts the AuthCubit's state stream to the [Listenable] go_router re-runs
/// its redirect on. The owner disposes it; go_router does not.
class AuthRefreshListenable extends ChangeNotifier {
  AuthRefreshListenable(AuthCubit auth) {
    _sub = auth.stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

// A fresh ShellRoute per router: it owns a navigator GlobalKey, which two live
// routers (e.g. in tests) must not share.
ShellRoute _buildShell() => ShellRoute(
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
    GoRoute(
      path: AppRoutes.ownerReview,
      builder: (context, state) => const OwnerReviewScreen(),
    ),
    GoRoute(
      path: AppRoutes.devices,
      builder: (context, state) => const DevicesScreen(),
    ),
  ],
);
