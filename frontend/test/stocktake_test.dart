// Stocktake (ตรวจนับสต็อก, pain-points 2026-10-23 §6.2 item 2): count → diff →
// review → apply through the EXISTING adjustStock, one product at a time.
//  • An uncounted product is ignored, never read as 0.
//  • Review lists only counted products whose count differs.
//  • Apply ends every product at its counted value (Drift build), taking the
//    delta against the stock at APPLY time.
//  • A failure stops the run and reports applied / remaining.
//  • API build: a parked adjustment is retried under the same key + body;
//    while Degraded the apply button is disabled.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/movements_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/widgets/stocktake_view.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

import 'api_customers_repository_test.dart' show InMemoryTokenStorage;
import 'support/fake_sync_facade.dart';

/// The real Drift repository, except that [failOn] refuses its adjustment.
class _FailingRepo extends ProductsRepository {
  _FailingRepo(super.db, this.failOn);
  final String failOn;

  @override
  Future<void> adjustStock(
    String productId,
    int delta,
    String type,
    String? note,
  ) async {
    if (productId == failOn) throw Exception('ทดสอบล้มเหลว');
    return super.adjustStock(productId, delta, type, note);
  }
}

Future<int> _stock(AppDatabase db, String id) async =>
    (await ProductsRepository(db).getById(id))!.stock;

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('stocktakeChanges', () {
    test('uncounted ignored, equal ignored, diff = counted − system', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final all = await ProductsRepository(db).getAll();
      final a = all[0], b = all[1], c = all[2];
      final lines = stocktakeChanges(all, {
        a.id: a.stock + 3,
        b.id: 0,
        c.id: c.stock, // counted, no difference
      });
      expect(lines.map((l) => l.product.id), [a.id, b.id]);
      expect(lines[0].diff, 3);
      expect(lines[1].diff, -b.stock);
      // Nothing counted → nothing to review (uncounted is not 0).
      expect(stocktakeChanges(all, {}), isEmpty);
      await db.close();
    });

    test('note carries the date and the optional text', () {
      final d = DateTime(2026, 10, 23);
      expect(stocktakeNote(d, ''), startsWith('ตรวจนับ '));
      expect(stocktakeNote(d, '  ชั้น A '), endsWith(' · ชั้น A'));
    });
  });

  group('applyStocktake (Drift build, real repository)', () {
    test('ends each product at its count — up, down and to 0 — with one '
        'movement each; uncounted products untouched', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = ProductsRepository(db);
      final all = await repo.getAll();
      final up = all[0], down = all[1], zero = all[2], untouched = all[3];
      final lines = stocktakeChanges(all, {
        up.id: up.stock + 4,
        down.id: down.stock - 1,
        zero.id: 0,
      });
      final before = (await MovementsRepository(db).getMovements()).length;

      final r = await applyStocktake(repo, lines, 'ตรวจนับ x');

      expect(r.failed, isNull);
      expect(r.applied, hasLength(3));
      expect(await _stock(db, up.id), up.stock + 4);
      expect(await _stock(db, down.id), down.stock - 1);
      expect(await _stock(db, zero.id), 0);
      expect(await _stock(db, untouched.id), untouched.stock);
      final mvs = await MovementsRepository(db).getMovements();
      expect(mvs.length - before, 3);
      expect(mvs.take(3).every((m) => m.note == 'ตรวจนับ x'), isTrue);
      await db.close();
    });

    test('delta is taken at apply time: stock that moved after counting '
        'still ends at the count', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = ProductsRepository(db);
      final all = await repo.getAll();
      final p = all[0];
      final lines = stocktakeChanges(all, {p.id: p.stock + 2});
      // A sale-like change between counting and applying.
      await repo.adjustStock(p.id, -1, 'sale', null);

      await applyStocktake(repo, lines, 'ตรวจนับ x');
      expect(await _stock(db, p.id), p.stock + 2);
      await db.close();
    });

    test('a failure stops the run and reports applied / failed', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final all = await ProductsRepository(db).getAll();
      final a = all[0], b = all[1], c = all[2];
      final repo = _FailingRepo(db, b.id);
      final lines = stocktakeChanges(all, {
        a.id: a.stock + 1,
        b.id: b.stock + 1,
        c.id: c.stock + 1,
      });

      final r = await applyStocktake(repo, lines, 'ตรวจนับ x');

      expect(r.applied.map((l) => l.product.id), [a.id]);
      expect(r.failed!.product.id, b.id);
      expect(r.error.toString(), contains('ทดสอบล้มเหลว'));
      expect(await _stock(db, a.id), a.stock + 1);
      expect(await _stock(db, b.id), b.stock);
      expect(await _stock(db, c.id), c.stock); // never attempted
      await db.close();
    });
  });

  group('applyStocktake (API build)', () {
    test('a 5xx leaves the adjustment parked; the retry sends the same key '
        'and body and ends at the count', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final p = (await ProductsRepository(db).getAll()).first;
      final keys = <String?>[];
      final bodies = <String>[];
      var posts = 0;
      final api = ApiClient(
        tokenStorage: InMemoryTokenStorage(),
        httpClient: MockClient((req) async {
          http.Response json(int s, Object b) => http.Response(
            jsonEncode(b),
            s,
            headers: {'content-type': 'application/json'},
          );
          if (req.method == 'GET') {
            return json(200, {'status': 'success', 'data': []});
          }
          keys.add(req.headers['Idempotency-Key']);
          bodies.add(req.body);
          posts++;
          if (posts == 1) {
            return json(504, {
              'status': 'error',
              'error': {'code': 'GATEWAY_TIMEOUT', 'message': 'x'},
            });
          }
          return json(201, {
            'status': 'success',
            'data': {'id': p.id, 'stockAfter': p.stock + 5},
          });
        }),
      );
      final repo = ApiProductsRepository(db, api);
      final all = await ProductsRepository(db).getAll();
      final lines = stocktakeChanges(all, {p.id: p.stock + 5});

      final first = await applyStocktake(repo, lines, 'ตรวจนับ x');
      expect(first.failed!.product.id, p.id);
      expect(first.applied, isEmpty);
      expect(await _stock(db, p.id), p.stock);

      final retry = await applyStocktake(repo, lines, 'ตรวจนับ x');
      expect(retry.failed, isNull);
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(1));
      expect(bodies.toSet(), hasLength(1));
      expect(jsonDecode(bodies.first)['delta'], 5);
      expect(await _stock(db, p.id), p.stock + 5);
      await db.close();
    });
  });

  group('StocktakePage', () {
    Future<void> pumpScreen(
      WidgetTester tester,
      AppDatabase db, {
      SyncFacade? syncFacade,
      double zoom = 1,
    }) async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(
            db,
            useApiRepositories: false,
            syncFacade: syncFacade,
          ),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
              BlocProvider<PendingQuoteCubit>(
                create: (_) => PendingQuoteCubit(),
              ),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
            ],
            child: MaterialApp(
              home: const Scaffold(body: ProductsScreen()),
              builder: (context, child) => UiZoom(zoom: zoom, child: child!),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    void setSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> openStocktake(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('stocktake-open')));
      await tester.tap(find.byKey(const Key('stocktake-open')));
      await settle(tester);
      expect(find.byType(StocktakePage), findsOneWidget);
    }

    Finder countField(String id) => find.byKey(ValueKey('stocktake-count-$id'));

    testWidgets('count → live diff → review lists only ≠ 0 → apply', (
      tester,
    ) async {
      setSize(tester, const Size(1280, 900));
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await pumpScreen(tester, db);
        final all = await ProductsRepository(db).getAll();
        final a = all[0], b = all[1], c = all[2];
        await openStocktake(tester);

        expect(find.text('ตรวจทาน (0)'), findsOneWidget);
        await tester.enterText(countField(a.id), '${a.stock + 2}');
        await tester.enterText(countField(b.id), '0');
        await tester.enterText(countField(c.id), '${c.stock}');
        await tester.pump();
        expect(
          tester
              .widget<Text>(find.byKey(ValueKey('stocktake-diff-${a.id}')))
              .data,
          '+2',
        );
        expect(
          tester
              .widget<Text>(find.byKey(ValueKey('stocktake-diff-${b.id}')))
              .data,
          '−${b.stock}',
        );
        expect(find.text('นับแล้ว 3 รายการ · ไม่ตรง 2 รายการ'), findsOneWidget);

        await tester.tap(find.byKey(const Key('stocktake-review')));
        await settle(tester);
        expect(find.byKey(ValueKey('stocktake-line-${a.id}')), findsOneWidget);
        expect(find.byKey(ValueKey('stocktake-line-${b.id}')), findsOneWidget);
        expect(find.byKey(ValueKey('stocktake-line-${c.id}')), findsNothing);
        expect(
          find.text('ไม่ตรง 2 รายการ · เพิ่ม 2 ชิ้น · ลด ${b.stock} ชิ้น'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('stocktake-apply')));
        await settle(tester);
        expect(find.byType(StocktakePage), findsNothing);
        expect(find.text('ปรับสต็อกตามที่นับแล้ว 2 รายการ'), findsOneWidget);
        expect(await _stock(db, a.id), a.stock + 2);
        expect(await _stock(db, b.id), 0);
        expect(await _stock(db, c.id), c.stock);
        expect(tester.takeException(), isNull);
        await db.close();
      });
    });

    testWidgets('a failure mid-way shows applied / remaining and keeps the '
        'rest for ลองอีกครั้ง', (tester) async {
      setSize(tester, const Size(1280, 900));
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        final all = await ProductsRepository(db).getAll();
        final a = all[0], b = all[1], c = all[2];
        await tester.pumpWidget(
          RepositoryProvider<ProductsRepository>.value(
            value: _FailingRepo(db, b.id),
            child: const MaterialApp(home: StocktakePage()),
          ),
        );
        await settle(tester);
        for (final p in [a, b, c]) {
          await tester.enterText(countField(p.id), '${p.stock + 1}');
        }
        await tester.pump();
        await tester.tap(find.byKey(const Key('stocktake-review')));
        await settle(tester);
        await tester.tap(find.byKey(const Key('stocktake-apply')));
        await settle(tester);

        expect(find.byType(StocktakePage), findsOneWidget);
        expect(
          find.text(
            'ปรับสต็อกไม่ครบ — ปรับแล้ว 1 รายการ · ยังไม่ได้ปรับ 2 รายการ',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('ไม่สำเร็จที่ ${b.name}'), findsOneWidget);
        expect(
          find.text('✓ ${a.name} (${a.partNo}) → ${a.stock + 1}'),
          findsOneWidget,
        );
        // The applied row left the list; the failed and the untried stay.
        expect(find.byKey(ValueKey('stocktake-line-${a.id}')), findsNothing);
        expect(find.byKey(ValueKey('stocktake-line-${b.id}')), findsOneWidget);
        expect(find.byKey(ValueKey('stocktake-line-${c.id}')), findsOneWidget);
        expect(find.text('ลองอีกครั้ง'), findsOneWidget);
        expect(await _stock(db, a.id), a.stock + 1);
        expect(await _stock(db, c.id), c.stock);
        await db.close();
      });
    });

    testWidgets('Degraded: apply disabled with the reason, nothing written', (
      tester,
    ) async {
      setSize(tester, const Size(1280, 900));
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await pumpScreen(
          tester,
          db,
          syncFacade: FakeSyncFacade(initialStatus: SyncStatus.degraded),
        );
        final a = (await ProductsRepository(db).getAll()).first;
        await openStocktake(tester);
        await tester.enterText(countField(a.id), '${a.stock + 1}');
        await tester.pump();
        await tester.tap(find.byKey(const Key('stocktake-review')));
        await settle(tester);
        final apply = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('stocktake-apply')),
        );
        expect(apply.onPressed, isNull);
        expect(
          find.text(
            'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับสินค้าได้',
          ),
          findsOneWidget,
        );
        expect(await _stock(db, a.id), a.stock);
        await db.close();
      });
    });

    for (final (label, size, zoom) in const [
      ('390 px', Size(390, 844), 1.0),
      ('1920x1080 at 3x', Size(1920, 1080), 3.0),
      ('1366x768 at 2x', Size(1366, 768), 2.0),
    ]) {
      testWidgets('$label: count and review lay out', (tester) async {
        setSize(tester, size);
        final db = AppDatabase(NativeDatabase.memory());
        await tester.runAsync(() async {
          await pumpScreen(tester, db, zoom: zoom);
          final a = (await ProductsRepository(db).getAll()).first;
          await openStocktake(tester);
          await tester.enterText(countField(a.id), '${a.stock + 1}');
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byKey(const Key('stocktake-review')));
          await tester.tap(find.byKey(const Key('stocktake-review')));
          await settle(tester);
          expect(find.byKey(const Key('stocktake-totals')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await db.close();
        });
      });
    }
  });
}

Future<void> settle(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}
