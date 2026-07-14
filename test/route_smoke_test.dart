// Route smoke test — pumps every top-level screen at tablet (1280x800) and
// phone (400x800) sizes against an in-memory Drift DB and asserts no exception
// (catches RenderFlex overflow / unbounded-constraint crashes).
//
// A real POS targets TABLETS, so by convention here:
//   • a tablet-size overflow/exception is treated as a HIGH severity finding,
//   • a phone-size-only overflow/exception is MEDIUM.
// This test simply records the raw exception per screen+size; the QA report
// applies that severity mapping.
//
// Notes on the "!timersPending" teardown crash a naive boot test hits:
//   The screens kick off async loads in initState (Drift queries) and the
//   theme controller reads shared_preferences. shared_preferences' mock and the
//   Drift isolate both schedule microtasks/timers that can still be pending at
//   teardown. We neutralize this by (a) mocking shared_preferences via
//   SharedPreferences.setMockInitialValues({}), (b) disabling GoogleFonts
//   runtime fetching, and (c) draining async work inside tester.runAsync so the
//   Drift query futures actually complete before the test finishes, then
//   pumpAndSettle. This is plugin/test-harness noise, not a leaked app Timer.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/screens/purchase_orders_screen.dart';
import 'package:srisurart_pos/presentation/screens/vehicle_search_screen.dart';
import 'package:srisurart_pos/presentation/screens/customers_screen.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';
import 'package:srisurart_pos/presentation/screens/quotes_screen.dart';
import 'package:srisurart_pos/presentation/screens/reports_screen.dart';
import 'package:srisurart_pos/presentation/screens/returns_screen.dart';
import 'package:srisurart_pos/presentation/screens/settings_screen.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';

/// One screen under test: a human label + a builder for the widget.
class _ScreenCase {
  const _ScreenCase(this.label, this.build);
  final String label;
  final Widget Function() build;
}

final List<_ScreenCase> _screens = [
  _ScreenCase('checkout', () => const CheckoutScreen()),
  _ScreenCase('products', () => const ProductsScreen()),
  _ScreenCase('purchase_orders', () => const PurchaseOrdersScreen()),
  _ScreenCase('vehicle_search', () => const VehicleSearchScreen()),
  _ScreenCase('customers', () => const CustomersScreen()),
  _ScreenCase('mechanics', () => const MechanicsScreen()),
  _ScreenCase('quotes', () => const QuotesScreen()),
  _ScreenCase('reports', () => const ReportsScreen()),
  _ScreenCase('returns', () => const ReturnsScreen()),
  _ScreenCase('settings', () => const SettingsScreen()),
  _ScreenCase('cash_drawer', () => const CashDrawerScreen()),
];

/// Sizes a real POS runs at. Tablet is the primary target.
const Size _tablet = Size(1280, 800);
const Size _phone = Size(400, 800);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  for (final size in [_tablet, _phone]) {
    final sizeLabel = size == _tablet ? 'tablet' : 'phone';

    group('$sizeLabel (${size.width.toInt()}x${size.height.toInt()})', () {
      for (final sc in _screens) {
        testWidgets('${sc.label} renders without exception', (tester) async {
          // Size the surface for this case; restore afterwards.
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          // Fresh in-memory DB per screen so seeded demo data is present and
          // screens never share state.
          final db = AppDatabase(NativeDatabase.memory());

          // Drain ALL async (initState Drift loads, lazily-mounted tab loads,
          // shared_preferences) inside runAsync so every repository future
          // actually completes — then close the DB while still inside the
          // test body. Closing via addTearDown instead races the in-flight
          // load futures and produces a spurious "Can't re-open a database
          // after closing it" StateError after the test has completed.
          Object? caught;
          await tester.runAsync(() async {
            await tester.pumpWidget(
              MultiRepositoryProvider(
                providers: repositoryProviders(db),
                child: MultiBlocProvider(
                  providers: [
                    BlocProvider<ThemeModeCubit>(
                        create: (_) => ThemeModeCubit()),
                    BlocProvider<FontScaleCubit>(
                        create: (_) => FontScaleCubit()),
                    BlocProvider<PendingQuoteCubit>(
                        create: (_) => PendingQuoteCubit()),
                    BlocProvider<CartCubit>(create: (_) => CartCubit()),
                  ],
                  child: MaterialApp(
                    // A bare Scaffold parent gives screens an Overlay/Navigator
                    // and Material ancestor without pulling in go_router.
                    home: Scaffold(body: sc.build()),
                  ),
                ),
              ),
            );
            // Let initState async work + repository futures settle, then flush
            // layout. pumpAndSettle drains the microtask/timer queue so nothing
            // is left pending at teardown.
            await tester.pumpAndSettle(const Duration(milliseconds: 100));
            caught = tester.takeException();
            // Close the DB while the test is still running so any trailing
            // load future sees an open connection (or is already done).
            await db.close();
          });

          expect(
            caught,
            isNull,
            reason:
                '${sc.label} threw at $sizeLabel size (${size.width.toInt()}x${size.height.toInt()})',
          );
        });
      }
    });
  }
}
