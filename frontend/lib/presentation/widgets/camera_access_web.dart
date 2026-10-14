// Web: `navigator.mediaDevices` exists only in a secure context (HTTPS or
// localhost). Without it no camera can open, and plugins that assume it is
// there throw a raw TypeError — so callers check this first.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Null when the camera API is reachable, else a Thai reason to show instead.
String? cameraBlockedReason() {
  final nav = web.window.navigator as JSObject;
  if (nav.getProperty<JSAny?>('mediaDevices'.toJS) == null) {
    // agent ร่าง — camera API needs HTTPS (or localhost).
    return 'เบราว์เซอร์นี้ใช้กล้องไม่ได้ (ต้องเปิดผ่าน HTTPS)';
  }
  return null;
}
