// Non-web: nothing to prepare, the native plugin handles the camera.
// The web version is barcode_scan_web.dart.

/// Returns null when scanning can start, else a Thai reason to show instead
/// of the camera (checked BEFORE the browser asks for camera permission).
Future<String?> prepareWebScanner() async => null;
