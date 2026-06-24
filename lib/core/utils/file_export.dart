// Cross-platform text-file export.
//
// On native (Android/iOS/desktop) the file is written to the app documents
// directory and the saved absolute path is returned. On the web a browser
// download is triggered and `null` is returned (there is no filesystem path).
//
// The implementation is chosen by conditional import so the web build never
// pulls in `dart:io` and the native build never pulls in `package:web` — this is
// what lets backup / CSV export work on the web target (previously dart:io-only,
// so it threw and the web shop had no data-safety path at all).
//
//   final path = await exportTextFile(filename: 'backup.json', content: json);
//   if (path != null) { /* native: show the saved path */ }
//   else              { /* web: browser handled the download */ }
export 'file_export_io.dart'
    if (dart.library.js_interop) 'file_export_web.dart';
