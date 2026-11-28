// iPad image upload (2026-11-28): shrinkProductPhoto refuses what it cannot
// handle cheaply BEFORE any decode — a file over 25 MB, or a picture over the
// server's 24 MP INPUT_PIXEL_LIMIT read from the header alone — and the header
// probe gives the displayed size (EXIF orientation applied) so the one
// target-size decode keeps the aspect ratio.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:srisurart_pos/core/errors/pos_exception.dart';
import 'package:srisurart_pos/core/utils/image_header.dart';
import 'package:srisurart_pos/core/utils/product_photo.dart';

/// A PNG signature + IHDR claiming [w]×[h], then junk: decodable only by
/// reading the header.
Uint8List _pngHeaderOnly(int w, int h) {
  final b = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add([0, 0, 0, 13])
    ..add('IHDR'.codeUnits)
    ..add([w >> 24 & 0xFF, w >> 16 & 0xFF, w >> 8 & 0xFF, w & 0xFF])
    ..add([h >> 24 & 0xFF, h >> 16 & 0xFF, h >> 8 & 0xFF, h & 0xFF])
    ..add(List.filled(64, 7));
  return b.toBytes();
}

void main() {
  group('imageHeaderSize', () {
    test('JPEG: size from SOF; EXIF orientation 6 swaps it', () {
      final stored = img.Image(width: 300, height: 100);
      expect(imageHeaderSize(img.encodeJpg(stored)), (width: 300, height: 100));
      stored.exif.imageIfd.orientation = 6;
      expect(imageHeaderSize(img.encodeJpg(stored)), (width: 100, height: 300));
    });

    test('PNG, GIF and WebP (lossless) headers', () {
      final im = img.Image(width: 321, height: 123);
      expect(imageHeaderSize(img.encodePng(im)), (width: 321, height: 123));
      expect(imageHeaderSize(img.encodeGif(im)), (width: 321, height: 123));
      expect(imageHeaderSize(_pngHeaderOnly(6000, 5000)), (width: 6000, height: 5000));
      // VP8L header: 'RIFF' size 'WEBP' 'VP8L' size, 0x2F, 14-bit w-1, 14-bit h-1.
      const w = 321, h = 123;
      final bits = (w - 1) | ((h - 1) << 14);
      final webp = Uint8List.fromList([
        ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits,
        ...'VP8L'.codeUnits, 0, 0, 0, 0, 0x2F,
        bits & 0xFF, bits >> 8 & 0xFF, bits >> 16 & 0xFF, bits >> 24 & 0xFF,
      ]);
      expect(imageHeaderSize(webp), (width: 321, height: 123));
    });

    test('malformed JPEG segments: len=0 and a SOF cut off mid-header → null', () {
      expect(imageHeaderSize(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 1, 2])), isNull);
      expect(
        imageHeaderSize(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00])),
        isNull,
      );
    });

    test('an EXIF IFD count running past its APP1 segment is not read', () {
      // APP1: Exif, II TIFF, IFD at 8 claiming 3 entries but holding 1. The
      // "3rd entry" would sit inside the next (APP2) segment, where an
      // orientation-6 entry is planted; the SOF says 300 wide × 100 high.
      final app1Payload = <int>[
        ...'Exif'.codeUnits, 0, 0, //
        0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // TIFF header
        0x03, 0x00, // count = 3 (only 1 present)
        0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2C, 0x01, 0x00, 0x00,
      ];
      final app2Payload = <int>[
        ...List.filled(8, 0),
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
      ];
      final bytes = Uint8List.fromList([
        0xFF, 0xD8,
        0xFF, 0xE1, 0, app1Payload.length + 2, ...app1Payload,
        0xFF, 0xE2, 0, app2Payload.length + 2, ...app2Payload,
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 100, 0x01, 0x2C, 0x03,
        ...List.filled(9, 0),
        0xFF, 0xD9,
      ]);
      expect(imageHeaderSize(bytes), (width: 300, height: 100));
    });

    test('not an image / truncated → null', () {
      expect(imageHeaderSize(Uint8List.fromList(List.filled(64, 7))), isNull);
      expect(imageHeaderSize(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull);
      expect(imageHeaderSize(Uint8List(0)), isNull);
    });
  });

  group('shrinkProductPhoto refuses before decoding', () {
    test('a file over 25 MB', () async {
      final huge = Uint8List(maxProductPhotoInputBytes + 1);
      await expectLater(
        shrinkProductPhoto(huge),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'PRODUCT_IMAGE_FILE_TOO_LARGE')
            .having((e) => e.message, 'message', 'ไฟล์รูปใหญ่เกินไป (เกิน 25 MB)')),
      );
    });

    test('a picture over 24 MP, from the header alone (no decode of the junk body)', () async {
      await expectLater(
        shrinkProductPhoto(_pngHeaderOnly(6000, 5000)), // 30 MP
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'PRODUCT_IMAGE_TOO_MANY_PIXELS')
            // A device limit for the owner, not a server rule.
            .having((e) => e.message, 'message', 'รูปใหญ่เกินไปสำหรับเครื่องนี้ กรุณาเลือกรูปอื่น')),
      );
    });
  });
}
