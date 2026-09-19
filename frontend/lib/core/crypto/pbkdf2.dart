// PBKDF2-HMAC-SHA256 key derivation utility for client-side offline PIN hashing (08 §13).
//
// Uses pure Dart and package:crypto (no native C bindings), making it compatible
// across Flutter platforms (Web, iOS, Android, Desktop).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class Pbkdf2Sha256 {
  const Pbkdf2Sha256._();

  /// Default iteration count providing a slow hash on client hardware while
  /// remaining responsive for user authentication (~10-30 ms).
  static const int defaultIterations = 10000;

  /// Default derived key length (256 bits / 32 bytes).
  static const int defaultKeyLength = 32;

  /// Generates a cryptographically secure random salt of [length] bytes (default 16 bytes).
  static Uint8List generateSalt([int length = 16]) {
    final rnd = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return bytes;
  }

  /// Derives a key from [password] and [salt] using PBKDF2 with HMAC-SHA256.
  ///
  /// Conforms to RFC 2898 / RFC 8018.
  static Uint8List deriveKey({
    required String password,
    required List<int> salt,
    int iterations = defaultIterations,
    int derivedKeyLength = defaultKeyLength,
  }) {
    if (iterations <= 0) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be positive');
    }
    if (derivedKeyLength <= 0) {
      throw ArgumentError.value(
        derivedKeyLength,
        'derivedKeyLength',
        'Must be positive',
      );
    }

    final passwordBytes = utf8.encode(password);
    final hmac = Hmac(sha256, passwordBytes);

    final numBlocks = (derivedKeyLength + 31) ~/ 32;
    final derivedKey = Uint8List(numBlocks * 32);

    for (int block = 1; block <= numBlocks; block++) {
      // U_1 = PRF(password, salt || INT_32_BE(block))
      final blockBytes = ByteData(4)..setUint32(0, block, Endian.big);
      final initialInput = [...salt, ...blockBytes.buffer.asUint8List()];
      var u = hmac.convert(initialInput).bytes;
      final xorSum = Uint8List.fromList(u);

      for (int iter = 1; iter < iterations; iter++) {
        u = hmac.convert(u).bytes;
        for (int i = 0; i < 32; i++) {
          xorSum[i] ^= u[i];
        }
      }

      derivedKey.setRange(
        (block - 1) * 32,
        block * 32,
        xorSum,
      );
    }

    return Uint8List.sublistView(derivedKey, 0, derivedKeyLength);
  }

  /// Converts bytes to a lowercase hexadecimal string.
  static String toHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toLowerCase();
  }

  /// Parses a lowercase or uppercase hexadecimal string into bytes.
  static Uint8List fromHex(String hex) {
    final clean = hex.trim();
    if (clean.length % 2 != 0) {
      throw const FormatException('Hex string must have an even length');
    }
    final result = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < clean.length; i += 2) {
      result[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  /// Combines a random salt and a device identifier into a bound salt for device binding (E5).
  static List<int> buildDeviceBoundSalt({
    required List<int> salt,
    required String? deviceId,
  }) {
    final devIdBytes = utf8.encode(deviceId ?? 'unknown-device');
    return [...salt, 0x3A, ...devIdBytes]; // 0x3A is ':'
  }
}
