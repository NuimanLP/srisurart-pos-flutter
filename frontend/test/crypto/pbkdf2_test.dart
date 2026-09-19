import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/crypto/pbkdf2.dart';

void main() {
  group('Pbkdf2Sha256', () {
    test('derives reproducible key for same password and salt', () {
      final salt = utf8.encode('salt1234');
      final key1 = Pbkdf2Sha256.deriveKey(
        password: '1234',
        salt: salt,
        iterations: 100,
      );
      final key2 = Pbkdf2Sha256.deriveKey(
        password: '1234',
        salt: salt,
        iterations: 100,
      );
      expect(key1, equals(key2));
      expect(key1.length, equals(32));
    });

    test('different password or salt produces different key', () {
      final salt1 = utf8.encode('salt1');
      final salt2 = utf8.encode('salt2');
      final key1 = Pbkdf2Sha256.deriveKey(
        password: '1234',
        salt: salt1,
        iterations: 100,
      );
      final key2 = Pbkdf2Sha256.deriveKey(
        password: '1235',
        salt: salt1,
        iterations: 100,
      );
      final key3 = Pbkdf2Sha256.deriveKey(
        password: '1234',
        salt: salt2,
        iterations: 100,
      );

      expect(key1, isNot(equals(key2)));
      expect(key1, isNot(equals(key3)));
    });

    test('toHex and fromHex roundtrip correctly', () {
      final salt = Pbkdf2Sha256.generateSalt(16);
      final hex = Pbkdf2Sha256.toHex(salt);
      final parsed = Pbkdf2Sha256.fromHex(hex);
      expect(parsed, equals(salt));
      expect(hex.length, equals(32));
    });

    test('buildDeviceBoundSalt binds deviceId', () {
      final salt = utf8.encode('random-salt');
      final bound1 = Pbkdf2Sha256.buildDeviceBoundSalt(
        salt: salt,
        deviceId: 'pos-1',
      );
      final bound2 = Pbkdf2Sha256.buildDeviceBoundSalt(
        salt: salt,
        deviceId: 'pos-2',
      );
      expect(bound1, isNot(equals(bound2)));

      final key1 = Pbkdf2Sha256.deriveKey(
        password: '9999',
        salt: bound1,
        iterations: 50,
      );
      final key2 = Pbkdf2Sha256.deriveKey(
        password: '9999',
        salt: bound2,
        iterations: 50,
      );
      expect(key1, isNot(equals(key2)));
    });

    test('constantTimeEquals compares strings securely and accurately', () {
      expect(Pbkdf2Sha256.constantTimeEquals('abc', 'abc'), isTrue);
      expect(Pbkdf2Sha256.constantTimeEquals('abc', 'abd'), isFalse);
      expect(Pbkdf2Sha256.constantTimeEquals('abc', 'abcd'), isFalse);
      expect(Pbkdf2Sha256.constantTimeEquals('', ''), isTrue);
      expect(Pbkdf2Sha256.constantTimeEquals('abc', ''), isFalse);
    });
  });
}
