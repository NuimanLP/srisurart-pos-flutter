// Shrinks a picked product photo before it is uploaded (contract §5): long side
// ≤ [maxProductPhotoSide] px, JPEG at quality [productPhotoQuality], so the raw
// `PUT /products/:id/image` stays well under the server's 3 MB limit.
//
// The size comes from the file's header ([imageHeaderSize]) — no probe decode:
// on the web a probe is a full-size decode of a 12–48 MP iPad photo on the main
// thread (iPad image upload, 2026-11-28). A file over 25 MB or a picture over
// the server's 24 MP is refused before any decode. Only a format the header
// reader does not know (e.g. HEIC from a desktop) still gets the old probe.
//
// Decoding and resizing use the engine (`ui.instantiateImageCodec` with a
// target size, as qr_image.dart does) — which also applies the photo's EXIF
// orientation (Skia's codec honours it; pinned by product_image_editor_test's
// orientation-6 case), so the re-encoded JPEG, which carries no EXIF, is
// already upright. The engine cannot encode JPEG, so the pixels are encoded by
// the pure-Dart `image` package — in a background isolate (`compute`; inline
// on the web), since a 1600 px encode is long enough to drop frames. A
// transparent PNG is flattened onto white first
// (JPEG has no alpha). The server re-decodes, strips metadata and makes the
// real thumbnail/preview; this step only saves bandwidth.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../errors/pos_exception.dart';
import 'image_header.dart';

const maxProductPhotoSide = 1600;
const productPhotoQuality = 85;

/// Below the server's 3 MB (3 × 1024 × 1024) with room to spare.
const maxProductPhotoBytes = 2900000;

/// A picked file larger than this is refused before it is decoded.
const maxProductPhotoInputBytes = 25 * 1024 * 1024;

/// The server's `INPUT_PIXEL_LIMIT` (image-pipeline.ts): a bigger picture is
/// refused before it is decoded.
const maxProductPhotoInputPixels = 24000000;

const productPhotoFileTooLarge = PosException(
  'PRODUCT_IMAGE_FILE_TOO_LARGE',
  'ไฟล์รูปใหญ่เกินไป (เกิน 25 MB)', // agent ร่าง
);

/// [source] (anything the engine decodes) → JPEG bytes, long side ≤
/// [maxSide], length ≤ [maxBytes]. Too large at full size → 20 % smaller
/// steps down to 400 px before it is refused.
///
/// Throws [PosException] when the file is not an image or cannot be made
/// small enough.
Future<Uint8List> shrinkProductPhoto(
  Uint8List source, {
  int maxSide = maxProductPhotoSide,
  int maxBytes = maxProductPhotoBytes,
}) async {
  if (source.length > maxProductPhotoInputBytes) throw productPhotoFileTooLarge;
  final size = imageHeaderSize(source) ?? await _probeSize(source);
  final width = size.width;
  final height = size.height;
  if (width * height > maxProductPhotoInputPixels) {
    throw const PosException(
      'PRODUCT_IMAGE_TOO_MANY_PIXELS',
      'รูปละเอียดเกิน 24 ล้านพิกเซล กรุณาเลือกรูปอื่น', // agent ร่าง
    );
  }
  final longSide = math.max(width, height);
  var side = math.min(maxSide, longSide);
  while (true) {
    final scale = side / longSide;
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    final ui.Image decoded;
    try {
      final codec = await ui.instantiateImageCodec(
        source,
        targetWidth: w,
        targetHeight: h,
      );
      decoded = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (_) {
      throw _unreadable; // a valid-looking header over a broken body
    }
    // Flatten onto white: JPEG keeps no alpha channel.
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      )
      ..drawImage(decoded, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final flat = await picture.toImage(w, h);
    picture.dispose();
    decoded.dispose();
    final rgba = (await flat.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    flat.dispose();
    final out = await compute(_encodeJpeg, (
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      w,
      h,
    ));
    if (out.length <= maxBytes) return out;
    final next = (side * 0.8).floor();
    if (next < 400) break;
    side = next;
  }
  throw const PosException(
    'PRODUCT_IMAGE_TOO_LARGE',
    'รูปใหญ่เกิน 3 MB', // agent ร่าง (same as the server's PRODUCT_IMAGE_TOO_LARGE)
  );
}

const _unreadable = PosException(
  'IMAGE_UNREADABLE',
  'อ่านรูปไม่ได้ กรุณาเลือกไฟล์รูป PNG หรือ JPG', // เจ้าของรับรอง 2026-10-10 (QR)
);

/// The old full decode, only for a format [imageHeaderSize] does not read.
Future<ImageSize> _probeSize(Uint8List source) async {
  try {
    final probe = await ui.instantiateImageCodec(source);
    final frame = await probe.getNextFrame();
    final size = (width: frame.image.width, height: frame.image.height);
    frame.image.dispose();
    probe.dispose();
    return size;
  } catch (_) {
    throw _unreadable;
  }
}

/// RGBA pixels → JPEG at [productPhotoQuality]. Top-level so [compute] can
/// run it in another isolate.
Uint8List _encodeJpeg((Uint8List, int, int) pixels) {
  final (rgba, w, h) = pixels;
  return img.encodeJpg(
    img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
    ),
    quality: productPhotoQuality,
  );
}
