// Web (package:web) implementation of [exportTextFile] — see file_export.dart.
//
// Builds a Blob from the UTF-8 bytes and clicks a hidden <a download> anchor,
// the same mechanism the original JS app used (URL.createObjectURL + anchor),
// so a web shop can back up / export again.

import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Triggers a browser download of [content] (UTF-8) as [filename]. Returns null
/// because there is no server/filesystem path on the web.
Future<String?> exportTextFile({
  required String filename,
  required String content,
}) async {
  final bytes = utf8.encode(content);
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return null;
}
