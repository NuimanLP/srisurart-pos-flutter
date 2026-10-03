import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/utils/backup_file.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

const _valid =
    '{"__meta":{"version":2,"shopName":"ร้านศรี"},"sa_products":[{"id":"p1"}]}';

Matcher _throwsMsg(String msg) =>
    throwsA(predicate((e) => e.toString().contains(msg)));

void main() {
  test('parses a valid backup (Thai text survives decoding)', () {
    final data = parseBackupFile(_bytes(_valid));
    expect((data['__meta'] as Map)['shopName'], 'ร้านศรี');
    expect(data['sa_products'], isA<List>());
  });

  test('accepts a file that starts with a UTF-8 BOM', () {
    final data = parseBackupFile(
      Uint8List.fromList([0xEF, 0xBB, 0xBF, ..._bytes(_valid)]),
    );
    expect((data['__meta'] as Map)['version'], 2);
  });

  test('accepts sa_sales without sa_products', () {
    final data = parseBackupFile(
      _bytes('{"__meta":{"version":1},"sa_sales":[]}'),
    );
    expect(data['sa_sales'], isEmpty);
  });

  test('invalid UTF-8 throws FormatException', () {
    expect(
      () => parseBackupFile(Uint8List.fromList([0x7B, 0xFF, 0x7D])),
      throwsFormatException,
    );
  });

  test('invalid JSON / empty file throws FormatException', () {
    expect(() => parseBackupFile(_bytes('{not json')), throwsFormatException);
    expect(() => parseBackupFile(Uint8List(0)), throwsFormatException);
  });

  test('non-object JSON is refused', () {
    expect(
      () => parseBackupFile(_bytes('[1,2,3]')),
      _throwsMsg('ไฟล์ว่างเปล่า'),
    );
  });

  test('missing __meta is refused', () {
    expect(
      () => parseBackupFile(_bytes('{"sa_products":[]}')),
      _throwsMsg('ไม่พบข้อมูล meta'),
    );
  });

  test('missing version is refused', () {
    expect(
      () => parseBackupFile(_bytes('{"__meta":{},"sa_products":[]}')),
      _throwsMsg('ไม่พบ version'),
    );
  });

  test('a newer version is refused', () {
    expect(
      () =>
          parseBackupFile(_bytes('{"__meta":{"version":3},"sa_products":[]}')),
      _throwsMsg('ไฟล์เวอร์ชัน 3'),
    );
  });

  test('no products and no sales is refused', () {
    expect(
      () => parseBackupFile(_bytes('{"__meta":{"version":2}}')),
      _throwsMsg('ไฟล์ว่างเปล่า'),
    );
  });
}
