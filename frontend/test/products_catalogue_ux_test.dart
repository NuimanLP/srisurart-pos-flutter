// Catalogue UX polish (2026-10-11): presentation only — these pin the new
// affordances, not any data rule.
//  • 390 px shows product cards instead of a sideways-scrolling table.
//  • "ล้างตัวกรอง" brings a filtered list back to everything.
//  • The adjust-stock ± steps write the same signed text a user would type,
//    and บันทึก stays disabled until there is a whole number.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pumpScreen(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db, useApiRepositories: false),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
            BlocProvider<CartCubit>(create: (_) => CartCubit()),
          ],
          child: const MaterialApp(home: Scaffold(body: ProductsScreen())),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  void setSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('390 px: cards, filter count, clear filters', (tester) async {
    setSize(tester, const Size(390, 844));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await pumpScreen(tester, db);
      expect(find.byKey(const Key('products-card-list')), findsOneWidget);
      expect(find.byType(DataTable), findsNothing);
      expect(find.byKey(const Key('products-clear-filters')), findsNothing);

      final all = await ProductsRepository(db).getAll();
      await tester.enterText(find.byType(TextField).first, all.first.partNo);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('products-clear-filters')), findsOneWidget);
      expect(find.textContaining('จาก ${all.length} รายการ'), findsOneWidget);

      await tester.tap(find.byKey(const Key('products-clear-filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('products-clear-filters')), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await db.close();
    });
  });

  testWidgets('tablet keeps the table', (tester) async {
    setSize(tester, const Size(1280, 900));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await pumpScreen(tester, db);
      expect(find.byType(DataTable), findsOneWidget);
      expect(find.byKey(const Key('products-card-list')), findsNothing);
      await db.close();
    });
  });

  testWidgets('adjust stock: ± steps fill the signed amount', (tester) async {
    // Wide enough that the test font (every glyph a full square) still
    // keeps the row actions on screen.
    setSize(tester, const Size(2000, 1200));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await pumpScreen(tester, db);
      await tester.tap(find.text('ปรับสต็อก').first);
      await tester.pumpAndSettle();

      ButtonStyleButton save() => tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.descendant(
            of: find.byType(Dialog),
            matching: find.text('บันทึก'),
          ),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      );
      expect(save().onPressed, isNull);

      TextField delta() => tester.widget<TextField>(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        ).first,
      );

      await tester.tap(find.byKey(const Key('adjust-step-5')));
      await tester.pump();
      expect(delta().controller!.text, '+5');
      await tester.tap(find.byKey(const Key('adjust-step--10')));
      await tester.pump();
      expect(delta().controller!.text, '-5');
      expect(save().onPressed, isNotNull);

      await tester.tap(find.text('ยกเลิก').last);
      await tester.pumpAndSettle();
      await db.close();
    });
  });
}
