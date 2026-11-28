// The brand in the stock list (owner, iPad stock entry 2026-11-28): p.brand
// was never shown. Under the name, in the table (1180 px landscape) and the
// portrait cards (820 px), a muted line "<brand> · <nameTH>" leaves out empty
// parts and shows nameTH only when it differs from the name. No new column.
// The search also matches the brand.

import 'package:drift/native.dart';
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
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

Future<void> _seed(AppDatabase db) async {
  Future<void> add(String id, String partNo, String name, String nameTH, String brand) =>
      db.into(db.products).insert(ProductsCompanion.insert(
            id: id,
            partNo: partNo,
            name: name,
            nameTH: nameTH,
            category: 'เครื่องยนต์',
            brand: brand,
            price: 100,
            cost: 50,
            stock: 10,
            minStock: 2,
          ));
  await add('b1', 'BR-001', 'Brake Pad', 'ผ้าเบรก', 'Bendix');
  await add('b2', 'BR-002', 'Oil Filter', 'กรองน้ำมัน', ''); // no brand
  await add('b3', 'BR-003', 'หัวเทียน', 'หัวเทียน', 'NGK'); // Thai-only name
}

/// The muted line under product [id]'s name, as plain text (null = none).
String? _subline(WidgetTester tester, String id) {
  final f = find.byKey(Key('product-subline-$id'));
  if (f.evaluate().isEmpty) return null;
  return tester.widget<Text>(f).textSpan!.toPlainText();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> run(WidgetTester tester, Size screen, Future<void> Function() body) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    await tester.runAsync(() async {
      await _seed(db);
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
              builder: (context, child) => UiZoom(zoom: 1.0, child: child!),
              home: const Scaffold(body: ProductsScreen()),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body();
      expect(tester.takeException(), isNull);
      await db.close();
    });
  }

  void expectSublines(WidgetTester tester) {
    expect(_subline(tester, 'b1'), 'Bendix · ผ้าเบรก');
    expect(_subline(tester, 'b2'), 'กรองน้ำมัน', reason: 'an empty brand is left out');
    expect(_subline(tester, 'b3'), 'NGK', reason: 'nameTH equal to the name is not repeated');
    final brand = tester
        .widget<Text>(find.byKey(const Key('product-subline-b1')))
        .textSpan!
        .visitChildren((s) => !(s is TextSpan && s.text == 'Bendix' && s.style?.fontWeight == FontWeight.w600));
    expect(brand, isFalse, reason: 'the brand is weight 600');
    final line = tester.widget<Text>(find.byKey(const Key('product-subline-b1')));
    expect(line.maxLines, 2, reason: 'a long brand + Thai name never pushes the row');
    expect(line.overflow, TextOverflow.ellipsis);
  }

  testWidgets('table at 1180×820: brand under the name, no new column', (tester) async {
    await run(tester, const Size(1180, 820), () async {
      expect(find.byType(DataTable), findsWidgets);
      expectSublines(tester);
      expect(find.text('แบรนด์'), findsNothing, reason: 'no brand column');
    });
  });

  testWidgets('cards at 820×1180: the same line', (tester) async {
    await run(tester, const Size(820, 1180), () async {
      expect(find.byType(DataTable), findsNothing);
      expectSublines(tester);
    });
  });

  testWidgets('search by brand finds the product', (tester) async {
    await run(tester, const Size(1180, 820), () async {
      await tester.enterText(
        find.widgetWithText(TextField, 'ค้นหา ชื่อ / รหัส…'),
        'bendix',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Brake Pad'), findsOneWidget);
      expect(find.text('Oil Filter'), findsNothing);
      expect(find.text('หัวเทียน'), findsNothing);
    });
  });
}
