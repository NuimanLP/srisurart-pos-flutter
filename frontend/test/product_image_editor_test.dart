// Products → แก้ไขสินค้า → รูปสินค้า (owner request 2026-10-10, contract §5):
// owner only, online only, nothing on the Drift build; removing a picture is a
// confirmed DELETE whose reply is what the editor then shows. Also
// shrinkProductPhoto, which runs on a picked photo before the PUT.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/utils/product_photo.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/widgets/product_image_editor.dart';

import 'support/fake_sync_facade.dart';

const _tenant = '0199c3a0-1111-7abc-8def-0123456789ab';
const _key = 'aaaaaaaabbbbbbbbccccccccdddddddd';

class _NoStorage implements TokenStorage {
  @override
  Future<void> clearAll() async {}
  @override
  Future<void> clearAuthTokens() async {}
  @override
  Future<String?> getAccessToken() async => null;
  @override
  Future<String?> getDeviceToken() async => null;
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<AuthUser?> getUser() async => null;
  @override
  Future<void> setAccessToken(String? token) async {}
  @override
  Future<void> setDeviceToken(String? token) async {}
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> setUser(AuthUser? user) async {}
}

class _SignedIn extends AuthRepository {
  _SignedIn(this.role)
      : super(apiClient: ApiClient(tokenStorage: _NoStorage()), tokenStorage: _NoStorage());
  final String role;
  @override
  Future<String?> sessionDeviceRole() async => 'pos';
  @override
  Future<String?> getDeviceRole() async => 'pos';
  @override
  Future<String?> getDeviceToken() async => null;
  @override
  Future<String?> sessionDeviceId() async => null;
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<AuthUser?> getCurrentUser() async =>
      AuthUser(id: 'u-1', username: 'u', role: role);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final pick = find.byKey(const Key('product-image-pick'));
  final remove = find.byKey(const Key('product-image-remove'));
  bool enabled(WidgetTester t, Finder f) =>
      t.widget<ButtonStyleButton>(f).onPressed != null;

  Future<void> pump(
    WidgetTester tester, {
    String role = 'owner',
    bool api = true,
    SyncStatus status = SyncStatus.online,
    required Future<void> Function(AppDatabase db, List<http.Request> sent, List<int> changed) body,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    final sent = <http.Request>[];
    final changed = <int>[];
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
            imageKey: const Value(_key),
          ));
      await db.into(db.appMeta).insert(AppMetaCompanion.insert(
            key: TenantCacheGuard.tenantKey,
            value: _tenant,
          ));
      final product = await db.select(db.products).getSingle();
      final client = ApiClient(
        baseUrl: 'https://shop.test',
        httpClient: MockClient((req) async {
          sent.add(req);
          return http.Response(
              jsonEncode({'status': 'success', 'data': {'id': 'p1', 'imageKey': null}}),
              200);
        }),
      );
      final ProductsRepository repo =
          api ? ApiProductsRepository(db, client) : ProductsRepository(db);
      final cubit = AuthCubit(authRepository: _SignedIn(role));
      await cubit.init();
      final facade = FakeSyncFacade(initialStatus: status);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ProductsRepository>.value(value: repo),
            RepositoryProvider<SyncFacade>.value(value: facade),
          ],
          child: BlocProvider<AuthCubit>.value(
            value: cubit,
            child: MaterialApp(
              home: Scaffold(
                body: ProductImageEditor(
                  product: product,
                  onChanged: () => changed.add(1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body(db, sent, changed);
      expect(tester.takeException(), isNull);
      await cubit.close();
      await db.close();
    });
  }

  testWidgets('owner, online: change + remove enabled; remove is a confirmed DELETE',
      (tester) async {
    await pump(tester, body: (db, sent, changed) async {
      expect(find.text('เปลี่ยนรูป'), findsOneWidget);
      expect(enabled(tester, pick), isTrue);
      expect(enabled(tester, remove), isTrue);
      expect(find.text(ApiProductsRepository.imageOwnerOnlyMessage), findsNothing);

      await tester.tap(remove);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(sent, isEmpty, reason: 'nothing is sent before the confirm');
      await tester.tap(find.text('ลบ'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      // Let the request and the Drift write finish.
      for (var i = 0; i < 10 && changed.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      expect(sent.single.method, 'DELETE');
      expect(sent.single.url.path, '/api/v1/products/p1/image');
      expect(changed, [1]);
      expect((await db.select(db.products).getSingle()).imageKey, isNull);
      expect(remove, findsNothing);
      expect(find.text('เลือกรูป'), findsOneWidget);
    });
  });

  testWidgets('cashier: sees the picture, buttons disabled, with the reason', (tester) async {
    await pump(tester, role: 'cashier', body: (db, sent, changed) async {
      expect(find.byKey(const Key('product-image-editor-thumb')), findsOneWidget);
      expect(enabled(tester, pick), isFalse);
      expect(enabled(tester, remove), isFalse);
      expect(find.text(ApiProductsRepository.imageOwnerOnlyMessage), findsOneWidget);
    });
  });

  testWidgets('owner, Degraded: buttons disabled with the offline note', (tester) async {
    await pump(tester, status: SyncStatus.degraded, body: (db, sent, changed) async {
      expect(enabled(tester, pick), isFalse);
      expect(enabled(tester, remove), isFalse);
      expect(find.text('ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะเปลี่ยนรูปสินค้าได้'), findsOneWidget);
    });
  });

  testWidgets('Drift build: no picture section at all', (tester) async {
    await pump(tester, api: false, body: (db, sent, changed) async {
      expect(find.byKey(const Key('product-image-editor-thumb')), findsNothing);
      expect(pick, findsNothing);
    });
  });

  testWidgets('shrinkProductPhoto: JPEG, long side ≤ 1600 px, alpha flattened; junk refused',
      (tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      // Left half transparent, right half red.
      canvas.drawRect(const ui.Rect.fromLTWH(1200, 0, 1200, 1200),
          ui.Paint()..color = const ui.Color(0xFFFF0000));
      final big = await recorder.endRecording().toImage(2400, 1200);
      final png = (await big.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();

      final out = await shrinkProductPhoto(png);
      expect(out.sublist(0, 3), [0xFF, 0xD8, 0xFF]); // JPEG magic
      expect(out.length, lessThan(maxProductPhotoBytes));
      final frame = await (await ui.instantiateImageCodec(out)).getNextFrame();
      expect(frame.image.width, 1600);
      expect(frame.image.height, 800);
      final px = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // The transparent half came out white, not black.
      final left = px.getUint32(4 * (400 * 1600 + 100)); // RGBA
      expect(left >> 24, greaterThan(240)); // R
      expect((left >> 16) & 0xFF, greaterThan(240)); // G

      // A small picture is not enlarged.
      final r2 = ui.PictureRecorder();
      ui.Canvas(r2).drawRect(const ui.Rect.fromLTWH(0, 0, 300, 200),
          ui.Paint()..color = const ui.Color(0xFF00FF00));
      final small = await r2.endRecording().toImage(300, 200);
      final smallPng = (await small.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      final s2 = await (await ui.instantiateImageCodec(await shrinkProductPhoto(smallPng)))
          .getNextFrame();
      expect(s2.image.width, 300);

      await expectLater(
        shrinkProductPhoto(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<Exception>()),
      );
    });
  });

  testWidgets('shrinkProductPhoto applies EXIF orientation 6 (a phone photo held upright)',
      (tester) async {
    await tester.runAsync(() async {
      // Stored 300×100: left half red, right half blue. Orientation 6 =
      // rotate 90° clockwise to display → 100×300, red on top, blue below.
      final stored = img.Image(width: 300, height: 100);
      img.fillRect(stored, x1: 0, y1: 0, x2: 149, y2: 99, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(stored, x1: 150, y1: 0, x2: 299, y2: 99, color: img.ColorRgb8(0, 0, 255));
      stored.exif.imageIfd.orientation = 6;
      final phone = img.encodeJpg(stored);
      expect(img.decodeJpgExif(phone)!.imageIfd.orientation, 6);

      final out = await shrinkProductPhoto(phone);
      final frame = await (await ui.instantiateImageCodec(out)).getNextFrame();
      expect([frame.image.width, frame.image.height], [100, 300]);
      final px = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int at(int x, int y) => px.getUint32(4 * (y * 100 + x));
      final top = at(50, 30);
      final bottom = at(50, 270);
      expect(top >> 24, greaterThan(200)); // red on top
      expect((top >> 8) & 0xFF, lessThan(60));
      expect((bottom >> 8) & 0xFF, greaterThan(200)); // blue below
      expect(bottom >> 24, lessThan(60));
      // The re-encoded JPEG carries no orientation of its own to apply twice.
      expect(img.decodeJpgExif(out)?.imageIfd.orientation, isNull);
    });
  });
}
