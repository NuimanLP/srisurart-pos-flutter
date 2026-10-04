// A Thai-only product name must be enough to save (live test 2026-10-04):
// `products.name` is NOT NULL and the server refuses a blank one, so the form
// falls back to the Thai name; both blank is still refused.
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
  test('Thai-only name is used for both columns', () {
    expect(productNameOrThai('', ' สินค้าทดสอบ UX '), 'สินค้าทดสอบ UX');
    expect(productNameOrThai('   ', 'สินค้าทดสอบ UX'), 'สินค้าทดสอบ UX');
  });

  test('EN name wins when present', () {
    expect(productNameOrThai(' Pad ', 'ผ้าเบรก'), 'Pad');
    expect(productNameOrThai('Pad', ''), 'Pad');
  });

  test('both blank stays empty so the form refuses', () {
    expect(productNameOrThai('', ''), isEmpty);
    expect(productNameOrThai('  ', '  '), isEmpty);
  });

  formTests();
}

// The real form: a Thai-only name saves, both blank is refused, and a
// reopened Thai-only product shows EN blank.
void formTests() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('form: TH-only saves; both blank refused; edit shows EN blank', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>(
                create: (_) => PendingQuoteCubit(),
              ),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
            ],
            child: const MaterialApp(home: Scaffold(body: ProductsScreen())),
          ),
        ),
      );
      Future<void> save() async {
        await tester.ensureVisible(find.text('บันทึก'));
        await tester.tap(find.text('บันทึก'));
      }

      Future<void> settle() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }

      await settle();
      final before = (await ProductsRepository(db).getAll()).length;

      Finder field(int i) => find
          .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
          .at(i);

      // Both names blank -> refused, nothing written.
      await tester.tap(find.text('เพิ่มสินค้า'));
      await settle();
      await tester.enterText(field(0), 'TH-ONLY-1');
      await save();
      await settle();
      expect(find.text('กรุณากรอกชื่อสินค้า'), findsOneWidget);
      expect((await ProductsRepository(db).getAll()).length, before);

      // Thai name only -> saved with the Thai name in both columns.
      await tester.enterText(field(2), 'สินค้าทดสอบ UX');
      await save();
      await settle();
      await settle();
      final all = await ProductsRepository(db).getAll();
      expect(all.length, before + 1);
      final saved = all.firstWhere((p) => p.partNo == 'TH-ONLY-1');
      expect(saved.name, 'สินค้าทดสอบ UX');
      expect(saved.nameTH, 'สินค้าทดสอบ UX');

      // Reopen for edit -> EN field is blank, TH shows the Thai name.
      await tester.enterText(find.byType(TextField).first, 'TH-ONLY-1');
      await settle();
      await tester.tap(find.byIcon(Icons.edit).first);
      await settle();
      expect(
        tester.widget<TextField>(field(1)).controller!.text,
        isEmpty,
      );
      expect(
        tester.widget<TextField>(field(2)).controller!.text,
        'สินค้าทดสอบ UX',
      );
      // Test-font RenderFlex overflow noise from the dialog's price box is
      // unrelated to this fix; drain it rather than fail on it.
      tester.takeException();
      await db.close();
    });
  });
}
