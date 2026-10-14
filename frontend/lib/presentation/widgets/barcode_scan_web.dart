// Web setup for the camera scanner, run BEFORE the camera is requested.
//
// 1. Native BarcodeDetector where the browser has it (Chrome on Android/macOS,
//    Safari 17+). Nothing is loaded.
// 2. Otherwise (Windows desktop Chrome/Edge, Firefox) the zxing-wasm decoder
//    vendored under web/zxing/ (see VERSION.txt) is loaded from OUR origin and
//    its .wasm is redirected there too — no CDN is ever contacted. The script
//    gets mobile_scanner's expected id, so the package reuses it instead of
//    fetching its own jsdelivr copy.
// 3. If neither can work, return a Thai reason so the dialog shows it without
//    asking for camera permission.
//
// Thai strings are `agent ร่าง` (owner to ratify).

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web/web.dart' as web;

import 'camera_access_web.dart';

// mobile_scanner's id for its zxing-wasm script tag: if a tag with this id
// exists it does not load its own.
const _scriptId = 'mobile-scanner-zxing-wasm';

/// Returns null when scanning can start, else a Thai reason.
Future<String?> prepareWebScanner() async {
  final blocked = cameraBlockedReason();
  if (blocked != null) return blocked;
  if (await _nativeDetectorWorks()) {
    MobileScannerPlatform.instance.setWebBarcodeReader(
      WebBarcodeReader.barcodeDetector,
    );
    return null;
  }
  if (!globalContext.has('WebAssembly')) {
    // agent ร่าง
    return 'เบราว์เซอร์นี้สแกนบาร์โค้ดไม่ได้';
  }
  if (!await _loadLocalZxing()) {
    // agent ร่าง
    return 'โหลดตัวอ่านบาร์โค้ดไม่สำเร็จ';
  }
  MobileScannerPlatform.instance.setWebBarcodeReader(
    WebBarcodeReader.zxingWasm,
  );
  return null;
}

Future<bool> _nativeDetectorWorks() async {
  if (!globalContext.has('BarcodeDetector')) return false;
  try {
    final detector = globalContext.getProperty<JSObject>(
      'BarcodeDetector'.toJS,
    );
    final formats = await detector
        .callMethod<JSPromise<JSArray<JSAny?>>>('getSupportedFormats'.toJS)
        .toDart;
    return formats.length > 0;
  } catch (_) {
    return false;
  }
}

String _local(String path) =>
    Uri.parse(web.document.baseURI).resolve(path).toString();

Future<bool> _loadLocalZxing() async {
  if (!globalContext.has('ZXingWASM')) {
    final done = Completer<bool>();
    final script = web.HTMLScriptElement()
      ..id = _scriptId
      ..src = _local('zxing/zxing_reader.js')
      ..onload = ((JSAny _) {
        if (!done.isCompleted) done.complete(true);
      }).toJS
      ..onerror = ((JSAny _) {
        if (!done.isCompleted) done.complete(false);
      }).toJS;
    web.document.head!.appendChild(script);
    if (!await done.future) {
      script.remove(); // let a later attempt retry
      return false;
    }
  }
  try {
    final wasmUrl = _local('zxing/zxing_reader.wasm');
    final overrides = JSObject()
      ..setProperty(
        'locateFile'.toJS,
        ((JSString file, JSString prefix) {
          final f = file.toDart;
          return (f.endsWith('.wasm') ? wasmUrl : prefix.toDart + f).toJS;
        }).toJS,
      );
    globalContext
        .getProperty<JSObject>('ZXingWASM'.toJS)
        .callMethod<JSAny?>('setZXingModuleOverrides'.toJS, overrides);
    return true;
  } catch (_) {
    return false;
  }
}
