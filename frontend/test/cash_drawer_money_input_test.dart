// The close-drawer tab's counted-cash field ("นับเงินสดจริงได้ ฿") accepted
// letters: "a400" was shown as typed, parsed as 0, and the screen reported a
// shortfall of the whole expected cash (found on mob04). The field now keeps
// only a non-negative amount with at most 2 decimals.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('counted-cash field rejects letters and malformed amounts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh-today',
              dateStr: todayKey(),
              startingCash: 1000,
              openedAt: DateTime.now(),
              isActive: const Value(true),
            ),
          );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: const MaterialApp(home: Scaffold(body: CashDrawerScreen())),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      await tester.tap(find.text('🔒 ปิดลิ้นชัก'));
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      String text() => tester.widget<TextField>(field).controller!.text;

      await tester.enterText(field, 'a400');
      await tester.pumpAndSettle();
      expect(text(), '400', reason: 'letters are dropped, digits kept');
      expect(find.text('เงินขาด −฿600'), findsOneWidget);
      expect(find.text('เงินขาด −฿1,000'), findsNothing);

      await tester.enterText(field, '400.5');
      await tester.pumpAndSettle();
      expect(text(), '400.5');

      // A second decimal point or a third decimal is refused; the text stays.
      await tester.enterText(field, '400.5.1');
      await tester.pumpAndSettle();
      expect(text(), '400.5');
      await tester.enterText(field, '400.555');
      await tester.pumpAndSettle();
      expect(text(), '400.5');

      await tester.enterText(field, '-5');
      await tester.pumpAndSettle();
      expect(text(), '5', reason: 'no negative sign');
      await db.close();
    });
  });
}
