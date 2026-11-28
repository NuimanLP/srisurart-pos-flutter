// เพิ่มสินค้าใหม่ with a picture (owner, iPad stock entry 2026-11-28). The
// owner picks a photo in the Add dialog: it is shrunk and previewed, nothing
// is uploaded. บันทึก = POST /products, then PUT /products/<new id>/image.
// A product saved whose picture failed keeps the dialog open as its edit form
// with a banner (ลองอีกครั้ง / ข้ามไปก่อน); บันทึก again never makes a second
// product. Staff and the Drift build see no picture block in Add.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/utils/product_photo.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/widgets/product_image_editor.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

import 'support/fake_sync_facade.dart';
import 'support/product_image_test_auth.dart';

const _tenant = '0199c3a0-1111-7abc-8def-0123456789ab';
const _newId = '0199c3a0-2222-7abc-8def-0123456789ab';
const _key = 'aaaaaaaabbbbbbbbccccccccdddddddd';

/// A fake server: POST /products creates [_newId], PATCH echoes it, PUT
/// .../image answers [imageStatus] (200 = the key), anything else is empty.
class _Server {
  int imageStatus = 200;

  /// When set, the image PUT waits for it.
  Completer<void>? imageGate;

  /// When set, runs before the image PUT answers (e.g. a pull landing).
  Future<void> Function()? beforeImageReply;
  final sent = <http.Request>[];
  Iterable<http.Request> where(String method, String pathEnd) =>
      sent.where((r) => r.method == method && r.url.path.endsWith(pathEnd));

  Map<String, dynamic> product = {};

  Future<http.Response> handle(http.Request req) async {
    sent.add(req);
    http.Response ok(Object? data) =>
        http.Response(jsonEncode({'status': 'success', 'data': data}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
    final path = req.url.path;
    if (req.method == 'POST' && path == '/api/v1/products') {
      product = {
        ...(jsonDecode(req.body) as Map<String, dynamic>),
        'id': _newId,
        'imageKey': null,
      };
      return ok(product);
    }
    if (req.method == 'PATCH' && path == '/api/v1/products/$_newId') {
      product = {...product, ...(jsonDecode(req.body) as Map<String, dynamic>)};
      return ok(product);
    }
    if (req.method == 'PUT' && path == '/api/v1/products/$_newId/image') {
      if (imageGate != null) await imageGate!.future;
      if (beforeImageReply != null) await beforeImageReply!();
      if (imageStatus != 200) {
        return http.Response(
            jsonEncode({'status': 'error', 'code': 'INTERNAL', 'message': 'x'}), imageStatus);
      }
      return ok({'id': _newId, 'imageKey': _key});
    }
    return ok(<Object>[]);
  }
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final photo = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 48)));
  setUp(() => productPhotoPicker = () async => photo);
  tearDown(() {
    productPhotoPicker = pickProductPhotoBytes;
    productPhotoShrinker = shrinkProductPhoto;
  });

  final pick = find.byKey(const Key('product-image-pick'));
  final save = find.byKey(const Key('product-save'));
  final banner = find.byKey(const Key('product-image-failed'));

  Future<void> settle(WidgetTester tester, [bool Function()? done]) async {
    for (var i = 0; i < 60 && !(done?.call() ?? false); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  }

  /// The add-product form's category Row overflows a few px in the test
  /// font (pre-existing, see ipad_stock_entry_test.dart).
  void allowCategoryOverflow(WidgetTester tester) {
    final e = tester.takeException();
    if (e == null) return;
    expect(e.toString(), contains('A RenderFlex overflowed by'));
  }

  Future<void> run(
    WidgetTester tester, {
    String role = 'owner',
    bool api = true,
    required Future<void> Function(AppDatabase db, _Server server) body,
  }) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    final server = _Server();
    await tester.runAsync(() async {
      await db.into(db.appMeta).insert(AppMetaCompanion.insert(
            key: TenantCacheGuard.tenantKey,
            value: _tenant,
          ));
      final client = ApiClient(
        baseUrl: 'https://shop.test',
        httpClient: MockClient(server.handle),
      );
      final cubit = AuthCubit(authRepository: SignedInAs(role));
      await cubit.init();
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            ...repositoryProviders(db, useApiRepositories: false),
            RepositoryProvider<ProductsRepository>.value(
                value: api ? ApiProductsRepository(db, client) : ProductsRepository(db)),
            RepositoryProvider<SyncFacade>.value(
                value: FakeSyncFacade(initialStatus: SyncStatus.online)),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<AuthCubit>.value(value: cubit),
              BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
              BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
            ],
            child: MaterialApp(
              builder: (context, child) => UiZoom(zoom: 1.0, child: child!),
              home: const Scaffold(body: ProductsScreen()),
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('เพิ่มสินค้า'));
      await settle(tester);
      allowCategoryOverflow(tester);
      expect(find.text('เพิ่มสินค้าใหม่'), findsOneWidget);
      await body(db, server);
      allowCategoryOverflow(tester);
      await cubit.close();
      await db.close();
    });
  }

  Future<void> fillAndPickPhoto(WidgetTester tester) async {
    final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(EditableText));
    await tester.enterText(fields.at(0), 'IMG-001'); // รหัสสินค้า
    await tester.enterText(fields.at(2), 'ผ้าเบรกหน้า'); // ชื่อ (TH)
    await tester.pump();
    allowCategoryOverflow(tester);
    await tester.tap(pick);
    await settle(tester,
        () => find.byKey(const Key('product-image-local-preview')).evaluate().isNotEmpty);
    expect(find.byKey(const Key('product-image-local-preview')), findsOneWidget);
    expect(find.text('รูปจะอัปโหลดเมื่อกดบันทึก'), findsOneWidget);
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    // Until the dialog closed or บันทึก is pressable again (the save ended).
    await settle(
      tester,
      () =>
          save.evaluate().isEmpty ||
          tester.widget<ButtonStyleButton>(save).onPressed != null,
    );
    allowCategoryOverflow(tester);
  }

  testWidgets('owner: pick in Add → preview only; บันทึก = add, then the picture; closes',
      (tester) async {
    await run(tester, body: (db, server) async {
      await fillAndPickPhoto(tester);
      expect(server.where('PUT', '/image'), isEmpty, reason: 'nothing before บันทึก');

      await tapSave(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(server.where('POST', '/products'), hasLength(1));
      final put = server.where('PUT', '/$_newId/image').single;
      expect(put.headers['content-type'], 'image/jpeg');
      expect(put.bodyBytes.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
      final saved = await db.select(db.products).getSingle();
      expect(saved.id, _newId);
      expect(saved.imageKey, _key);
    });
  });

  testWidgets('add ok, picture fails → edit mode + banner; ลองอีกครั้ง sends the same bytes',
      (tester) async {
    await run(tester, body: (db, server) async {
      server.imageStatus = 503;
      await fillAndPickPhoto(tester);
      await tapSave(tester);

      expect(banner, findsOneWidget);
      expect(find.text('บันทึกสินค้าแล้ว แต่อัปโหลดรูปไม่สำเร็จ'), findsOneWidget);
      expect(find.text('ข้ามไปก่อน'), findsOneWidget);
      expect(find.text('แก้ไขสินค้า'), findsOneWidget, reason: 'now the edit form');
      expect(find.text('เพิ่มสินค้าใหม่'), findsNothing);
      expect(await db.select(db.products).get(), hasLength(1));

      server.imageStatus = 200;
      await tester.tap(find.byKey(const Key('product-image-failed-retry')));
      await settle(tester, () => find.byType(Dialog).evaluate().isEmpty);
      expect(find.byType(Dialog), findsNothing);
      final puts = server.where('PUT', '/$_newId/image').toList();
      expect(puts, hasLength(2));
      expect(puts[1].bodyBytes, puts[0].bodyBytes);
      expect(puts[1].headers['Idempotency-Key'], puts[0].headers['Idempotency-Key']);
      expect(server.where('POST', '/products'), hasLength(1));
      expect((await db.select(db.products).getSingle()).imageKey, _key);
    });
  });

  testWidgets('a second บันทึก after a failed picture makes no second product', (tester) async {
    await run(tester, body: (db, server) async {
      server.imageStatus = 503;
      await fillAndPickPhoto(tester);
      await tapSave(tester);
      expect(banner, findsOneWidget);

      // Still failing: บันทึก is an update + the same picture, never a POST.
      await tapSave(tester);
      expect(banner, findsOneWidget);
      server.imageStatus = 200;
      await tapSave(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(server.where('POST', '/products'), hasLength(1));
      expect(server.where('PATCH', '/products/$_newId'), hasLength(2));
      expect(server.where('PUT', '/$_newId/image'), hasLength(3));
      expect(await db.select(db.products).get(), hasLength(1));
    });
  });

  testWidgets('ข้ามไปก่อน closes with the product saved and no picture', (tester) async {
    await run(tester, body: (db, server) async {
      server.imageStatus = 503;
      await fillAndPickPhoto(tester);
      await tapSave(tester);
      await tester.tap(find.byKey(const Key('product-image-failed-skip')));
      await settle(tester, () => find.byType(Dialog).evaluate().isEmpty);
      expect(find.byType(Dialog), findsNothing);
      final saved = await db.select(db.products).getSingle();
      expect(saved.imageKey, isNull);
    });
  });

  testWidgets('บันทึก is held while the picture is still shrinking', (tester) async {
    final shrinking = Completer<Uint8List>();
    productPhotoShrinker = (_) => shrinking.future;
    await run(tester, body: (db, server) async {
      final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(EditableText));
      await tester.enterText(fields.at(0), 'IMG-001');
      await tester.enterText(fields.at(2), 'ผ้าเบรกหน้า');
      await tester.pump();
      allowCategoryOverflow(tester);
      await tester.tap(pick);
      await settle(tester, () => find.text('กำลังย่อรูป…').evaluate().isNotEmpty);
      expect(tester.widget<ButtonStyleButton>(save).onPressed, isNull);
      await tester.ensureVisible(save);
      await tester.tap(save, warnIfMissed: false);
      await settle(tester);
      allowCategoryOverflow(tester);
      expect(server.where('POST', '/products'), isEmpty,
          reason: 'never saved without the picture the owner is waiting for');

      shrinking.complete(photo);
      await settle(tester,
          () => find.byKey(const Key('product-image-local-preview')).evaluate().isNotEmpty);
      await tapSave(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(server.where('POST', '/products'), hasLength(1));
      expect(server.where('PUT', '/$_newId/image'), hasLength(1));
    });
  });

  testWidgets('during the upload after add: the picture stays local, picking is off, one PUT',
      (tester) async {
    await run(tester, body: (db, server) async {
      server.imageGate = Completer<void>();
      await fillAndPickPhoto(tester);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await settle(tester, () => server.where('PUT', '/image').isNotEmpty);
      await tester.pump();
      allowCategoryOverflow(tester);
      expect(find.text('กำลังอัปโหลดรูป…'), findsOneWidget);
      expect(find.byKey(const Key('product-image-local-preview')), findsOneWidget,
          reason: 'not flipped to the edit-mode editor with its own PUT');
      expect(tester.widget<ButtonStyleButton>(pick).onPressed, isNull);

      server.imageGate!.complete();
      await settle(tester, () => find.byType(Dialog).evaluate().isEmpty);
      expect(find.byType(Dialog), findsNothing);
      expect(server.where('PUT', '/$_newId/image'), hasLength(1));
    });
  });

  testWidgets('a picture upload that failed but landed anyway (row re-read) closes the dialog',
      (tester) async {
    await run(tester, body: (db, server) async {
      server.imageStatus = 503;
      server.beforeImageReply = () => (db.update(db.products)
            ..where((t) => t.id.equals(_newId)))
          .write(const ProductsCompanion(imageKey: Value(_key)));
      await fillAndPickPhoto(tester);
      await tapSave(tester);
      expect(banner, findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });
  });

  testWidgets('Esc after "saved, picture failed" still reloads the list', (tester) async {
    await run(tester, body: (db, server) async {
      server.imageStatus = 503;
      await fillAndPickPhoto(tester);
      await tapSave(tester);
      expect(banner, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, () => find.byType(Dialog).evaluate().isEmpty);
      expect(find.byType(Dialog), findsNothing);
      await settle(tester, () => find.text('IMG-001').evaluate().isNotEmpty);
      expect(find.text('IMG-001'), findsWidgets, reason: 'the new product is listed');
    });
  });

  testWidgets('cashier on the API build: no picture block in Add', (tester) async {
    await run(tester, role: 'cashier', body: (db, server) async {
      expect(pick, findsNothing);
    });
  });

  testWidgets('Drift build: no picture block in Add', (tester) async {
    await run(tester, api: false, body: (db, server) async {
      expect(pick, findsNothing);
    });
  });
}
