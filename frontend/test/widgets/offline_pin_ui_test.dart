import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/crypto/pbkdf2.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/offline_pin_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/widgets/login_form.dart';
import 'package:srisurart_pos/presentation/widgets/offline_pin_setup_dialog.dart';

import '../support/fake_sync_facade.dart';

class _FakeTokenStorage implements TokenStorage {
  String? accessToken;
  String? refreshToken;
  String? deviceToken = 'device-pos-1';
  AuthUser? user;

  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<void> setAccessToken(String? token) async => accessToken = token;
  @override
  Future<String?> getRefreshToken() async => refreshToken;
  @override
  Future<void> setRefreshToken(String? token) async => refreshToken = token;
  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<void> setDeviceToken(String? token) async => deviceToken = token;
  @override
  Future<AuthUser?> getUser() async => user;
  @override
  Future<void> setUser(AuthUser? u) async => user = u;
  @override
  Future<void> clearAuthTokens() async {
    accessToken = null;
    refreshToken = null;
    user = null;
  }

  @override
  Future<void> clearAll() async {
    accessToken = null;
    refreshToken = null;
    user = null;
    deviceToken = null;
  }
}

void main() {
  late AppDatabase db;
  late _FakeTokenStorage tokenStorage;
  late OfflinePinRepository pinRepo;
  late AuthRepository authRepo;
  late FakeSyncFacade syncFacade;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tokenStorage = _FakeTokenStorage();
    final apiClient = ApiClient(tokenStorage: tokenStorage);
    pinRepo = OfflinePinRepository(
      db: db,
      tokenStorage: tokenStorage,
      apiClient: apiClient,
    );
    authRepo = AuthRepository(
      apiClient: apiClient,
      tokenStorage: tokenStorage,
      offlinePinRepository: pinRepo,
    );
    syncFacade = FakeSyncFacade(initialStatus: SyncStatus.online);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildTestWidget({
    required AuthCubit authCubit,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<OfflinePinRepository>.value(value: pinRepo),
            RepositoryProvider<AuthRepository>.value(value: authRepo),
            RepositoryProvider<SyncFacade>.value(value: syncFacade),
          ],
          child: BlocProvider<AuthCubit>.value(
            value: authCubit,
            child: const SingleChildScrollView(child: LoginForm()),
          ),
        ),
      ),
    );
  }

  String makeToken({required int iat, String deviceId = 'pos-1'}) {
    final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'u-owner-1',
      'tid': 't-shop-1',
      'did': deviceId,
      'drole': 'pos',
      'role': 'owner',
      'iat': iat,
      'exp': iat + 900,
    })));
    return '$header.$payload.fake_sig';
  }

  Future<void> seedPin({required int iat, String deviceId = 'pos-1'}) async {
    tokenStorage.accessToken = makeToken(iat: iat, deviceId: deviceId);

    final salt = Pbkdf2Sha256.generateSalt(16);
    final boundSalt = Pbkdf2Sha256.buildDeviceBoundSalt(
      salt: salt,
      deviceId: deviceId,
    );
    final derivedKey = Pbkdf2Sha256.deriveKey(
      password: '1234',
      salt: boundSalt,
      iterations: Pbkdf2Sha256.defaultIterations,
    );

    await db.batch((b) {
      b.insertAll(db.appMeta, [
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyPinHash,
          value: Pbkdf2Sha256.toHex(derivedKey),
        ),
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyPinSalt,
          value: Pbkdf2Sha256.toHex(salt),
        ),
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyDeviceId,
          value: deviceId,
        ),
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyLastLoginIat,
          value: iat.toString(),
        ),
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyFailedAttempts,
          value: '0',
        ),
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyLocked,
          value: 'false',
        ),
      ]);
    });
  }

  group('LoginForm Offline PIN UI Criteria (08 §13)', () {
    testWidgets('ออนไลน์ → ไม่มีตัวเลือก PIN', (tester) async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await seedPin(iat: nowSec);

      final authCubit = AuthCubit(
        authRepository: authRepo,
        offlinePinRepository: pinRepo,
      );
      await authCubit.init();

      // Online status
      syncFacade.emitStatus(SyncStatus.online);

      await tester.pumpWidget(buildTestWidget(authCubit: authCubit));
      await tester.pumpAndSettle();

      // Standard online form
      expect(find.text('ชื่อผู้ใช้ (Username)'), findsOneWidget);
      expect(find.text('รหัสผ่าน (Password)'), findsOneWidget);
      expect(find.text('เข้าสู่ระบบ'), findsOneWidget);

      // Acceptance Criteria: No PIN option visible
      expect(find.text('รหัส PIN ออฟไลน์ (4-6 หลัก)'), findsNothing);
      expect(find.text('เข้าสู่ระบบ (PIN ออฟไลน์)'), findsNothing);
      expect(find.text('เข้าสู่ระบบด้วย PIN ออฟไลน์'), findsNothing);

      await authCubit.close();
    });

    testWidgets(
        'Degraded + /auth/token ล่าสุด 4 วันก่อน (refresh เมื่อวาน) → ไม่มีตัวเลือก',
        (tester) async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // 4 days ago
      final fourDaysAgo = nowSec - (4 * 24 * 3600);
      await seedPin(iat: fourDaysAgo);

      final authCubit = AuthCubit(
        authRepository: authRepo,
        offlinePinRepository: pinRepo,
      );
      await authCubit.init();

      // Degraded status
      syncFacade.emitStatus(SyncStatus.degraded);

      await tester.pumpWidget(buildTestWidget(authCubit: authCubit));
      await tester.pumpAndSettle();

      // Expired notice is shown
      expect(
        find.text(
          'ไม่สามารถใช้ PIN ออฟไลน์ได้เนื่องจากเกินกำหนด 3 วัน กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบใหม่',
        ),
        findsOneWidget,
      );

      // Acceptance Criteria: No PIN option visible
      expect(find.text('รหัส PIN ออฟไลน์ (4-6 หลัก)'), findsNothing);
      expect(find.text('เข้าสู่ระบบ (PIN ออฟไลน์)'), findsNothing);

      await authCubit.close();
    });

    testWidgets(
        'Degraded + valid PIN within 3 days → shows PIN login option and submits',
        (tester) async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // 1 day ago
      final oneDayAgo = nowSec - (1 * 24 * 3600);
      await seedPin(iat: oneDayAgo);

      final authCubit = AuthCubit(
        authRepository: authRepo,
        offlinePinRepository: pinRepo,
      );
      await authCubit.init();

      // Degraded status
      syncFacade.emitStatus(SyncStatus.degraded);

      await tester.pumpWidget(buildTestWidget(authCubit: authCubit));
      await tester.pumpAndSettle();

      // PIN option IS shown
      expect(find.text('รหัส PIN ออฟไลน์ (4-6 หลัก)'), findsOneWidget);
      expect(find.text('เข้าสู่ระบบ (PIN ออฟไลน์)'), findsOneWidget);

      // Enter wrong PIN
      await tester.enterText(
        find.byType(TextFormField).first,
        '0000',
      );
      await tester.tap(find.text('เข้าสู่ระบบ (PIN ออฟไลน์)'));
      await tester.pumpAndSettle();

      // Shows remaining attempts
      expect(find.textContaining('เหลือโอกาสอีก 4 ครั้ง'), findsOneWidget);

      // Enter correct PIN
      await tester.enterText(
        find.byType(TextFormField).first,
        '1234',
      );
      await tester.tap(find.text('เข้าสู่ระบบ (PIN ออฟไลน์)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Successfully authenticated
      expect(authCubit.state, isA<Authenticated>());
      final auth = authCubit.state as Authenticated;
      expect(auth.isPos, isTrue);

      await authCubit.close();
    });
  });

  group('OfflinePinSetupDialog Invariant C4: Setting PIN = password', () {
    testWidgets('rejects in memory when PIN == password without sending request',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => OfflinePinSetupDialog.show(ctx),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('ตั้งค่ารหัส PIN ออฟไลน์'), findsOneWidget);

      // Type same password and PIN (numeric 4 digits to satisfy digitsOnly formatter)
      await tester.enterText(
        find.byType(TextFormField).at(0),
        '1234',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        '1234',
      );
      await tester.enterText(
        find.byType(TextFormField).at(2),
        '1234',
      );

      await tester.tap(find.text('บันทึก PIN'));
      await tester.pumpAndSettle();

      // Invariant C4: Immediate error shown
      expect(
        find.text('รหัส PIN ต้องไม่ตรงกับรหัสผ่านของบัญชี'),
        findsOneWidget,
      );
    });
  });
}
