// promptPayPayload / crc16Ccitt against published, known-good vectors.
//
// Sources (expected strings copied verbatim, inputs normalised to digits):
//  [dtinth] https://github.com/dtinth/promptpay-qr — index.test.js
//  [kittinan] https://github.com/kittinan/php-promptpay-qr — tests/PromptPayTest.php
// Both libraries emit tags in the order 00, 01, 29, 58, 53, [54], 63, which
// promptPayPayload follows, so the strings must match byte for byte.

import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/utils/promptpay.dart';

void main() {
  group('promptPayPayload — published vectors', () {
    final cases = <(String source, String id, double? amount, String expected)>[
      // Phone, no amount (static QR).
      ('dtinth', '0801234567', null,
          '00020101021129370016A000000677010111011300668012345675802TH530376463046197'),
      ('kittinan', '0899999999', null,
          '00020101021129370016A000000677010111011300668999999995802TH53037646304FE29'),
      ('kittinan', '0891234567', null,
          '00020101021129370016A000000677010111011300668912345675802TH5303764630429C1'),
      // Phone, with amount (dynamic QR).
      ('dtinth', '0000000000', 4.22,
          '00020101021229370016A000000677010111011300660000000005802TH530376454044.226304E469'),
      ('kittinan', '0891234567', 13371337.75,
          '00020101021229370016A000000677010111011300668912345675802TH5303764541113371337.756304B7D7'),
      // 13-digit national ID / tax ID, no amount.
      ('dtinth', '1111111111111', null,
          '00020101021129370016A000000677010111021311111111111115802TH530376463047B5A'),
      ('dtinth', '0123456789012', null,
          '00020101021129370016A000000677010111021301234567890125802TH530376463040CBD'),
      ('kittinan', '1234567890123', null,
          '00020101021129370016A000000677010111021312345678901235802TH53037646304EC40'),
      // 13-digit ID, with amount.
      ('kittinan', '1234567890123', 420,
          '00020101021229370016A000000677010111021312345678901235802TH53037645406420.006304BF7B'),
      // 15-digit e-wallet, without and with amount.
      ('dtinth', '012345678901234', null,
          '00020101021129390016A00000067701011103150123456789012345802TH530376463049781'),
      ('kittinan', '004999000288505', 100.25,
          '00020101021229390016A00000067701011103150049990002885055802TH53037645406100.256304369A'),
      ('kittinan', '004000006579718', 200.50,
          '00020101021229390016A00000067701011103150040000065797185802TH53037645406200.5063048A37'),
    ];
    for (final (source, id, amount, expected) in cases) {
      test('[$source] $id amount=$amount', () {
        expect(promptPayPayload(id, amount), expected);
      });
    }
  });

  test('a zero amount is a static QR (no tag 54), like the libraries', () {
    expect(
      promptPayPayload('0801234567', 0),
      promptPayPayload('0801234567', null),
    );
  });

  test('CRC-16/CCITT-FALSE check value: "123456789" → 0x29B1', () {
    expect(crc16Ccitt('123456789'), 0x29B1);
  });

  test('an invalid id is refused, never encoded', () {
    for (final bad in ['', '123', '1801234567', '08012345678', '12345678901234', 'abc']) {
      expect(isValidPromptPayId(bad), isFalse, reason: bad);
      expect(() => promptPayPayload(bad, 10), throwsArgumentError, reason: bad);
    }
  });
}
