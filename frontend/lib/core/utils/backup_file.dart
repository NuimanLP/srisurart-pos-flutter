// Backup-file parsing for Settings → 💾 สำรอง/กู้คืน → restore.
//
// Turns the raw bytes of a picked `.json` backup (the file
// SnapshotRepository.exportSnapshot produces) into the map that
// SnapshotRepository.importLegacyBackup takes, applying the same checks as
// handleFileSelect in SettingsScreen.jsx. Throws on anything unusable; the
// caller shows the message after 'ไม่สามารถอ่านไฟล์ได้: '.

import 'dart:convert';
import 'dart:typed_data';

Map<String, dynamic> parseBackupFile(Uint8List bytes) {
  var raw = utf8.decode(bytes); // strict: malformed UTF-8 throws
  // A UTF-8 BOM (e.g. a file re-saved by Notepad) is not valid JSON.
  if (raw.startsWith('﻿')) raw = raw.substring(1);
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw Exception('ไฟล์ว่างเปล่า — ไม่มีข้อมูลสินค้าหรือยอดขาย');
  }
  final data = decoded.cast<String, dynamic>();
  final meta = data['__meta'];
  if (meta == null || meta is! Map) {
    throw Exception('ไม่พบข้อมูล meta — ไฟล์ไม่ถูกต้อง');
  }
  final version = meta['version'];
  if (version is! num) {
    throw Exception('ไม่พบ version ในไฟล์');
  }
  if (version > 2) {
    throw Exception(
      'ไฟล์เวอร์ชัน $version ใหม่กว่าที่ระบบรองรับ — กรุณาอัพเดทระบบ',
    );
  }
  if (data['sa_products'] == null && data['sa_sales'] == null) {
    throw Exception('ไฟล์ว่างเปล่า — ไม่มีข้อมูลสินค้าหรือยอดขาย');
  }
  return data;
}
