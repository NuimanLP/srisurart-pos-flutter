// Owner decision 2026-10-03: a mechanic who still owes credit cannot be deleted.
// The screen refuses up front (no confirm dialog) and the row stays.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  Future<void> pumpScreen(WidgetTester tester, AppDatabase db) async {
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db),
        child: const MaterialApp(home: Scaffold(body: MechanicsScreen())),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  testWidgets('delete on a mechanic with a balance shows the refusal, no confirm dialog',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() => db.update(db.mechanics)
        .write(const MechanicsCompanion(creditBalance: Value(150))));
    await tester.runAsync(() => pumpScreen(tester, db));

    // Every seeded mechanic owes 150, so whichever row is first is refused.
    await tester.tap(find.byTooltip('ลบ').first);
    await tester.pumpAndSettle();

    expect(find.text('ช่างยังมียอดค้างชำระ ฿150 — รับชำระให้ครบก่อนลบ'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final row = await tester.runAsync(
        () => (db.select(db.mechanics)..where((t) => t.id.equals('m2'))).getSingleOrNull());
    expect(row, isNotNull);
  });
}
