// Can this page use a camera at all? Shared by the barcode scanner and the
// sale-photo camera, and checked BEFORE either asks for camera permission.
// Non-web: always yes (the native plugin reports a missing camera itself).
// The web version is camera_access_web.dart.

/// Null when the camera API is reachable, else a Thai reason to show instead.
String? cameraBlockedReason() => null;
