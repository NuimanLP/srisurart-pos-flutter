// The size of an encoded picture, read from its header only — no pixel is
// decoded (iPad image upload, 2026-11-28). shrinkProductPhoto uses it to refuse
// a picture over the server's 24 MP before any decode, and to pick the target
// size of its single downscaled decode. On the web the engine has no cheap
// "size only" call: a probe decode there is a full-size decode of a 12–48 MP
// photo on the main thread.
//
// JPEG (SOF + the EXIF orientation, so the size is the displayed one, as the
// engine decodes it), PNG, GIF and WebP. Anything else → null.

import 'dart:typed_data';

typedef ImageSize = ({int width, int height});

ImageSize? imageHeaderSize(Uint8List b) {
  try {
    if (b.length >= 24 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return _positive(_u32be(b, 16), _u32be(b, 20)); // IHDR
    }
    if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return _positive(_u16le(b, 6), _u16le(b, 8)); // GIF logical screen
    }
    if (b.length >= 16 && _ascii(b, 0, 'RIFF') && _ascii(b, 8, 'WEBP')) {
      return _webp(b);
    }
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) return _jpeg(b);
  } on RangeError {
    // Truncated header.
  }
  return null;
}

ImageSize? _webp(Uint8List b) {
  if (_ascii(b, 12, 'VP8 ')) {
    return _positive(_u16le(b, 26) & 0x3FFF, _u16le(b, 28) & 0x3FFF);
  }
  if (_ascii(b, 12, 'VP8L')) {
    final bits = b[21] | b[22] << 8 | b[23] << 16 | b[24] << 24;
    return _positive((bits & 0x3FFF) + 1, (bits >> 14 & 0x3FFF) + 1);
  }
  if (_ascii(b, 12, 'VP8X')) {
    return _positive(_u24le(b, 24) + 1, _u24le(b, 27) + 1);
  }
  return null;
}

ImageSize? _jpeg(Uint8List b) {
  var orientation = 1;
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2; // no length
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null; // EOI / SOS before a SOF
    final len = _u16be(b, i + 2);
    if (len < 2) return null;
    final seg = i + 4;
    if (marker == 0xE1 && len >= 8 && _ascii(b, seg, 'Exif')) {
      orientation = _exifOrientation(b, seg + 6, i + 2 + len) ?? orientation;
    }
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG
        marker != 0xCC; // DAC
    if (isSof) {
      final h = _u16be(b, seg + 1);
      final w = _u16be(b, seg + 3);
      // 5–8 = rotated a quarter turn: the displayed picture is w↔h.
      return orientation >= 5 && orientation <= 8 ? _positive(h, w) : _positive(w, h);
    }
    i += 2 + len;
  }
  return null;
}

/// The Orientation tag (0x0112) of IFD0 in the TIFF block at [t], or null.
/// Nothing at or past [end] (the APP1 segment's end) is read.
int? _exifOrientation(Uint8List b, int t, int end) {
  if (t + 8 > end) return null;
  final little = b[t] == 0x49 && b[t + 1] == 0x49;
  if (!little && !(b[t] == 0x4D && b[t + 1] == 0x4D)) return null;
  int u16(int o) => little ? _u16le(b, t + o) : _u16be(b, t + o);
  int u32(int o) => little
      ? b[t + o] | b[t + o + 1] << 8 | b[t + o + 2] << 16 | b[t + o + 3] << 24
      : _u32be(b, t + o);
  final ifd = u32(4);
  if (t + ifd + 2 > end) return null;
  final count = u16(ifd);
  if (t + ifd + 2 + 12 * count > end) return null; // runs past its segment
  for (var k = 0; k < count; k++) {
    final e = ifd + 2 + 12 * k;
    if (u16(e) == 0x0112) return u16(e + 8);
  }
  return null;
}

ImageSize? _positive(int w, int h) => w > 0 && h > 0 ? (width: w, height: h) : null;

bool _ascii(Uint8List b, int at, String s) {
  if (at + s.length > b.length) return false;
  for (var k = 0; k < s.length; k++) {
    if (b[at + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}

int _u16be(Uint8List b, int i) => b[i] << 8 | b[i + 1];
int _u16le(Uint8List b, int i) => b[i] | b[i + 1] << 8;
int _u24le(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16;
int _u32be(Uint8List b, int i) =>
    b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
