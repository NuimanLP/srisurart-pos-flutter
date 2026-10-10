// Native (dart:io) implementation of [exportTextFile] — see file_export.dart.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Writes [content] as UTF-8 to a file named [filename] in the application
/// documents directory and returns the absolute path.
Future<String?> exportTextFile({
  required String filename,
  required String content,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, filename));
  await file.writeAsString(content, encoding: utf8);
  return file.path;
}

/// Writes [bytes] (a backup `.zip`) to [filename] in the application documents
/// directory and returns the absolute path. [mimeType] is for the web build.
Future<String?> exportBytesFile({
  required String filename,
  required List<int> bytes,
  required String mimeType,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, filename));
  await file.writeAsBytes(bytes);
  return file.path;
}
