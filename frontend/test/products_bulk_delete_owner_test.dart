// Bulk product delete — owner decisions 2026-10-01.
//
//  • A product in an open PO, an active quote or a parked bill on this device
//    is WARNED about in the confirm dialog (which document) and stays
//    deletable.
//  • Signed-in build: only an `owner` session that is not on the `pos` device
//    may enter selection mode; otherwise the toggle is disabled with a reason,
//    and losing the right mid-selection drops the selection.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';

const _owner = AuthUser(id: 'u1', username: 'owner', role: 'owner');

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<AuthCubit?> pumpScreen(
    WidgetTester tester,
    AppDatabase db, {
    bool requireLogin = false,
    AuthState? auth,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AuthCubit? cubit;
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db, useApiRepositories: false),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
            BlocProvider<CartCubit>(create: (_) => CartCubit()),
            BlocProvider<AuthCubit>(
              create: (ctx) {
                cubit = AuthCubit(authRepository: ctx.read<AuthRepository>());
                if (auth != null) cubit!.emit(auth);
                return cubit!;
              },
            ),
          ],
          child: MaterialApp(
            home: Scaffold(body: ProductsScreen(requireLogin: requireLogin)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    return cubit;
  }

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Finder toggle() => find.byKey(const Key('bulk-delete-toggle'));
  VoidCallback? toggleOnPressed(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(toggle()).onPressed;

  testWidgets('products in an open PO, an active quote and a parked bill are '
      'warned about by document, and still deleted', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      final all = await ProductsRepository(db).getAll();
      final inPo = all[0], inQuote = all[1], inParked = all[2];
      final now = DateTime.now();
      await db.into(db.purchaseOrders).insert(
        PurchaseOrdersCompanion.insert(
          id: 'po1',
          poNo: 'PO-TEST-1',
          supplier: 's',
          createdAt: now,
        ),
      );
      await db.into(db.poItems).insert(
        PoItemsCompanion.insert(
          poId: 'po1',
          partNo: inPo.partNo,
          name: 'n',
          qty: 1,
          cost: 1,
        ),
      );
      await db.into(db.quotes).insert(
        QuotesCompanion.insert(
          id: 'q1',
          quoteNo: 'QT-TEST-1',
          date: now,
          validUntil: now.add(const Duration(days: 7)),
        ),
      );
      await db.into(db.quoteItems).insert(
        QuoteItemsCompanion.insert(
          quoteId: 'q1',
          productId: Value(inQuote.id),
          name: 'n',
          qty: 1,
          price: 1,
        ),
      );
      await db.into(db.parkedSales).insert(
        ParkedSalesCompanion.insert(
          id: 'pk1',
          parkedAt: now,
          payload: '{"items":[{"productId":"${inParked.id}","qty":1}]}',
        ),
      );

      await pumpScreen(tester, db);
      await settle(tester);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      for (final p in [inPo, inQuote, inParked]) {
        await tester.tap(find.text(p.partNo).first);
      }
      await tester.pumpAndSettle();
      expect(find.text('เลือกแล้ว 3 รายการ'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk-delete-go')));
      await settle(tester);
      expect(
        find.byKey(const Key('bulk-delete-docref-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('⚠ มี 3 รายการที่อยู่ใน'), findsOneWidget);
      expect(
        find.text('${inPo.partNo} · อยู่ใน: ใบสั่งซื้อ PO-TEST-1'),
        findsOneWidget,
      );
      expect(
        find.text('${inQuote.partNo} · อยู่ใน: ใบเสนอราคา QT-TEST-1'),
        findsOneWidget,
      );
      expect(
        find.textContaining('${inParked.partNo} · อยู่ใน: บิลที่พัก '),
        findsOneWidget,
      );

      // Still deletable — seeded stock keeps the typed confirm (unchanged).
      await tester.enterText(find.byKey(const Key('bulk-delete-typed')), '3');
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-delete-confirm')));
      await settle(tester);
      await settle(tester);
      final left = (await ProductsRepository(db).getAll()).map((p) => p.id);
      for (final p in [inPo, inQuote, inParked]) {
        expect(left, isNot(contains(p.id)));
      }
      await db.close();
    });
  });

  testWidgets('no document reference → no doc warning', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await pumpScreen(tester, db);
      await settle(tester);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-delete-go')));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byKey(const Key('bulk-delete-docref-warning')),
        findsNothing,
      );
      await db.close();
    });
  });

  group('owner gating (signed-in build)', () {
    testWidgets('pos device: toggle disabled with the reason', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await pumpScreen(
          tester,
          db,
          requireLogin: true,
          auth: const Authenticated(user: _owner, deviceRole: 'pos'),
        );
        await settle(tester);
        expect(toggleOnPressed(tester), isNull);
        expect(find.byTooltip(bulkDeleteOwnerOnly), findsOneWidget);
        await db.close();
      });
    });

    testWidgets('not signed in: toggle disabled', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await pumpScreen(
          tester,
          db,
          requireLogin: true,
          auth: const Unauthenticated(),
        );
        await settle(tester);
        expect(toggleOnPressed(tester), isNull);
        await db.close();
      });
    });

    testWidgets('owner on a backoffice device may bulk delete; switching to '
        'a pos session drops the selection', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        final cubit = await pumpScreen(
          tester,
          db,
          requireLogin: true,
          auth: const Authenticated(user: _owner, deviceRole: 'backoffice'),
        );
        await settle(tester);
        expect(toggleOnPressed(tester), isNotNull);
        expect(find.byTooltip(bulkDeleteOwnerOnly), findsNothing);
        await tester.tap(toggle());
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bulk-select-all')));
        await tester.pumpAndSettle();
        expect(find.text('เลือกแล้ว 12 รายการ'), findsOneWidget);

        cubit!.emit(const Authenticated(user: _owner, deviceRole: 'pos'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bulk-delete-go')), findsNothing);
        expect(toggleOnPressed(tester), isNull);
        expect(find.text('เลือกเพื่อลบ'), findsOneWidget);
        await db.close();
      });
    });

    testWidgets('Drift-only build (no login): no gate', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await pumpScreen(tester, db, auth: const Unauthenticated());
        await settle(tester);
        expect(toggleOnPressed(tester), isNotNull);
        await db.close();
      });
    });
  });
}
