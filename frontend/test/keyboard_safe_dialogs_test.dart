// iPad report (2026-10-31): the on-screen keyboard hid the field being typed
// in, inside the add-product dialog. A landscape iPad-like view (1180x820)
// with a 380 px keyboard (viewInsets.bottom, as the web engine reports it)
// must leave the focused field AND the บันทึก button above the keyboard —
// at 1x and with the whole-app UiZoom applied. Cause: the dialog shrinks
// above the keyboard by a 100 ms AnimatedPadding, after the field was
// already scrolled into view of the not-yet-shrunk dialog.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/widgets/instant_keyboard_inset.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

const _screen = Size(1180, 820);
const _keyboard = 380.0;

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  for (final zoom in [1.0, 1.25]) {
    testWidgets('add-product: focused last field and บันทึก stay above the '
        'keyboard (zoom $zoom)', (tester) async {
      tester.view.physicalSize = _screen;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: repositoryProviders(db, useApiRepositories: false),
            child: MultiBlocProvider(
              providers: [
                BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
                BlocProvider<PendingQuoteCubit>(
                  create: (_) => PendingQuoteCubit(),
                ),
                BlocProvider<CartCubit>(create: (_) => CartCubit()),
              ],
              child: MaterialApp(
                builder: (context, child) => UiZoom(zoom: zoom, child: child!),
                home: const Scaffold(body: ProductsScreen()),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        await tester.tap(find.text('เพิ่มสินค้า'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        tester.takeException(); // category-dropdown overflow in the test font is pre-existing

        final fields = find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(EditableText),
        );
        final last = fields.last;
        // Tap the field (focus + caret), then the keyboard slides up — the
        // real order on the iPad. The user scrolls the form to it first.
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        await tester.tap(last);
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        tester.takeException();

        expect(
          tester.widget<EditableText>(last).focusNode.hasFocus,
          isTrue,
        );
        final visibleBottom = _screen.height - _keyboard;
        final r = tester.getRect(last);
        expect(r.top, greaterThanOrEqualTo(0), reason: 'field rect $r');
        expect(r.bottom, lessThanOrEqualTo(visibleBottom),
            reason: 'field rect $r');
        // Inside the form's scroll viewport too — a field below it is clipped
        // under the sticky footer even when above the keyboard.
        final body = tester.getRect(find
            .ancestor(of: last, matching: find.byType(SingleChildScrollView))
            .first);
        expect(r.top, greaterThanOrEqualTo(body.top), reason: 'body $body, field $r');
        expect(r.bottom, lessThanOrEqualTo(body.bottom),
            reason: 'body $body, field $r');
        final save = tester.getRect(find.descendant(
          of: find.byType(Dialog),
          matching: find.text('บันทึก'),
        ));
        expect(save.top, greaterThanOrEqualTo(0), reason: 'save rect $save');
        expect(save.bottom, lessThanOrEqualTo(visibleBottom),
            reason: 'save rect $save');
        await db.close();
      });
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
    final last = find.byType(EditableText).last;
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
    await tester.pumpAndSettle();

    final r = tester.getRect(last);
    final body = tester.getRect(find
        .ancestor(of: last, matching: find.byType(SingleChildScrollView))
        .first);
    expect(body.bottom, lessThanOrEqualTo(_screen.height - _keyboard),
        reason: 'body $body');
    expect(r.top, greaterThanOrEqualTo(body.top), reason: 'body $body, field $r');
    expect(r.bottom, lessThanOrEqualTo(body.bottom),
        reason: 'body $body, field $r');
    expect(tester.getRect(find.text('ok')).bottom,
        lessThanOrEqualTo(_screen.height - _keyboard));
  });
}
