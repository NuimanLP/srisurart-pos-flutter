// #480 — shelf-label price strip hard-coded "รวม VAT 7%" (label_printer.dart
// `_pdfLabel` at what was line 223, and the on-screen `_ShelfLabel` preview
// at what was line 692) instead of reading the shop's configured VAT (%)
// (`Settings.taxRate`, already read the same way by products_screen.dart's
// price-calculator tab). Fixed by having `_LabelPrinterState` load
// `SettingsRepository.getSettings().taxRate` and format both labels from it
// (`_taxLabel`), the same pattern `_PriceCalcTabState` already used.
//
// The on-screen `_ShelfLabel` preview and the printed PDF share the same
// `_taxLabel` getter/value, so this widget test (which can inspect rendered
// text) covers the formatting logic feeding both paths.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/settings_repository.dart';
import 'package:srisurart_pos/presentation/widgets/label_printer.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'p-vat-test',
            partNo: 'BRK-001',
            name: 'Brake Pad',
            nameTH: 'ผ้าเบรก',
            category: 'เบรก',
            brand: 'Acme',
            price: 500,
            cost: 250,
            stock: 10,
            minStock: 1,
          ),
        );
  });

  tearDown(() async => db.close());

  testWidgets(
    'shelf label preview reads a non-default VAT rate from settings (#480)',
    (tester) async {
      await (db.update(db.settingsRow)..where((t) => t.id.equals(0))).write(
        const SettingsRowCompanion(taxRate: Value(10)),
      );
      final products = await db.select(db.products).get();
      await tester.pumpWidget(
        RepositoryProvider<SettingsRepository>(
          create: (_) => SettingsRepository(db),
          child: MaterialApp(
            home: Scaffold(
              body: LabelPrinter(
                products: products,
                selectedIds: const ['p-vat-test'],
                categories: const ['เบรก'],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('รวม VAT 10%'), findsOneWidget);
      expect(find.text('รวม VAT 7%'), findsNothing);
    },
  );

  testWidgets('shelf label preview defaults to the seeded 7% VAT (#480)', (
    tester,
  ) async {
    final products = await db.select(db.products).get();
    await tester.pumpWidget(
      RepositoryProvider<SettingsRepository>(
        create: (_) => SettingsRepository(db),
        child: MaterialApp(
          home: Scaffold(
            body: LabelPrinter(
              products: products,
              selectedIds: const ['p-vat-test'],
              categories: const ['เบรก'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('รวม VAT 7%'), findsOneWidget);
  });
}
