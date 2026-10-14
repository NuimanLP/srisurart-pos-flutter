// Settings → บัญชีรับเงิน QR (owner request 2026-10-10, contract §5): the
// owner edits, everyone else reads with the reason shown, the add button stops
// at 5, and the Drift build (no sign-in) can add through the dialog. Also
// shrinkQrImage, which the dialog runs on a picked image.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/utils/qr_image.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/payment_accounts_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/widgets/payment_accounts_settings.dart';

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

/// A signed-in session with [role].
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

/// The API build's owner-only rule, without HTTP: local CRUD, `ownerOnly`.
class _OwnerOnly extends PaymentAccountsRepository {
  _OwnerOnly(super.db);
  @override
  bool get ownerOnly => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pump(
    WidgetTester tester, {
    required PaymentAccountsRepository Function(AppDatabase db) repo,
    String? role,
    int accounts = 0,
    Size size = const Size(390, 844),
    Future<void> Function(AppDatabase db)? body,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      final local = PaymentAccountsRepository(db);
      for (var i = 0; i < accounts; i++) {
        await local.addAccount(PaymentAccountInput(
          nickname: 'บัญชี ${i + 1}',
          bankCode: 'KBANK',
          kind: 'promptpay',
          promptpayId: '0812345678',
          isDefault: i == 0,
        ));
      }
      final cubit = AuthCubit(authRepository: _SignedIn(role ?? 'owner'));
      if (role != null) await cubit.init();
      await tester.pumpWidget(
        RepositoryProvider<PaymentAccountsRepository>.value(
          value: repo(db),
          child: BlocProvider<AuthCubit>.value(
            value: cubit,
            child: const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: PaymentAccountsSection()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      if (body != null) await body(db);
      await cubit.close();
      await db.close();
    });
  }

  Finder addButton() => find.text('+ เพิ่มบัญชี');

  testWidgets('owner: can add, edit, delete; no lock notice', (tester) async {
    await pump(tester, repo: _OwnerOnly.new, role: 'owner', accounts: 2, body: (_) async {
      expect(find.text(paymentAccountOwnerOnlyMessage), findsNothing);
      expect(addButton(), findsOneWidget);
      expect(find.text('แก้ไข'), findsNWidgets(2));
      expect(find.text('ลบ'), findsNWidgets(2));
      expect(find.text('ตั้งเป็นค่าเริ่มต้น'), findsOneWidget); // only the non-default
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('non-owner: read-only with the reason shown', (tester) async {
    await pump(tester, repo: _OwnerOnly.new, role: 'cashier', accounts: 2, body: (_) async {
      expect(find.text(paymentAccountOwnerOnlyMessage), findsOneWidget);
      expect(find.text('บัญชี 1'), findsOneWidget);
      expect(addButton(), findsNothing);
      expect(find.text('แก้ไข'), findsNothing);
      expect(find.text('ลบ'), findsNothing);
      expect(find.text('ตั้งเป็นค่าเริ่มต้น'), findsNothing);
    });
  });

  testWidgets('at 5 accounts the add button is disabled and the limit is said', (tester) async {
    await pump(tester, repo: _OwnerOnly.new, role: 'owner', accounts: 5, body: (_) async {
      expect(find.text('บัญชีรับเงิน 5/5'), findsOneWidget);
      final btn = tester.widget<ButtonStyleButton>(
        find.ancestor(of: addButton(), matching: find.bySubtype<ButtonStyleButton>()),
      );
      expect(btn.onPressed, isNull);
      expect(find.text(paymentAccountLimitMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Drift build (no sign-in): add a PromptPay account through the dialog',
      (tester) async {
    await pump(tester, repo: PaymentAccountsRepository.new, size: const Size(1280, 800),
        body: (db) async {
      expect(find.text('ยังไม่มีบัญชีรับเงิน QR'), findsOneWidget);
      await tester.tap(addButton());
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'ชื่อเล่น'), 'บัญชีร้าน');
      await tester.enterText(find.widgetWithText(TextField, 'หมายเลขพร้อมเพย์'), '12');
      await tester.tap(find.text('บันทึก'));
      await tester.pumpAndSettle();
      // A bad number is refused inside the dialog, which stays open.
      expect(find.textContaining('หมายเลขพร้อมเพย์ต้องเป็น'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'หมายเลขพร้อมเพย์'), '0812345678');
      await tester.tap(find.text('บันทึก'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final rows = await PaymentAccountsRepository(db).getAccounts();
      expect(rows.single.nickname, 'บัญชีร้าน');
      expect(rows.single.isDefault, isTrue, reason: 'the first account starts as the default');
      expect(find.text('บัญชีร้าน'), findsOneWidget);
      expect(find.text('ค่าเริ่มต้น'), findsOneWidget);
    });
  });

  testWidgets('ตั้งเป็นค่าเริ่มต้น moves the default', (tester) async {
    await pump(tester, repo: _OwnerOnly.new, role: 'owner', accounts: 2, body: (db) async {
      await tester.tap(find.text('ตั้งเป็นค่าเริ่มต้น'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final rows = await PaymentAccountsRepository(db).getAccounts();
      expect(rows.firstWhere((r) => r.isDefault).nickname, 'บัญชี 2');
    });
  });

  testWidgets('shrinkQrImage: long side ≤ 600 px, PNG, ≤ 300,000 bytes; junk is refused',
      (tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 1500, 1000), ui.Paint()..color = Colors.white);
      for (var i = 0; i < 30; i++) {
        canvas.drawRect(
          ui.Rect.fromLTWH(i * 50.0, (i % 5) * 200.0, 25, 25),
          ui.Paint()..color = Colors.black,
        );
      }
      final big = await recorder.endRecording().toImage(1500, 1000);
      final bytes = (await big.toByteData(format: ui.ImageByteFormat.png))!;
      final src = bytes.buffer.asUint8List();

      final out = await shrinkQrImage(src);
      expect(out.length, lessThanOrEqualTo(300000));
      expect(out.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]); // PNG magic
      final codec = await ui.instantiateImageCodec(out);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 600);
      expect(frame.image.height, 400);

      await expectLater(
        shrinkQrImage(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<Exception>()),
      );
    });
  });
}
