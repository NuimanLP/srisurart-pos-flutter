// iPad image upload spun forever (owner, 2026-11-28; the server never saw a
// request). The editor no longer shows a busy state while the picker is open,
// a pick that never returns cannot hold the screen, processing and upload have
// hard timeouts, and ลองอีกครั้ง re-sends the same in-memory JPEG (so the
// server's idempotency fingerprint — the body bytes — is unchanged).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/errors/pos_exception.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/server_error_resolver.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/widgets/product_image_editor.dart';

import 'support/fake_sync_facade.dart';
import 'support/product_image_test_auth.dart';

const _tenant = '0199c3a0-1111-7abc-8def-0123456789ab';
const _newKey = 'eeeeeeeeffffffff0000000011111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final pick = find.byKey(const Key('product-image-pick'));
  final retry = find.byKey(const Key('product-image-retry'));
  final spinner = find.byType(CircularProgressIndicator);
  bool enabled(WidgetTester t, Finder f) =>
      t.widget<ButtonStyleButton>(f).onPressed != null;

  /// Pumps real time until [done] or ~2 s.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    required Future<Uint8List?> Function() pickPhoto,
    Future<Uint8List> Function(Uint8List)? shrink,
    Future<http.Response> Function(http.Request req, int n, AppDatabase db)? server,
    Duration processTimeout = const Duration(seconds: 20),
    Duration writeTimeout = ApiClient.defaultWriteTimeout,
    List<int>? changed,
    required Future<void> Function(AppDatabase db, List<http.Request> sent) body,
  }) async {
    tester.view.physicalSize = const Size(820, 1180);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    final sent = <http.Request>[];
    await tester.runAsync(() async {
      await db.into(db.products).insert(ProductsCompanion.insert(
            id: 'p1',
            partNo: 'HN-01',
            name: 'Oil Filter',
            nameTH: 'กรองน้ำมัน',
            category: 'เครื่องยนต์',
            brand: 'Honda',
            price: 85,
            cost: 45,
            stock: 7,
            minStock: 2,
          ));
      await db.into(db.appMeta).insert(AppMetaCompanion.insert(
            key: TenantCacheGuard.tenantKey,
            value: _tenant,
          ));
      final product = await db.select(db.products).getSingle();
      final client = ApiClient(
        baseUrl: 'https://shop.test',
        writeTimeout: writeTimeout,
        httpClient: MockClient((req) async {
          sent.add(req);
          if (server != null) return server(req, sent.length, db);
          return http.Response(
              jsonEncode({'status': 'success', 'data': {'id': 'p1', 'imageKey': _newKey}}),
              200);
        }),
      );
      final cubit = AuthCubit(authRepository: SignedInAs('owner'));
      await cubit.init();
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ProductsRepository>.value(
                value: ApiProductsRepository(db, client)),
            RepositoryProvider<SyncFacade>.value(
                value: FakeSyncFacade(initialStatus: SyncStatus.online)),
          ],
          child: BlocProvider<AuthCubit>.value(
            value: cubit,
            child: MaterialApp(
              home: Scaffold(
                body: ProductImageEditor(
                  product: product,
                  onChanged: () => changed?.add(1),
                  pickPhoto: pickPhoto,
                  shrink: shrink ?? (b) async => b,
                  processTimeout: processTimeout,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body(db, sent);
      expect(tester.takeException(), isNull);
      await cubit.close();
      await db.close();
    });
  }

  final photo = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3, 4]);

  testWidgets('a pick that never returns: no spinner, button usable, a late result is dropped',
      (tester) async {
    final first = Completer<Uint8List?>();
    var picks = 0;
    await pump(
      tester,
      pickPhoto: () {
        picks++;
        return picks == 1 ? first.future : Future.value(photo);
      },
      body: (db, sent) async {
        await tester.tap(pick);
        await tester.pump();
        expect(spinner, findsNothing, reason: 'no busy state while the picker is open');
        expect(enabled(tester, pick), isTrue);

        // The owner taps again (the iOS picker was dismissed without a word).
        await tester.tap(pick);
        await settle(tester, () => sent.isNotEmpty && find.byKey(const Key('product-image-status')).evaluate().isEmpty);
        expect(sent.single.method, 'PUT');
        expect(sent.single.bodyBytes, photo);
        expect((await db.select(db.products).getSingle()).imageKey, _newKey);

        // The first picker finally answers: stale, nothing else is sent.
        first.complete(Uint8List.fromList([9, 9, 9]));
        await settle(tester, () => false);
        expect(sent, hasLength(1));
        expect(spinner, findsNothing);
      },
    );
  });

  testWidgets('processing → uploading → done, each state shown', (tester) async {
    final shrinking = Completer<Uint8List>();
    final uploading = Completer<http.Response>();
    await pump(
      tester,
      pickPhoto: () async => photo,
      shrink: (_) => shrinking.future,
      server: (req, n, db) => uploading.future,
      body: (db, sent) async {
        await tester.tap(pick);
        await settle(tester, () => find.text('กำลังย่อรูป…').evaluate().isNotEmpty);
        expect(find.text('กำลังย่อรูป…'), findsOneWidget);
        shrinking.complete(photo);
        await settle(tester, () => find.text('กำลังอัปโหลด…').evaluate().isNotEmpty);
        expect(find.text('กำลังอัปโหลด…'), findsOneWidget);
        uploading.complete(http.Response(
            jsonEncode({'status': 'success', 'data': {'id': 'p1', 'imageKey': _newKey}}), 200));
        await settle(tester, () => find.text('กำลังอัปโหลด…').evaluate().isEmpty);
        await settle(tester, () => spinner.evaluate().isEmpty);
        expect(spinner, findsNothing);
        expect(find.text('เปลี่ยนรูป'), findsOneWidget);
      },
    );
  });

  testWidgets('a shrink that never ends → the timeout message, no spinner', (tester) async {
    await pump(
      tester,
      pickPhoto: () async => photo,
      shrink: (_) => Completer<Uint8List>().future,
      processTimeout: const Duration(milliseconds: 200),
      body: (db, sent) async {
        await tester.tap(pick);
        await settle(tester, () => find.text(productPhotoTimeoutMessage).evaluate().isNotEmpty);
        expect(find.text(productPhotoTimeoutMessage), findsOneWidget);
        expect(spinner, findsNothing);
        expect(enabled(tester, pick), isTrue);
        expect(sent, isEmpty);
      },
    );
  });

  // The upload's cut-off is ApiClient's own (a 401 refresh may resend; a UI
  // timeout shorter than that said "failed" while the server saved it).
  testWidgets('an upload with no reply → ApiClient gives up, connection message + retry; '
      'a refused file → its message', (tester) async {
    var n = 0;
    await pump(
      tester,
      pickPhoto: () async {
        n++;
        if (n == 2) {
          throw const PosException('PRODUCT_IMAGE_FILE_TOO_LARGE', 'ไฟล์รูปใหญ่เกินไป (เกิน 25 MB)');
        }
        return photo;
      },
      server: (req, _, _) => Completer<http.Response>().future,
      writeTimeout: const Duration(milliseconds: 200),
      body: (db, sent) async {
        await tester.tap(pick);
        await settle(tester, () => retry.evaluate().isNotEmpty);
        expect(find.text(ServerErrorResolver.resolve(null)), findsOneWidget);
        expect(spinner, findsNothing);
        expect(retry, findsOneWidget);

        await tester.tap(pick);
        await settle(tester, () => find.text('ไฟล์รูปใหญ่เกินไป (เกิน 25 MB)').evaluate().isNotEmpty);
        expect(find.text('ไฟล์รูปใหญ่เกินไป (เกิน 25 MB)'), findsOneWidget);
        expect(retry, findsNothing, reason: 'resending a refused file is pointless');
        expect(sent, hasLength(1));
      },
    );
  });

  testWidgets('a failed upload: ลองอีกครั้ง re-sends the same bytes under the same key',
      (tester) async {
    var shrinks = 0;
    await pump(
      tester,
      pickPhoto: () async => photo,
      // A fresh list each call: the retry must not shrink again.
      shrink: (b) async {
        shrinks++;
        return Uint8List.fromList(b);
      },
      server: (req, n, db) async => n == 1
          ? http.Response(jsonEncode({'status': 'error', 'code': 'INTERNAL', 'message': 'x'}), 503)
          : http.Response(
              jsonEncode({'status': 'success', 'data': {'id': 'p1', 'imageKey': _newKey}}), 200),
      body: (db, sent) async {
        await tester.tap(pick);
        await settle(tester, () => retry.evaluate().isNotEmpty);
        expect(retry, findsOneWidget);
        expect(spinner, findsNothing);

        await tester.tap(retry);
        await settle(tester, () => sent.length == 2 && spinner.evaluate().isEmpty);
        expect(sent, hasLength(2));
        expect(sent[1].bodyBytes, sent[0].bodyBytes);
        expect(sent[1].headers['Idempotency-Key'], isNotNull);
        expect(sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
        expect(shrinks, 1);
        expect(retry, findsNothing);
        expect((await db.select(db.products).getSingle()).imageKey, _newKey);
      },
    );
  });

  testWidgets('one shrink at a time: pick disabled while shrinking; a cancel after the '
      'timeout leaves no spinner; a re-pick waits for the old shrink', (tester) async {
    final firstShrink = Completer<Uint8List>();
    var shrinks = 0;
    Uint8List? next = photo;
    await pump(
      tester,
      pickPhoto: () async => next,
      shrink: (b) {
        shrinks++;
        return shrinks == 1 ? firstShrink.future : Future.value(b);
      },
      processTimeout: const Duration(milliseconds: 300),
      body: (db, sent) async {
        await tester.tap(pick);
        await settle(tester, () => find.text('กำลังย่อรูป…').evaluate().isNotEmpty);
        expect(enabled(tester, pick), isFalse, reason: 'no second decode while one runs');

        await settle(tester, () => find.text(productPhotoTimeoutMessage).evaluate().isNotEmpty);
        expect(spinner, findsNothing);

        // The picker is dismissed: nothing is left spinning.
        next = null;
        await tester.tap(pick);
        await settle(tester, () => false);
        expect(spinner, findsNothing);
        expect(find.text('กำลังย่อรูป…'), findsNothing);

        // A real re-pick: its shrink waits until the timed-out one has ended.
        next = photo;
        await tester.tap(pick);
        await settle(tester, () => find.text('กำลังย่อรูป…').evaluate().isNotEmpty);
        expect(shrinks, 1);
        firstShrink.complete(photo);
        await settle(tester, () => sent.isNotEmpty && spinner.evaluate().isEmpty);
        expect(shrinks, 2);
        expect(sent, hasLength(1), reason: 'the stale first result is dropped');
        expect(spinner, findsNothing);
      },
    );
  });

  testWidgets('a failed upload whose picture landed anyway (row re-read) is a success',
      (tester) async {
    final changed = <int>[];
    await pump(
      tester,
      pickPhoto: () async => photo,
      changed: changed,
      server: (req, n, db) async {
        // The picture reached the product (e.g. a pull) while the reply was lost.
        await (db.update(db.products)..where((t) => t.id.equals('p1')))
            .write(const ProductsCompanion(imageKey: Value(_newKey)));
        return http.Response(
            jsonEncode({'status': 'error', 'code': 'INTERNAL', 'message': 'x'}), 503);
      },
      body: (db, sent) async {
        await tester.tap(pick);
        await settle(tester, () => changed.isNotEmpty);
        await settle(tester, () => spinner.evaluate().isEmpty);
        expect(changed, [1]);
        expect(find.byKey(const Key('product-image-error')), findsNothing);
        expect(retry, findsNothing);
        expect(find.text('เปลี่ยนรูป'), findsOneWidget);
      },
    );
  });
}
