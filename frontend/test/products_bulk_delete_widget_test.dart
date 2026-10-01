// Bulk product delete on the stock screen (Drift build, seeded 12 products).
//
// Pins the safety UX: selection mode → select-all-of-filtered honours the
// search → the confirm dialog lists the items, warns about remaining stock,
// keeps the destructive button disabled until the count is typed, and Cancel
// deletes nothing. Run at tablet and 390 px.

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
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  for (final size in const [Size(1280, 900), Size(390, 844)]) {
    final label = '${size.width.toInt()}px';

    testWidgets(
      '$label: select-all honours the search; cancel deletes nothing; '
      'typed count unlocks delete',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final db = AppDatabase(NativeDatabase.memory());
        await tester.runAsync(() async {
          await pumpScreen(tester, db);
          await settle(tester);

          final all = await ProductsRepository(db).getAll();
          expect(all.length, 12);
          // Narrow the list to one product by its part number.
          final target = all.first;
          await tester.enterText(find.byType(TextField).first, target.partNo);
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('bulk-delete-toggle')));
          await tester.pumpAndSettle();
          expect(find.text('เลือกแล้ว 0 รายการ'), findsOneWidget);
          // Nothing selected → the destructive button is disabled.
          expect(
            tester
                .widget<ButtonStyleButton>(
                  find.ancestor(
                    of: find.text('ลบที่เลือก (0)'),
                    matching: find.bySubtype<ButtonStyleButton>(),
                  ),
                )
                .onPressed,
            isNull,
          );

          await tester.tap(find.byKey(const Key('bulk-select-all')));
          await tester.pumpAndSettle();
          final filteredCount = all
              .where(
                (p) => p.partNo.toLowerCase().contains(
                  target.partNo.toLowerCase(),
                ),
              )
              .length;
          expect(find.text('เลือกแล้ว $filteredCount รายการ'), findsOneWidget);
          expect(filteredCount, lessThan(12));

          // Cancel → nothing deleted.
          await tester.tap(find.byKey(const Key('bulk-delete-go')));
          await settle(tester);
          expect(find.text('ลบสินค้า $filteredCount รายการ'), findsOneWidget);
          expect(find.text('การลบจะไม่สามารถกู้คืนได้'), findsOneWidget);
          // Seeded products all hold stock → explicit warning + typed confirm.
          expect(
            find.byKey(const Key('bulk-delete-stock-warning')),
            findsOneWidget,
          );
          await tester.tap(find.text('ยกเลิก'));
          await settle(tester);
          expect((await ProductsRepository(db).getAll()).length, 12);

          // Confirm: disabled until the count is typed exactly.
          await tester.tap(find.byKey(const Key('bulk-delete-go')));
          await settle(tester);
          ButtonStyleButton confirm() => tester.widget<ButtonStyleButton>(
            find.byKey(const Key('bulk-delete-confirm')),
          );
          expect(confirm().onPressed, isNull);
          await tester.enterText(
            find.byKey(const Key('bulk-delete-typed')),
            '999',
          );
          await tester.pump();
          expect(confirm().onPressed, isNull);
          await tester.enterText(
            find.byKey(const Key('bulk-delete-typed')),
            '$filteredCount',
          );
          await tester.pump();
          expect(confirm().onPressed, isNotNull);
          await tester.tap(find.byKey(const Key('bulk-delete-confirm')));
          await settle(tester);
          await settle(tester);

          final left = await ProductsRepository(db).getAll();
          expect(left.length, 12 - filteredCount);
          expect(left.any((p) => p.id == target.id), isFalse);
          expect(find.text('ลบแล้ว $filteredCount รายการ'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await db.close();
        });
      },
    );
  }
}
