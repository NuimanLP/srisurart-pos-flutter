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

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/fake_sale_photos_repository.dart';
import 'package:srisurart_pos/data/repositories/sale_photos_repository.dart';
import 'package:srisurart_pos/presentation/widgets/sale_photo_sheet.dart';
import 'package:srisurart_pos/presentation/widgets/sale_photo_strip.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';
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
import 'package:srisurart_pos/presentation/screens/owner_review_screen.dart';

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
  _ScreenCase('owner_review', () => const OwnerReviewScreen()),
];

/// Sizes a real POS runs at. Tablet is the primary target.
const Size _tablet = Size(1280, 800);
const Size _phone = Size(400, 800);

/// Whole-screen zoom (blocs/ui_zoom_cubit.dart, widgets/ui_zoom.dart): a 1920x1080 screen at 3x and a
/// 1366x768 laptop at 2x lay the app out on a ~640x360 / ~683x384 logical screen.
const List<(String, Size, double)> _cases = [
  ('tablet', _tablet, 1.0),
  ('phone', _phone, 1.0),
  ('zoom3x-fullhd', Size(1920, 1080), 3.0),
  ('zoom2x-laptop', Size(1366, 768), 2.0),
  // Capped to ~569x320: the shortest logical height the cap allows.
  ('zoom3x-laptop', Size(1366, 768), 3.0),
];

/// Sale photo evidence (10_SALE_PHOTO_EVIDENCE.md §2.5): the surfaces that open
/// ON TOP of a screen — the capture sheet (five photos), the Reports bill sheet
/// and the full-screen viewer — opened with a fake repository at every size.
const _photoSaleId = '0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b';
final _photoPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

class _Opener extends StatefulWidget {
  const _Opener(this.open);
  final void Function(BuildContext) open;

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

FakeSalePhotosRepository _photoRepo() {
  final repo = FakeSalePhotosRepository();
  for (var i = 0; i < 3; i++) {
    repo.seed(
      _photoSaleId,
      SalePhoto(
        id: 'p$i',
        saleId: _photoSaleId,
        sortOrder: i,
        width: 1,
        height: 1,
        takenAt: DateTime(2026, 10, 12, 14, 5),
        createdAt: DateTime(2026, 10, 12, 14, 5),
      ),
      _photoPng,
    );
  }
  return repo;
}

final Map<String, void Function(BuildContext, SalePhotosRepository)>
_photoSurfaces = {
  'sale photo sheet': (context, repo) => showSalePhotoSheet(
    context,
    repo: repo,
    saleId: _photoSaleId,
    receiptNo: 'RC01-2569-10-0042',
    sources: SalePhotoSources(
      files: () async => _photoPng,
      shrink: (b) async => b,
    ),
  ),
  'reports bill sheet': (context, repo) => showSaleBillSheet(
    context,
    saleId: _photoSaleId,
    receiptNo: 'RC01-2569-10-0042',
    date: DateTime(2026, 10, 12, 14, 5),
    paymentMethod: 'เครดิตช่าง',
    totalText: '฿123,456.00',
  ),
  'photo viewer': (context, repo) async {
    final photos = await repo.list(_photoSaleId);
    if (context.mounted) {
      await showSalePhotoViewer(
        context,
        repo: repo,
        photos: photos,
        initial: 1,
      );
    }
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  for (final (sizeLabel, size, zoom) in _cases) {
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
                providers: repositoryProviders(db, useApiRepositories: false),
                child: MultiBlocProvider(
                  providers: [
                    BlocProvider<ThemeModeCubit>(
                      create: (_) => ThemeModeCubit(),
                    ),
                    BlocProvider<FontScaleCubit>(
                      create: (_) => FontScaleCubit(),
                    ),
                    BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
                    BlocProvider<PendingQuoteCubit>(
                      create: (_) => PendingQuoteCubit(),
                    ),
                    BlocProvider<CartCubit>(create: (_) => CartCubit()),
                  ],
                  child: MaterialApp(
                    // A bare Scaffold parent gives screens an Overlay/Navigator
                    // and Material ancestor without pulling in go_router.
                    home: Scaffold(body: sc.build()),
                    builder: (context, child) =>
                        UiZoom(zoom: zoom, child: child!),
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
  for (final (sizeLabel, size, zoom) in _cases) {
    group(
      'sale photos at $sizeLabel (${size.width.toInt()}x${size.height.toInt()})',
      () {
        for (final surface in _photoSurfaces.entries) {
          testWidgets('${surface.key} renders without exception', (
            tester,
          ) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });
            final db = AppDatabase(NativeDatabase.memory());
            final repo = _photoRepo();
            Object? caught;
            await tester.runAsync(() async {
              await tester.pumpWidget(
                MultiRepositoryProvider(
                  providers: repositoryProviders(db, useApiRepositories: false),
                  child: RepositoryProvider<SalePhotosRepository?>.value(
                    value: repo,
                    child: MaterialApp(
                      home: Scaffold(
                        body: _Opener((c) => surface.value(c, repo)),
                      ),
                      builder: (context, child) =>
                          UiZoom(zoom: zoom, child: child!),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle(const Duration(milliseconds: 100));
              if (surface.key == 'sale photo sheet') {
                // Fill the sheet: five photos is its tallest state.
                for (var i = 0; i < 5; i++) {
                  final files = find.byKey(const Key('sale-photo-files'));
                  await tester.ensureVisible(files);
                  await tester.pump();
                  await tester.tap(files);
                  await tester.pumpAndSettle(const Duration(milliseconds: 100));
                }
                expect(find.text('ครบ 5 รูปแล้ว'), findsOneWidget);
              }
              caught = tester.takeException();
              await db.close();
            });
            expect(
              caught,
              isNull,
              reason: '${surface.key} threw at $sizeLabel',
            );
          });
        }
      },
    );
  }
}
