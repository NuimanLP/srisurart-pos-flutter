// iPad report (2026-10-31): the on-screen keyboard hid the field being typed
// in, inside the add-product dialog. A landscape iPad-like view (1180x820)
// with a 380 px keyboard (viewInsets.bottom, as the web engine reports it)
// must leave the focused field AND the save button above the keyboard —
// at 1x and with the whole-app UiZoom applied. Cause: the dialog shrinks
// above the keyboard by a 100 ms AnimatedPadding, after the field was
// already scrolled into view of the not-yet-shrunk dialog.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/customers_screen.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/screens/purchase_orders_screen.dart';
import 'package:srisurart_pos/presentation/widgets/instant_keyboard_inset.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

const _screen = Size(1180, 820);
const _keyboard = 380.0;

/// The add-product form's category Row (dropdown + "ใหม่…" + add button)
/// overflows a few px in the test font — pre-existing, not this test's
/// subject. Anything else is a real failure.
void _expectAtMostCategoryOverflow(WidgetTester tester) {
  final e = tester.takeException();
  if (e == null) return;
  expect(e, isA<FlutterError>());
  expect(e.toString(), contains('A RenderFlex overflowed by'));
}

Future<void> _pumpApp(
  WidgetTester tester,
  AppDatabase db,
  Widget home, {
  double zoom = 1.0,
  Size screen = _screen,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: repositoryProviders(db, useApiRepositories: false),
      child: MultiBlocProvider(
        providers: [
          BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
          BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
          BlocProvider<CartCubit>(create: (_) => CartCubit()),
        ],
        child: MaterialApp(
          builder: (context, child) => UiZoom(zoom: zoom, child: child!),
          home: Scaffold(body: home),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

/// Scrolls the dialog's last text field into view, taps it (focus + caret),
/// then raises the keyboard — the real order on the iPad.
Future<Finder> _focusLastFieldThenKeyboard(
  WidgetTester tester, {
  void Function()? afterEachPump,
}) async {
  final last = find
      .descendant(of: find.byType(Dialog), matching: find.byType(EditableText))
      .last;
  await tester.ensureVisible(last);
  await tester.pumpAndSettle();
  afterEachPump?.call();
  await tester.tap(last);
  await tester.pump();
  tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  afterEachPump?.call();
  expect(tester.widget<EditableText>(last).focusNode.hasFocus, isTrue);
  return last;
}

/// The focused field lies inside its scroll viewport (a field below it is
/// clipped under a sticky footer even when above the keyboard), and the
/// field and [saveLabel] are above the keyboard.
void _expectVisible(WidgetTester tester, Finder field, String saveLabel) {
  final visibleBottom = tester.view.physicalSize.height - _keyboard; // dpr 1
  final r = tester.getRect(field);
  expect(r.top, greaterThanOrEqualTo(0), reason: 'field rect $r');
  expect(r.bottom, lessThanOrEqualTo(visibleBottom), reason: 'field rect $r');
  final body = tester.getRect(find
      .ancestor(of: field, matching: find.byType(SingleChildScrollView))
      .first);
  expect(r.top, greaterThanOrEqualTo(body.top), reason: 'body $body, field $r');
  expect(r.bottom, lessThanOrEqualTo(body.bottom),
      reason: 'body $body, field $r');
  final save = tester.getRect(find
      .descendant(of: find.byType(Dialog), matching: find.text(saveLabel))
      .last);
  expect(save.top, greaterThanOrEqualTo(0), reason: 'save rect $save');
  expect(save.bottom, lessThanOrEqualTo(visibleBottom),
      reason: 'save rect $save');
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  for (final zoom in [1.0, 1.25]) {
    testWidgets('add-product: focused last field and บันทึก stay above the '
        'keyboard (zoom $zoom)', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _pumpApp(tester, db, const ProductsScreen(), zoom: zoom);
        await tester.tap(find.text('เพิ่มสินค้า'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        _expectAtMostCategoryOverflow(tester);
        final last = await _focusLastFieldThenKeyboard(
          tester,
          afterEachPump: () => _expectAtMostCategoryOverflow(tester),
        );
        _expectVisible(tester, last, 'บันทึก');
        await db.close();
      });
    });
  }

  testWidgets('create PO: focused last draft-line field and บันทึกใบสั่งซื้อ '
      'stay above the keyboard', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      // Spark Plug NGK (p2) runs low, so the prefill adds a draft line with
      // qty/cost fields at the bottom of the form.
      await (db.update(db.products)..where((t) => t.id.equals('p2')))
          .write(const ProductsCompanion(stock: Value(3)));
      await _pumpApp(
        tester,
        db,
        const PurchaseOrdersScreen(prefill: PoPrefill(supplier: 'NGK Thailand')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('สร้างใบสั่งซื้อใหม่ · New Purchase Order'), findsOneWidget);
      final last = await _focusLastFieldThenKeyboard(tester);
      _expectVisible(tester, last, 'บันทึกใบสั่งซื้อ');
      await db.close();
    });
  });

  // A shorter view (1180x640, 260 px left above the keyboard): at 820 the
  // short customer form fits even without the fix.
  testWidgets('customer editor: focused last field and บันทึก stay above the '
      'keyboard', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _pumpApp(
        tester,
        db,
        const CustomersScreen(),
        screen: const Size(1180, 640),
      );
      await tester.tap(find.text('เพิ่มลูกค้า').first);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final last = await _focusLastFieldThenKeyboard(tester);
      _expectVisible(tester, last, 'บันทึก');
      await db.close();
    });
  });

  // Top-aligned only on touch platforms (web on iPad Safari reports iOS);
  // desktop keeps the centred dialog.
  for (final (platform, top) in [
    (TargetPlatform.iOS, true),
    (TargetPlatform.android, true),
    (TargetPlatform.windows, false),
  ]) {
    testWidgets('add-product dialog alignment on ${platform.name}: '
        '${top ? 'top' : 'centred'}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _pumpApp(tester, db, const ProductsScreen());
        await tester.tap(find.text('เพิ่มสินค้า'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        _expectAtMostCategoryOverflow(tester);
        final card = tester.getRect(find
            .descendant(of: find.byType(Dialog), matching: find.byType(Material))
            .first);
        if (top) {
          expect(card.top, moreOrLessEquals(24, epsilon: 1), reason: '$card');
        } else {
          expect(card.center.dy, moreOrLessEquals(_screen.height / 2, epsilon: 1),
              reason: '$card');
        }
        await db.close();
      });
      // The override must be cleared before the test ends (framework check).
      debugDefaultTargetPlatformOverride = null;
    });
  }

  // AlertDialog has no insetAnimationDuration; the form AlertDialogs are
  // wrapped in InstantKeyboardInset instead. A tall scrollable one, last
  // field focused: without the wrapper it ends ~300 px below the viewport.
  testWidgets('InstantKeyboardInset: tall AlertDialog keeps the focused '
      'field in view above the keyboard', (tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => InstantKeyboardInset(
                child: AlertDialog(
                  scrollable: true,
                  title: const Text('form'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 10; i++)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: TextField(),
                        ),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('ok')),
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final last = await _focusLastFieldThenKeyboard(tester);
    _expectVisible(tester, last, 'ok');
  });
}
