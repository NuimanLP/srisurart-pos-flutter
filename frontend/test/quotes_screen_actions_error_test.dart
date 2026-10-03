// mob04, 2026-10-03 (API build): Quotes → "→ ขาย" / "✓ แปลงเป็นการขาย" →
// ตกลง. `POST /api/v1/quotes/:id/convert` answered 400, `_handleConvert` had no
// catch, and the counter saw nothing at all — the dialog closed and the quote
// stayed `open`. Every repository await in the screen's action handlers now
// catches and shows the counter's Thai sentence.
//
// Since the owner's #27 decision (2026-10-03, option (ข)) "→ ขาย" no longer
// writes at all: it hands the quote to checkout, and the bill converts it via
// `POST /sales` `quoteId`. The tests run the REAL `ApiQuotesRepository`
// against a mocked HTTP client.
//
// The A4 preview's app-bar button used to render a check Icon next to the
// label '✓ แปลงเป็นการขาย' — two ticks; the second test pins it to one.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/router/app_router.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_quotes_repository.dart';
import 'package:srisurart_pos/data/repositories/quotes_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/quotes_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  void setWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// One open, still-valid quote in the local cache (Drift write, no server).
  Future<String> seedOpenQuote(AppDatabase db) async {
    final repo = QuotesRepository(db);
    await repo.saveQuote(
      const QuoteInput(
        subtotal: 200,
        discount: 0,
        total: 200,
        customerName: 'ลูกค้าทดสอบ',
        customerPhone: '',
        items: [QuoteLineInput(productId: null, name: 'ไส้กรอง', qty: 2, price: 100)],
      ),
    );
    final quotes = await repo.getQuotes();
    return quotes.single.quote.id;
  }

  Future<void> pumpQuotesScreen(
    WidgetTester tester,
    AppDatabase db,
    QuotesRepository repo,
    PendingQuoteCubit pending,
  ) async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          ...repositoryProviders(db),
          RepositoryProvider<QuotesRepository>.value(value: repo),
        ],
        child: BlocProvider<PendingQuoteCubit>.value(
          value: pending,
          child: const MaterialApp(home: Scaffold(body: QuotesScreen())),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  testWidgets('"→ ขาย" writes nothing: the quote stays open and is handed to '
      'checkout for sale (#27 (ข))', (tester) async {
    setWideViewport(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pending = PendingQuoteCubit();
    addTearDown(pending.close);
    final calls = <String>[];
    final client = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      return http.Response('{"status":"error"}', 404);
    });

    await tester.runAsync(() async {
      final id = await seedOpenQuote(db);
      final repo = ApiQuotesRepository(db, ApiClient(httpClient: client));
      final router = GoRouter(
        initialLocation: '/quotes',
        routes: [
          GoRoute(
            path: '/quotes',
            builder: (_, _) => const Scaffold(body: QuotesScreen()),
          ),
          GoRoute(
            path: AppRoutes.checkout,
            builder: (_, _) => const Scaffold(body: Text('CHECKOUT')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            ...repositoryProviders(db),
            RepositoryProvider<QuotesRepository>.value(value: repo),
          ],
          child: BlocProvider<PendingQuoteCubit>.value(
            value: pending,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      await tester.tap(find.text('→ ขาย'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ตกลง'));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      expect(calls.where((c) => !c.startsWith('GET ')), isEmpty,
          reason: 'no write — the old body-less /convert was a 400 on mob04');
      expect(find.text('CHECKOUT'), findsOneWidget);
      expect(pending.state?.quote.id, id);
      expect(pending.forSale, isTrue);
      final row = await (db.select(db.quotes)..where((t) => t.id.equals(id))).getSingle();
      expect(row.status, 'open');
      expect(row.convertedAt, isNull);
    });
  });

  testWidgets('a server refusal on delete shows the Thai sentence and keeps the row '
      '(QUOTE_CONVERTED_NOT_DELETABLE, #27 Q2)', (tester) async {
    setWideViewport(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pending = PendingQuoteCubit();
    addTearDown(pending.close);
    // The cache still says open; the server knows the quote was sold meanwhile.
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        return http.Response(
          jsonEncode({
            'status': 'error',
            'error': {
              'code': 'QUOTE_CONVERTED_NOT_DELETABLE',
              'message': 'A converted quote cannot be deleted.',
            },
          }),
          409,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    await tester.runAsync(() async {
      final id = await seedOpenQuote(db);
      final repo = ApiQuotesRepository(db, ApiClient(httpClient: client));
      await pumpQuotesScreen(tester, db, repo, pending);

      await tester.tap(find.byTooltip('ลบ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ตกลง'));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      expect(find.text('ใบเสนอราคานี้แปลงเป็นการขายแล้ว ลบไม่ได้'), findsOneWidget);
      expect(find.textContaining('ApiException'), findsNothing);
      expect(
        await (db.select(db.quotes)..where((t) => t.id.equals(id))).get(),
        hasLength(1),
      );
    });
  });

  testWidgets('a converted quote offers no delete button (#27 Q2)', (tester) async {
    setWideViewport(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pending = PendingQuoteCubit();
    addTearDown(pending.close);

    await tester.runAsync(() async {
      final id = await seedOpenQuote(db);
      await (db.update(db.quotes)..where((t) => t.id.equals(id))).write(
        QuotesCompanion(
          status: const Value('converted'),
          convertedAt: Value(DateTime.now()),
        ),
      );
      await pumpQuotesScreen(tester, db, QuotesRepository(db), pending);

      expect(find.text('ดู'), findsOneWidget, reason: 'the row is shown');
      expect(find.byTooltip('ลบ'), findsNothing);
    });
  });

  testWidgets('the A4 preview convert button shows exactly one tick and is a '
      'filled button', (tester) async {
    setWideViewport(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pending = PendingQuoteCubit();
    addTearDown(pending.close);

    await tester.runAsync(() async {
      await seedOpenQuote(db);
      await pumpQuotesScreen(tester, db, QuotesRepository(db), pending);

      // The A4 body is a PdfPreview: its spinner never settles and it calls the
      // `printing` plugin, which has no implementation under `flutter test`.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('net.nfet.printing'),
        // `canRaster: false` (all keys absent) — the preview never rasterises.
        (call) async => call.method == 'printingInfo' ? <String, Object?>{} : null,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('net.nfet.printing'), null));
      await tester.tap(find.text('ดู'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final appBar = find.byType(AppBar);
      final label = find.descendant(of: appBar, matching: find.text('✓ แปลงเป็นการขาย'));
      expect(label, findsOneWidget);
      expect(find.descendant(of: appBar, matching: find.byIcon(Icons.check)), findsNothing);
      expect(
        find.ancestor(of: label, matching: find.byType(FilledButton)),
        findsOneWidget,
      );
    });
  });
}
