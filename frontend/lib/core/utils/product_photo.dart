// Shrinks a picked product photo before it is uploaded (contract §5): long side
// ≤ [maxProductPhotoSide] px, JPEG at quality [productPhotoQuality], so the raw
// `PUT /products/:id/image` stays well under the server's 3 MB limit.
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

const maxProductPhotoSide = 1600;
const productPhotoQuality = 85;

/// Below the server's 3 MB (3 × 1024 × 1024) with room to spare.
const maxProductPhotoBytes = 2900000;

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
  final int width;
  final int height;
  try {
    final probe = await ui.instantiateImageCodec(source);
    final frame = await probe.getNextFrame();
    width = frame.image.width;
    height = frame.image.height;
    frame.image.dispose();
    probe.dispose();
  } catch (_) {
    throw const PosException(
      'IMAGE_UNREADABLE',
      'อ่านรูปไม่ได้ กรุณาเลือกไฟล์รูป PNG หรือ JPG', // เจ้าของรับรอง 2026-10-10 (QR)
    );
  }
  final longSide = math.max(width, height);
  var side = math.min(maxSide, longSide);
  while (true) {
    final scale = side / longSide;
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    final codec = await ui.instantiateImageCodec(
      source,
      targetWidth: w,
      targetHeight: h,
    );
    final decoded = (await codec.getNextFrame()).image;
    codec.dispose();
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
