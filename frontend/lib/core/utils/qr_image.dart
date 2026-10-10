// Shrinks an uploaded QR image before it is stored (contract §5): at most
// [maxQrImageSide] px on the long side, re-encoded as PNG, at most 300 KB.
//
// Uses the engine's own decoder (`ui.instantiateImageCodec` with a target
// size, then `toByteData(png)`) — no image package. PNG because a QR is two
// flat colours, which PNG keeps sharp and small; JPEG would blur the modules.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../errors/pos_exception.dart';

const maxQrImageSide = 600;

/// The encoded-size limit — the stored image IS this PNG, so it is the
/// decoded-image limit too (`maxQrImageBytes`, 300,000 bytes).
const maxQrImageEncodedBytes = 300000;

/// [source] (PNG / JPEG / anything the engine decodes) → PNG bytes, long side
/// ≤ [maxSide], length ≤ [maxBytes]. A picture still too large at the long
/// side shrinks in 20 % steps down to 200 px before it is refused.
///
/// Throws [PosException] when the file is not an image or cannot be made
/// small enough.
Future<Uint8List> shrinkQrImage(
  Uint8List source, {
  int maxSide = maxQrImageSide,
  int maxBytes = maxQrImageEncodedBytes,
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
      'อ่านรูปไม่ได้ กรุณาเลือกไฟล์รูป PNG หรือ JPG', // เจ้าของรับรอง 2026-10-10
    );
  }
  final longSide = math.max(width, height);
  var side = math.min(maxSide, longSide);
  while (true) {
    final scale = side / longSide;
    final codec = await ui.instantiateImageCodec(
      source,
      targetWidth: math.max(1, (width * scale).round()),
      targetHeight: math.max(1, (height * scale).round()),
    );
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    final out = data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (out.length <= maxBytes) return out;
    final next = (side * 0.8).floor();
    if (next < 200) break;
    side = next;
  }
  throw const PosException(
    'IMAGE_TOO_LARGE',
    'รูป QR ใหญ่เกิน 300 KB กรุณาเลือกรูปอื่น', // เจ้าของรับรอง 2026-10-10
  );
}
