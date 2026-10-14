// UI/UX pass 2026-10-11 (A-shell-kit audit, P1): at phone width the topbar's
// fixed-width right cluster (sync pill + theme toggle + cashier/date) used to
// overflow the row, worst while offline with unsent bills and an owner item.
// The phone topbar now shows the sync state as icon + count (label in the
// tooltip) and the time only; on a mid-width bar the pill goes icon-only only
// while the owner badge is also shown. The banner below still words it.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/theme/app_theme.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/settings_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/widgets/app_shell.dart';
import 'package:srisurart_pos/presentation/widgets/thai_format.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';

import '../support/fake_sync_facade.dart';

void main() {
  setUpAll(() => initializeDateFormatting('th'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    bool ownerItem = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final facade = FakeSyncFacade(
      initialStatus: SyncStatus.degraded,
      initialOutboxRemaining: 12,
      initialNeedsOwner: [
        if (ownerItem)
          OutboxOpView(
            opId: 'op_1',
            type: 'sale.create',
            status: OutboxOpStatus.rejected,
            attempts: 3,
            payload: const {'docNo': 'RC01'},
            docNo: 'RC01',
            createdAt: DateTime(2026, 10, 11),
          ),
      ],
    );
    final router = GoRouter(
      routes: [
        ShellRoute(
          builder: (_, _, child) => AppShell(child: child),
          routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SettingsRepository>.value(
              value: SettingsRepository(db),
            ),
            RepositoryProvider<SyncFacade>.value(value: facade),
          ],
          child: BlocProvider(
            create: (_) => ThemeModeCubit(),
            child: MaterialApp.router(
              theme: AppTheme.light,
              routerConfig: router,
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
  }

  Future<void> unmount(WidgetTester tester) => tester.runAsync(() async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
  });

  testWidgets('390 px phone: offline + unsent + owner item, no overflow', (
    tester,
  ) async {
    await pumpShell(tester, const Size(390, 844));
    expect(tester.takeException(), isNull);
    // Compact pill: the count stays visible, the words move to the tooltip.
    expect(find.text('12'), findsOneWidget);
    expect(find.byTooltip('ออฟไลน์ (ขายสำรอง) · ค้าง 12'), findsOneWidget);
    expect(find.byTooltip('รอตรวจสอบ (1)'), findsOneWidget);
    // The banner below the bar still states the offline mode in words.
    expect(find.textContaining('ออฟไลน์ (ขายสำรอง) —'), findsOneWidget);
    // Time only on the bar; the full day + date sits in its tooltip.
    final now = DateTime.now();
    expect(
      find.byTooltip(
        '${DateFormat('EEE', 'th').format(now)} '
        '${thaiDate(now)} · ${thaiTime(now)}',
      ),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('tablet, offline + owner item: badge worded, pill icon-only', (
    tester,
  ) async {
    await pumpShell(tester, const Size(820, 1180));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('ออฟไลน์ (ขายสำรอง) · ค้าง 12'), findsOneWidget);
    expect(find.text('รอตรวจสอบ (1)'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('tablet, offline only: the pill keeps its words', (tester) async {
    await pumpShell(tester, const Size(820, 1180), ownerItem: false);
    expect(tester.takeException(), isNull);
    expect(find.text('ออฟไลน์ (ขายสำรอง) · ค้าง 12'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('desktop, offline + owner item: both worded', (tester) async {
    await pumpShell(tester, const Size(1366, 768));
    expect(tester.takeException(), isNull);
    expect(find.text('ออฟไลน์ (ขายสำรอง) · ค้าง 12'), findsOneWidget);
    expect(find.text('รอตรวจสอบ (1)'), findsOneWidget);
    await unmount(tester);
  });
}
