// OfflinePinRepository — Handles client-side offline PIN lifecycle on POS terminal (08 §13).
//
// Invariants (08 §13, 09 Slice 10):
// 1. 1 PIN per `pos` device for shop account.
// 2. Setup requires online: compares PIN != password in memory, then verifies
//    password via standard POST /auth/token. Password is immediately cleared.
//    PIN or PIN hash is NEVER sent to server.
// 3. Stored in Drift AppMeta as a slow salted hash (PBKDF2-HMAC-SHA256, 10,000 iter)
//    bound to deviceId.
// 4. 3-day validity window strictly counting from `iat` of token from /auth/token.
//    /auth/refresh does NOT count and does NOT extend the window.
// 5. Degraded mode only: online hides PIN option. Degraded + > 3 days hides PIN option.
// 6. 5 failed attempts locks PIN in app until unlocked by online login.

import 'dart:convert';

import '../../core/crypto/pbkdf2.dart';
import '../../core/network/api_client.dart';
import '../../domain/models/auth_models.dart';
import '../db/database.dart';
import '../storage/token_storage.dart';

class OfflinePinRepository {
  OfflinePinRepository({
    required this.db,
    required this.tokenStorage,
    this.apiClient,
  });

  final AppDatabase db;
  final TokenStorage tokenStorage;
  final ApiClient? apiClient;

  // AppMeta keys
  static const String keyPinHash = 'offline_pin_hash';
  static const String keyPinSalt = 'offline_pin_salt';
  static const String keyDeviceId = 'offline_pin_device_id';
  static const String keyUserJson = 'offline_pin_user';
  static const String keyFailedAttempts = 'offline_pin_failed_attempts';
  static const String keyLocked = 'offline_pin_locked';
  static const String keyLastLoginIat = 'offline_pin_last_login_iat';

  /// Maximum allowed failed PIN attempts before lockout.
  static const int maxFailedAttempts = 5;

  /// Validity window in seconds: exactly 3 days (72 hours).
  static const int validityWindowSeconds = 3 * 24 * 60 * 60; // 259,200 seconds

  Future<String?> _getMeta(String key) async {
    final row = await (db.select(db.appMeta)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _setMeta(String key, String value) async {
    await db.into(db.appMeta).insertOnConflictUpdate(
          AppMetaCompanion.insert(key: key, value: value),
        );
  }

  Future<void> _deleteMeta(String key) async {
    await (db.delete(db.appMeta)..where((t) => t.key.equals(key))).go();
  }

  /// Whether an offline PIN has been configured in Drift.
  Future<bool> isPinConfigured() async {
    final hash = await _getMeta(keyPinHash);
    return hash != null && hash.isNotEmpty;
  }

  /// Checks if PIN is currently locked due to 5 failed attempts.
  Future<bool> isLocked() async {
    final lockedStr = await _getMeta(keyLocked);
    if (lockedStr == 'true') return true;
    final attempts = await getFailedAttempts();
    return attempts >= maxFailedAttempts;
  }

  /// Returns the number of consecutive failed attempts.
  Future<int> getFailedAttempts() async {
    final val = await _getMeta(keyFailedAttempts);
    if (val == null || val.isEmpty) return 0;
    return int.tryParse(val) ?? 0;
  }

  /// Returns the `iat` claim (in seconds) of the latest online /auth/token login.
  Future<int?> getLastLoginIat() async {
    final val = await _getMeta(keyLastLoginIat);
    if (val == null || val.isEmpty) return null;
    return int.tryParse(val);
  }

  /// Returns true if the 3-day window has expired (> 72 hours from last online login).
  Future<bool> isExpired({DateTime? now}) async {
    final lastIat = await getLastLoginIat();
    if (lastIat == null) return true; // No record of online login

    final currentTimeSec =
        (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final diff = currentTimeSec - lastIat;
    return diff > validityWindowSeconds;
  }

  /// Checks if PIN login is eligible to be offered and used:
  /// - Device is enrolled as POS (`deviceRole == 'pos'`)
  /// - PIN is configured
  /// - PIN is not locked
  /// - Not expired (within 3 days of latest /auth/token `iat`)
  Future<bool> isPinAvailable({
    required String? deviceRole,
    DateTime? now,
  }) async {
    if (deviceRole != 'pos') return false;
    final configured = await isPinConfigured();
    if (!configured) return false;
    final locked = await isLocked();
    if (locked) return false;
    final expired = await isExpired(now: now);
    if (expired) return false;
    return true;
  }

  /// Records the `iat` timestamp (in seconds) from a successful `POST /auth/token` login.
  ///
  /// Invariant C5: Called ONLY from `login()`, NEVER from `refresh()`.
  /// Automatically resets failed attempts and unlocks PIN.
  Future<void> recordOnlineLogin({
    required int iat,
    String? deviceId,
  }) async {
    await _setMeta(keyLastLoginIat, iat.toString());
    if (deviceId != null && deviceId.isNotEmpty) {
      await _setMeta(keyDeviceId, deviceId);
    }
    await _setMeta(keyFailedAttempts, '0');
    await _setMeta(keyLocked, 'false');
  }

  /// Configures or updates the offline PIN on this device (08 §13, C4).
  ///
  /// Steps:
  /// 1. Verifies in memory that `newPin != password`. Throws if identical.
  /// 2. Verifies password online with `POST /api/v1/auth/token`.
  /// 3. Clears password from memory immediately.
  /// 4. Generates random salt, derives slow hash with PBKDF2 bound to [deviceId].
  /// 5. Stores in Drift AppMeta. PIN or hash is NEVER sent to server.
  Future<void> setPin({
    required String password,
    required String newPin,
    required String username,
    required String deviceId,
    String? deviceToken,
    AuthUser? user,
  }) async {
    final cleanPin = newPin.trim();
    final cleanPassword = password;

    // Invariant C4: Compare in memory and reject immediately if equal.
    if (cleanPin == cleanPassword) {
      throw ArgumentError('รหัส PIN ต้องไม่ตรงกับรหัสผ่านของบัญชี');
    }

    if (cleanPin.length < 4 || cleanPin.length > 6) {
      throw ArgumentError('รหัส PIN ต้องเป็นตัวเลข 4-6 หลัก');
    }

    // Verify online credentials via POST /auth/token
    final client = apiClient ?? ApiClient(tokenStorage: tokenStorage);
    final response = await client.post(
      '/api/v1/auth/token',
      body: {
        'username': username.trim(),
        'password': cleanPassword,
        if (deviceToken != null && deviceToken.trim().isNotEmpty)
          'deviceToken': deviceToken.trim(),
      },
      skipAuth: true,
    );

    final map = response as Map<String, dynamic>;
    final accessToken = map['accessToken'] as String?;
    final claims = JwtClaims.tryParse(accessToken);
    final iat = claims?.iat ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);

    // Derive slow hash bound to deviceId
    final salt = Pbkdf2Sha256.generateSalt(16);
    final boundSalt = Pbkdf2Sha256.buildDeviceBoundSalt(
      salt: salt,
      deviceId: deviceId,
    );
    final derivedKey = Pbkdf2Sha256.deriveKey(
      password: cleanPin,
      salt: boundSalt,
      iterations: Pbkdf2Sha256.defaultIterations,
    );

    final hashHex = Pbkdf2Sha256.toHex(derivedKey);
    final saltHex = Pbkdf2Sha256.toHex(salt);

    // Persist to Drift AppMeta
    await _setMeta(keyPinHash, hashHex);
    await _setMeta(keyPinSalt, saltHex);
    await _setMeta(keyDeviceId, deviceId);
    await _setMeta(keyFailedAttempts, '0');
    await _setMeta(keyLocked, 'false');
    await _setMeta(keyLastLoginIat, iat.toString());

    if (user != null) {
      await _setMeta(keyUserJson, jsonEncode(user.toJson()));
    } else if (map['user'] != null) {
      await _setMeta(keyUserJson, jsonEncode(map['user']));
    }
  }

  /// Verifies entered PIN against stored slow hash.
  Future<PinVerifyResult> verifyPin({
    required String pin,
    required String? deviceId,
    DateTime? now,
  }) async {
    final configured = await isPinConfigured();
    if (!configured) {
      return const PinVerifyNotConfigured();
    }

    final locked = await isLocked();
    if (locked) {
      return const PinVerifyLocked();
    }

    final expired = await isExpired(now: now);
    if (expired) {
      return const PinVerifyExpired();
    }

    final storedHash = await _getMeta(keyPinHash);
    final storedSaltHex = await _getMeta(keyPinSalt);
    final storedDeviceId = await _getMeta(keyDeviceId);

    if (storedHash == null || storedSaltHex == null) {
      return const PinVerifyNotConfigured();
    }

    // Verify device binding: must match enrolled deviceId
    if (storedDeviceId != null &&
        deviceId != null &&
        storedDeviceId != deviceId) {
      return const PinVerifyNotPos();
    }

    final saltBytes = Pbkdf2Sha256.fromHex(storedSaltHex);
    final boundSalt = Pbkdf2Sha256.buildDeviceBoundSalt(
      salt: saltBytes,
      deviceId: deviceId ?? storedDeviceId,
    );

    final derivedKey = Pbkdf2Sha256.deriveKey(
      password: pin.trim(),
      salt: boundSalt,
      iterations: Pbkdf2Sha256.defaultIterations,
    );
    final computedHash = Pbkdf2Sha256.toHex(derivedKey);

    if (computedHash == storedHash) {
      // Success! Reset failed attempts
      await _setMeta(keyFailedAttempts, '0');
      return const PinVerifySuccess();
    }

    // Failure: increment attempts
    final currentAttempts = await getFailedAttempts() + 1;
    await _setMeta(keyFailedAttempts, currentAttempts.toString());

    if (currentAttempts >= maxFailedAttempts) {
      await _setMeta(keyLocked, 'true');
      return const PinVerifyLocked();
    }

    return PinVerifyInvalid(
      remainingAttempts: maxFailedAttempts - currentAttempts,
    );
  }

  /// Retrieves the cached shop user profile for offline session establishment.
  Future<AuthUser?> getStoredUser() async {
    final userJsonStr = await _getMeta(keyUserJson);
    if (userJsonStr != null && userJsonStr.isNotEmpty) {
      try {
        final map = jsonDecode(userJsonStr) as Map<String, dynamic>;
        return AuthUser.fromJson(map);
      } catch (_) {}
    }
    return tokenStorage.getUser();
  }

  /// Clears PIN configuration completely from Drift.
  Future<void> clearPin() async {
    await _deleteMeta(keyPinHash);
    await _deleteMeta(keyPinSalt);
    await _deleteMeta(keyDeviceId);
    await _deleteMeta(keyUserJson);
    await _deleteMeta(keyFailedAttempts);
    await _deleteMeta(keyLocked);
    await _deleteMeta(keyLastLoginIat);
  }
}
