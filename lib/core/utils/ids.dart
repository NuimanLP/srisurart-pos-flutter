// Port of _newId / _docNo from pos/db.js — UUID-backed, collision-proof.
//
// JS source:
//   let _idCounter = 0;
//   _uuidShort = () => crypto.randomUUID().slice(0, 8);
//   _newId(prefix) = `${prefix}${Date.now().toString(36)}_${_uuidShort()}_${(++_idCounter).toString(36)}`
//   _docNo(prefix) = prefix + Date.now().toString().slice(-8) + _uuidShort().slice(0,4).toUpperCase()
//
// NEVER inline DateTime.now() for a document number — always use these helpers.

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Top-level mutable counter, mirrors JS `_idCounter`.
int _idCounter = 0;

/// First 8 chars of a v4 UUID with dashes removed (JS crypto.randomUUID().slice(0,8)
/// returns 8 chars which always falls before the first dash, so dash removal is a
/// safe no-op for the first 8 — we strip dashes to be exact regardless).
String _uuidShort() => _uuid.v4().replaceAll('-', '').substring(0, 8);

/// `prefix + base36(nowMs) + "_" + uuidShort + "_" + base36(++counter)`
String newId(String prefix) {
  final ms = DateTime.now().millisecondsSinceEpoch;
  return '$prefix${ms.toRadixString(36)}_${_uuidShort()}_${(++_idCounter).toRadixString(36)}';
}

/// `prefix + last-8-digits-of-nowMs + uppercased first-4 of uuidShort`.
/// JS uses `Date.now().toString().slice(-8)` — the last 8 characters of the
/// decimal millisecond string (which is `nowMs % 100000000`, but kept as the
/// raw substring so leading-zero behaviour matches JS exactly).
String docNo(String prefix) {
  final msStr = DateTime.now().millisecondsSinceEpoch.toString();
  final tail = msStr.length <= 8 ? msStr : msStr.substring(msStr.length - 8);
  final suffix = _uuidShort().substring(0, 4).toUpperCase();
  return '$prefix$tail$suffix';
}
