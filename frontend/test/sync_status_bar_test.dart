// Widget tests for SyncStatusIndicator and SyncAlertBanner in AppShell.
// Verifies Slice 19 (#195 FE) according to docs/Backend_design/02_API_SCREENS.md §8.1.1.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/app.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/widgets/app_shell.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';

import 'support/fake_sync_facade.dart';

void main() {
  late FakeSyncFacade fakeSyncFacade;
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeSyncFacade = FakeSyncFacade();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildTestApp({SyncFacade? facade}) {
    return MultiRepositoryProvider(
      providers: repositoryProviders(
        db,
        syncFacade: facade ?? fakeSyncFacade,
        useApi: false,
        useApiRepositories: false,
      ),
      child: MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => ThemeModeCubit()),
          BlocProvider(create: (_) => FontScaleCubit()),
          BlocProvider(create: (_) => PendingQuoteCubit()),
          BlocProvider(create: (_) => CartCubit()),
        ],
        child: const SrisurartApp(requireLogin: false),
      ),
    );
  }

  group('SyncStatusIndicator and SyncAlertBanner', () {
    testWidgets('renders ออนไลน์ status pill when online and no banner',
        (tester) async {
      await tester.runAsync(() async {
        fakeSyncFacade.emitStatus(SyncStatus.online);
        fakeSyncFacade.emitOutboxRemaining(0);
        fakeSyncFacade.emitNeedsOwner(const []);

        await tester.pumpWidget(buildTestApp());
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.byType(SyncStatusIndicator), findsOneWidget);
        expect(find.text('ออนไลน์'), findsOneWidget);
        // Alert banner should be empty/shrink
        expect(find.textContaining('ออฟไลน์ (ขายสำรอง)'), findsNothing);
        expect(find.textContaining('มีรายการรอเจ้าของร้านตรวจสอบ'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    });

    testWidgets(
        'renders ออฟไลน์ (ขายสำรอง) status and alert banner when degraded',
        (tester) async {
      await tester.runAsync(() async {
        fakeSyncFacade.emitStatus(SyncStatus.degraded);
        fakeSyncFacade.emitOutboxRemaining(2);
        fakeSyncFacade.emitNeedsOwner(const []);

        await tester.pumpWidget(buildTestApp());
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.byType(SyncStatusIndicator), findsOneWidget);
        expect(find.text('ออฟไลน์ (ขายสำรอง) · ค้าง 2'), findsOneWidget);
        expect(find.byType(SyncAlertBanner), findsWidgets);
        expect(
          find.text(
              'ออฟไลน์ (ขายสำรอง) — ระบบจะบันทึกรายการขายในเครื่อง และส่งข้อมูลไปยังเซิร์ฟเวอร์โดยอัตโนมัติเมื่อเชื่อมต่ออินเทอร์เน็ต'),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    });

    testWidgets('renders กำลังส่งข้อมูล... when syncing', (tester) async {
      await tester.runAsync(() async {
        fakeSyncFacade.emitStatus(SyncStatus.syncing);
        fakeSyncFacade.emitOutboxRemaining(5);
        fakeSyncFacade.emitNeedsOwner(const []);

        await tester.pumpWidget(buildTestApp());
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.byType(SyncStatusIndicator), findsOneWidget);
        expect(find.text('กำลังส่งข้อมูล... (5)'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    });

    testWidgets(
        'renders รอตรวจสอบ badge and banner when needsOwner > 0 and navigates on tap',
        (tester) async {
      await tester.runAsync(() async {
        fakeSyncFacade.emitStatus(SyncStatus.online);
        fakeSyncFacade.emitNeedsOwner([
          OutboxOpView(
            opId: 'op_stuck_1',
            type: 'sale.create',
            status: OutboxOpStatus.rejected,
            attempts: 3,
            payload: const {'docNo': 'RC670919_01'},
            docNo: 'RC670919_01',
            createdAt: DateTime.now(),
          ),
        ]);

        await tester.pumpWidget(buildTestApp());
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.text('รอตรวจสอบ (1)'), findsOneWidget);
        expect(
          find.text(
              'มีรายการรอเจ้าของร้านตรวจสอบ (1 รายการ) — กดที่นี่เพื่อเข้าหน้าตรวจรายการ'),
          findsOneWidget,
        );

        // Tap the badge in TopBar to navigate to OwnerReviewScreen
        await tester.tap(find.text('รอตรวจสอบ (1)'));
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Verify we navigated to owner review screen (shows title or tabs)
        expect(find.text('รายการรอเจ้าของ'), findsWidgets);
        expect(find.text('ถูกปฏิเสธ / ค้าง'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    });
  });
}
