// Widget tests for OwnerReviewScreen and AppShell badge.
// Covers Slice 16 (#230), 08_PHASE2_SPEC.md §14, and 09_PHASE2_LANES.md §3.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/app.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/review_items_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/domain/models/review_item.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/owner_review_screen.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';

import 'support/fake_sync_facade.dart';

class FakeReviewItemsRepository implements ReviewItemsRepository {
  List<ReviewItem> items = [];
  final List<String> reviewedCalls = [];
  Object? nextError;

  @override
  Future<List<ReviewItem>> listPending({int page = 1, int limit = 50}) async {
    if (nextError != null) throw nextError!;
    return List.of(items);
  }

  @override
  Future<void> markReviewed(String id) async {
    if (nextError != null) throw nextError!;
    reviewedCalls.add(id);
    items.removeWhere((i) => i.id == id);
  }
}

Widget buildTestWidget({
  required Widget child,
  required FakeSyncFacade syncFacade,
  required FakeReviewItemsRepository reviewItemsRepo,
}) {
  return MultiRepositoryProvider(
    providers: [
      RepositoryProvider<SyncFacade>.value(value: syncFacade),
      RepositoryProvider<ReviewItemsRepository>.value(value: reviewItemsRepo),
    ],
    child: MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeModeCubit()),
        BlocProvider(create: (_) => FontScaleCubit()),
      ],
      child: MaterialApp(
        home: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSyncFacade fakeSyncFacade;
  late FakeReviewItemsRepository fakeReviewItemsRepo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeSyncFacade = FakeSyncFacade();
    fakeReviewItemsRepo = FakeReviewItemsRepository();
  });

  tearDown(() {
    fakeSyncFacade.dispose();
  });

  group('OwnerReviewScreen - Tab 1 (ถูกปฏิเสธ / ค้าง)', () {
    testWidgets('shows empty state when no ops needing owner', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          child: const OwnerReviewScreen(),
          syncFacade: fakeSyncFacade,
          reviewItemsRepo: fakeReviewItemsRepo,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ไม่มีรายการที่ถูกปฏิเสธหรือค้างส่ง'), findsOneWidget);
      expect(find.text('ถูกปฏิเสธ / ค้าง'), findsOneWidget);
      expect(find.text('รอตรวจ'), findsOneWidget);
    });

    testWidgets('renders rejected and stuck ops with payload and details',
        (tester) async {
      final op1 = OutboxOpView(
        opId: 'op_rej_1',
        type: 'sale.create',
        status: OutboxOpStatus.rejected,
        attempts: 2,
        docNo: 'RC67091901',
        lastCode: 'INSUFFICIENT_STOCK',
        lastMessage: 'สต็อกไม่พอสำหรับสินค้า: ผ้าเบรคหน้า',
        payload: {'id': 's1', 'total': '500.00', 'items': []},
        createdAt: DateTime(2026, 9, 19, 10, 30),
      );

      final op2 = OutboxOpView(
        opId: 'op_stuck_1',
        type: 'customer.create',
        status: OutboxOpStatus.stuck,
        attempts: 5,
        lastCode: 'TIMEOUT',
        lastMessage: 'การเชื่อมต่อหมดเวลา',
        payload: {'id': 'c1', 'name': 'สมชาย'},
        createdAt: DateTime(2026, 9, 19, 11, 0),
      );

      fakeSyncFacade.emitNeedsOwner([op1, op2]);

      await tester.pumpWidget(
        buildTestWidget(
          child: const OwnerReviewScreen(),
          syncFacade: fakeSyncFacade,
          reviewItemsRepo: fakeReviewItemsRepo,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ถูกปฏิเสธ'), findsOneWidget);
      expect(find.text('ค้างส่ง'), findsOneWidget);
      expect(find.text('ขายสินค้า'), findsOneWidget);
      expect(find.text('เพิ่มลูกค้า'), findsOneWidget);
      expect(find.text('RC67091901'), findsOneWidget);
      expect(find.text('รหัสข้อผิดพลาด: INSUFFICIENT_STOCK'), findsOneWidget);
      expect(find.text('สต็อกไม่พอสำหรับสินค้า: ผ้าเบรคหน้า'), findsOneWidget);
      expect(find.text('พยายามส่งแล้ว: 2 ครั้ง'), findsOneWidget);
      expect(find.text('พยายามส่งแล้ว: 5 ครั้ง'), findsOneWidget);

      // Expand payload
      expect(find.text('ดูข้อมูล payload'), findsNWidgets(2));
      await tester.tap(find.text('ดูข้อมูล payload').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('"total": "500.00"'), findsOneWidget);
    });

    testWidgets('resend button calls syncFacade.resend', (tester) async {
      final op = OutboxOpView(
        opId: 'op_test_resend',
        type: 'sale.create',
        status: OutboxOpStatus.rejected,
        attempts: 1,
        docNo: 'RC999',
        payload: {'id': 's1'},
        createdAt: DateTime.now(),
      );

      fakeSyncFacade.emitNeedsOwner([op]);

      await tester.pumpWidget(
        buildTestWidget(
          child: const OwnerReviewScreen(),
          syncFacade: fakeSyncFacade,
          reviewItemsRepo: fakeReviewItemsRepo,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'ส่งใหม่'));
      await tester.pumpAndSettle();

      expect(fakeSyncFacade.resendCalls, ['op_test_resend']);
      expect(find.text('ส่งรายการใหม่แล้ว: RC999'), findsOneWidget);
    });

    testWidgets('discard button validates non-empty note and calls syncFacade.discard',
        (tester) async {
      final op = OutboxOpView(
        opId: 'op_test_discard',
        type: 'sale.create',
        status: OutboxOpStatus.rejected,
        attempts: 3,
        docNo: 'RC1234',
        payload: {'id': 's1'},
        createdAt: DateTime.now(),
      );

      fakeSyncFacade.emitNeedsOwner([op]);
      fakeSyncFacade.nextDiscardResult = const DiscardResult(serverHasRow: false);

      await tester.pumpWidget(
        buildTestWidget(
          child: const OwnerReviewScreen(),
          syncFacade: fakeSyncFacade,
          reviewItemsRepo: fakeReviewItemsRepo,
        ),
      );
      await tester.pumpAndSettle();

      // Tap Discard button
      await tester.tap(find.widgetWithText(OutlinedButton, 'ทิ้ง'));
      await tester.pumpAndSettle();

      // Dialog is displayed
      expect(find.text('ยืนยันการทิ้งรายการ'), findsOneWidget);
      expect(find.text('หมายเหตุการทิ้งรายการ *'), findsOneWidget);

      // Confirm with empty note -> triggers validator
      await tester.tap(find.widgetWithText(ElevatedButton, 'ยืนยันการทิ้ง'));
      await tester.pumpAndSettle();

      expect(find.text('กรุณาระบุหมายเหตุการทิ้งรายการ'), findsOneWidget);
      expect(fakeSyncFacade.discardCalls, isEmpty);

      // Enter valid note
      await tester.enterText(
        find.byType(TextFormField),
        'ลูกค้าเปลี่ยนใจ ไม่เอาแล้ว',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'ยืนยันการทิ้ง'));
      await tester.pumpAndSettle();

      expect(fakeSyncFacade.discardCalls.length, 1);
      expect(fakeSyncFacade.discardCalls.first.opId, 'op_test_discard');
      expect(
        fakeSyncFacade.discardCalls.first.note,
        'ลูกค้าเปลี่ยนใจ ไม่เอาแล้ว',
      );
      expect(
        find.text('ทิ้งรายการและลบข้อมูลในเครื่องเรียบร้อยแล้ว'),
        findsOneWidget,
      );
    });
  });

  group('OwnerReviewScreen - Tab 2 (รอตรวจ)', () {
    testWidgets('loads and renders review items and handles markReviewed',
        (tester) async {
      fakeReviewItemsRepo.items = [
        ReviewItem(
          id: 'rev_1',
          kind: ReviewItemKind.voidOffline,
          refId: 'RC670919_01',
          details: {'note': 'บิลผิด', 'amount': '250.00'},
          createdAt: DateTime(2026, 9, 19, 9, 0),
        ),
        ReviewItem(
          id: 'rev_2',
          kind: ReviewItemKind.creditOverride,
          refId: 'm_101',
          details: {'mechanic': 'ช่างนิด', 'overLimitBy': '1500.00'},
          createdAt: DateTime(2026, 9, 19, 9, 15),
        ),
      ];

      await tester.pumpWidget(
        buildTestWidget(
          child: const OwnerReviewScreen(),
          syncFacade: fakeSyncFacade,
          reviewItemsRepo: fakeReviewItemsRepo,
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Tab 2
      await tester.tap(find.text('รอตรวจ'));
      await tester.pumpAndSettle();

      expect(find.text('ยกเลิกบิลออฟไลน์'), findsOneWidget);
      expect(find.text('วงเงินเกิน (อนุมัติพิเศษ)'), findsOneWidget);
      expect(find.text('อ้างอิง: RC670919_01'), findsOneWidget);
      expect(find.text('อ้างอิง: m_101'), findsOneWidget);
      expect(find.text('ตรวจแล้ว'), findsNWidgets(2));

      // Tap "ตรวจแล้ว" on first item
      await tester.tap(find.widgetWithText(ElevatedButton, 'ตรวจแล้ว').first);
      await tester.pumpAndSettle();

      expect(fakeReviewItemsRepo.reviewedCalls, ['rev_1']);
      expect(find.text('บันทึกการตรวจสอบเรียบร้อยแล้ว'), findsOneWidget);
      expect(find.text('อ้างอิง: RC670919_01'), findsNothing);
      expect(find.text('อ้างอิง: m_101'), findsOneWidget);
    });
  });

  group('AppShell - Navigation destination and badge', () {
    testWidgets(
        'renders รอเจ้าของ nav destination with badge when needsOwner > 0',
        (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        fakeSyncFacade.emitNeedsOwner([
          OutboxOpView(
            opId: 'op_1',
            type: 'sale.create',
            status: OutboxOpStatus.rejected,
            attempts: 1,
            payload: {},
            createdAt: DateTime.now(),
          ),
        ]);

        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: repositoryProviders(
              db,
              syncFacade: fakeSyncFacade,
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
              child: const SrisurartApp(
                requireLogin: false,
              ),
            ),
          ),
        );

        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.text('รอเจ้าของ'), findsOneWidget);
        expect(find.byType(Badge), findsWidgets);

        // Unmount AppShell to cancel _TopBar's 1-second live clock timer.
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    });
  });
}
