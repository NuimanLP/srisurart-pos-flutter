// Owner decision 2026-10-03 (option A): on the API build the Settings restore
// control is not offered and SnapshotRepository.importLegacyBackup refuses;
// the offline (Drift-only) build keeps both. Export stays on both.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/snapshot_repository.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/settings_screen.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';

Future<void> _openRestoreTab(
  WidgetTester tester, {
  required bool useApi,
  required Future<void> Function() expectations,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(
          db,
          useApi: useApi,
          useApiRepositories: false,
        ),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ThemeModeCubit>(create: (_) => ThemeModeCubit()),
            BlocProvider<FontScaleCubit>(create: (_) => FontScaleCubit()),
            BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
            BlocProvider<CartCubit>(create: (_) => CartCubit()),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('💾 สำรอง/กู้คืน'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('📥 กู้คืนข้อมูล'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await expectations();
    await db.close();
  });
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('API build: no restore control, Thai explanation shown',
      (tester) async {
    await _openRestoreTab(tester, useApi: true, expectations: () async {
      expect(
          find.text(SnapshotRepository.importBlockedMessage), findsOneWidget);
      expect(find.text('คลิกเพื่อเลือกไฟล์ backup'), findsNothing);
      // the export sub-tab is still offered
      expect(find.text('💾 สำรองข้อมูล'), findsOneWidget);
    });
  });

  testWidgets('offline build: restore control present', (tester) async {
    await _openRestoreTab(tester, useApi: false, expectations: () async {
      expect(find.text('คลิกเพื่อเลือกไฟล์ backup'), findsOneWidget);
      expect(find.text(SnapshotRepository.importBlockedMessage), findsNothing);
    });
  });

  test('importLegacyBackup refuses on the API build with a PosException',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = SnapshotRepository(db, importBlocked: true);
    await expectLater(
      repo.importLegacyBackup({'__meta': {}}),
      throwsA(isA<PosException>().having((e) => e.message, 'message',
          SnapshotRepository.importBlockedMessage)),
    );
  });
}
