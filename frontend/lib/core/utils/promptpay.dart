// PromptPay QR payload (EMVCo / Thai QR, BOT "Thai QR Code Payment Standard").
//
// Pure functions, no Flutter. Field order follows the widely used
// `promptpay-qr` npm library (dtinth) and `kittinan/php-promptpay-qr`, whose
// published test vectors `test/promptpay_payload_test.dart` checks byte for
// byte: 00, 01, 29, 58, 53, [54], 63.

/// The PromptPay application id carried in tag 29, sub-tag 00.
const promptPayAid = 'A000000677010111';

/// Whether [id] (digits only) is a PromptPay target the payload can carry:
/// a 10-digit phone number starting with `0`, a 13-digit national/tax ID, or
/// a 15-digit e-wallet ID — the server's `promptpayId` rule.
bool isValidPromptPayId(String id) =>
    RegExp(r'^(0\d{9}|\d{13}|\d{15})$').hasMatch(id);

/// The QR payload for PromptPay target [id] (digits only, see
/// [isValidPromptPayId]). With a positive [amount] the QR is dynamic
/// (tag 01 = `12`, tag 54 = the amount, 2 decimals); without one it is static
/// (`11`) and the payer types the amount.
///
/// Throws [ArgumentError] for an id that is not a valid PromptPay target.
String promptPayPayload(String id, double? amount) {
  if (!isValidPromptPayId(id)) {
    throw ArgumentError.value(id, 'id', 'not a PromptPay phone / ID / e-wallet');
  }
  final String target;
  if (id.length == 15) {
    target = _tlv('03', id); // e-wallet
  } else if (id.length == 13) {
    target = _tlv('02', id); // national ID / tax ID
  } else {
    // Phone: `0066` + the number without its leading 0, padded to 13.
    target = _tlv('01', '66${id.substring(1)}'.padLeft(13, '0'));
  }
  final dynamicQr = amount != null && amount > 0;
  final body = StringBuffer()
    ..write(_tlv('00', '01'))
    ..write(_tlv('01', dynamicQr ? '12' : '11'))
    ..write(_tlv('29', _tlv('00', promptPayAid) + target))
    ..write(_tlv('58', 'TH'))
    ..write(_tlv('53', '764'));
  if (dynamicQr) body.write(_tlv('54', _amount(amount)));
  body.write('6304');
  final s = body.toString();
  return s + crc16Ccitt(s).toRadixString(16).toUpperCase().padLeft(4, '0');
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no xorout)
/// over the UTF-8/ASCII code units of [data] — the checksum tag 63 carries.
int crc16Ccitt(String data) {
  var crc = 0xFFFF;
  for (final byte in data.codeUnits) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

String _tlv(String tag, String value) =>
    '$tag${value.length.toString().padLeft(2, '0')}$value';

/// Baht → `"1250.50"`, rounded through integer satang (as `wireMoney`).
String _amount(double baht) {
  final satang = (baht * 100).round();
  return '${satang ~/ 100}.${(satang % 100).toString().padLeft(2, '0')}';
}
