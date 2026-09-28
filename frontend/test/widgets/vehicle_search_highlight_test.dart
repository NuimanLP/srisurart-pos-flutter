// #478 — the matched substring in the vehicle-search compat text was
// highlighted with `Color(0xFFFFCC88)` text on `Color(0x59E8601C)` (orange
// tint) — a pale-orange-on-orange combo tuned for a dark background,
// unreadable on the app's default light theme. Fixed by picking the match
// text color from `Theme.of(context).brightness`, like the rest of this
// screen's `isDark` branches (vehicle_search_screen.dart `_highlight`).
//
// This seeds one product whose `compat` contains the search term, types that
// term into the search field, and inspects the rendered `RichText`'s matched
// `TextSpan` to confirm it no longer uses the old unreadable color and picks
// a readable color per theme brightness.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/core/theme/app_colors.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/presentation/screens/vehicle_search_screen.dart';

const _oldUnreadableColor = Color(0xFFFFCC88);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: 'p-highlight-test',
            partNo: 'BRK-001',
            name: 'Brake Pad',
            nameTH: 'ผ้าเบรก',
            category: 'เบรก',
            brand: 'Acme',
            price: 500,
            cost: 250,
            stock: 10,
            minStock: 1,
            compat: const Value('Toyota Hilux 2015-2020, Toyota Fortuner'),
          ),
        );
  });

  tearDown(() async => db.close());

  Future<void> pumpSearch(WidgetTester tester, {required Brightness brightness}) async {
    await tester.pumpWidget(
      RepositoryProvider<ProductsRepository>(
        create: (_) => ProductsRepository(db),
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const VehicleSearchScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hilux');
    await tester.pumpAndSettle();
  }

  TextSpan matchedSpan(WidgetTester tester) {
    // Every plain Text also renders as a RichText internally, so scan for the
    // one _highlight() built: a TextSpan with multiple children, one of
    // which carries the orange highlight background.
    for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
      final root = richText.text;
      if (root is! TextSpan || root.children == null) continue;
      final match = root.children!
          .whereType<TextSpan>()
          .where((s) => s.style?.backgroundColor != null);
      if (match.isNotEmpty) return match.first;
    }
    fail('no highlighted TextSpan found');
  }

  testWidgets('highlighted match text is not the old unreadable pale-orange (#478)', (
    tester,
  ) async {
    await pumpSearch(tester, brightness: Brightness.light);
    final span = matchedSpan(tester);
    expect(span.text, 'Hilux');
    expect(span.style?.color, isNot(_oldUnreadableColor));
    expect(span.style?.color, AppColors.navy);
  });

  testWidgets('highlighted match text picks a readable color in dark theme too (#478)', (
    tester,
  ) async {
    await pumpSearch(tester, brightness: Brightness.dark);
    final span = matchedSpan(tester);
    expect(span.text, 'Hilux');
    expect(span.style?.color, Colors.white);
  });
}
