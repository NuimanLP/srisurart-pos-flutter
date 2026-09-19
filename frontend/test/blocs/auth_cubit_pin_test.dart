import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/crypto/pbkdf2.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/offline_pin_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';

class _FakeTokenStorage implements TokenStorage {
  String? accessToken;
  String? refreshToken;
  String? deviceToken = 'mock-device-token';
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
  late AuthCubit cubit;

  setUp(() async {
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

    cubit = AuthCubit(
      authRepository: authRepo,
      offlinePinRepository: pinRepo,
    );

    // Seed offline PIN directly into Drift AppMeta for testing
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final salt = Pbkdf2Sha256.generateSalt(16);
    final boundSalt = Pbkdf2Sha256.buildDeviceBoundSalt(
      salt: salt,
      deviceId: 'pos-1',
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
          value: 'pos-1',
        ),
        AppMetaCompanion.insert(
          key: OfflinePinRepository.keyLastLoginIat,
          value: nowSec.toString(),
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
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  group('AuthCubit.loginWithOfflinePin', () {
    test('successful PIN login transitions to Authenticated with role pos',
        () async {
      final result = await cubit.loginWithOfflinePin('1234');
      expect(result, isA<PinVerifySuccess>());

      expect(cubit.state, isA<Authenticated>());
      final state = cubit.state as Authenticated;
      expect(state.isPos, isTrue);
      expect(state.user.role, equals('owner'));
    });

    test('invalid PIN transitions to Unauthenticated with remaining attempts',
        () async {
      final result = await cubit.loginWithOfflinePin('0000');
      expect(result, isA<PinVerifyInvalid>());
      expect((result as PinVerifyInvalid).remainingAttempts, equals(4));

      expect(cubit.state, isA<Unauthenticated>());
      final state = cubit.state as Unauthenticated;
      expect(state.errorMessage, contains('เหลือโอกาสอีก 4 ครั้ง'));
    });

    test('5th failure locks PIN and shows locked error message', () async {
      for (int i = 0; i < 4; i++) {
        await cubit.loginWithOfflinePin('0000');
      }

      final result5 = await cubit.loginWithOfflinePin('0000');
      expect(result5, isA<PinVerifyLocked>());

      expect(cubit.state, isA<Unauthenticated>());
      final state = cubit.state as Unauthenticated;
      expect(state.errorMessage, contains('รหัส PIN ถูกล็อก'));
    });
  });
}
