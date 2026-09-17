// DocCounterSeeder — seeds the local document-number counter from the server
// (#188, ADR-0007 "ช่องพังที่ต้องปิดก่อนเฟส 2" item 1).
//
// In phase 2 the `pos` device issues RC/CN itself from `doc_counters`, which
// lives in IndexedDB and can come back from a stale restore. On app open and on
// login this pulls `GET /doc-counters` — the server's high-water mark for THIS
// device (the server takes the device from the token) — and sets
// `local = max(local, server)` per row, then records the period as seeded.
// Rows are keyed by the server's device id, so a re-enrolled browser never
// applies another device's counters or seed record to the new one.
//
// Phase 1 issues nothing from the counter; this only fills it.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../db/database.dart';

class DocCounterSeeder {
  DocCounterSeeder({required this.db, required this.apiClient});

  final AppDatabase db;
  final ApiClient apiClient;

  /// Returns whether the local counter was seeded.
  ///
  /// 🔴 Never throws: seeding is a safety net, and a failure here must not block
  /// app start or login. Any failure — no network, a refusal, a malformed reply —
  /// leaves every local row exactly as it was: the reply is parsed in full before
  /// the first write, and the writes share one local transaction (nothing is held
  /// open across the wire).
  Future<bool> seed() async {
    try {
      final res = await apiClient.get('/api/v1/doc-counters');
      final seed = _parse(res);
      await db.transaction(() async {
        for (final c in seed.counters) {
          await db.customInsert(
            'INSERT INTO doc_counters '
            '(device_id, device_no, doc_type, period, last_no) '
            'VALUES (?, ?, ?, ?, ?) '
            'ON CONFLICT (device_id, doc_type, period) '
            'DO UPDATE SET last_no = MAX(last_no, excluded.last_no)',
            variables: [
              Variable.withString(seed.deviceId),
              Variable.withInt(seed.deviceNo),
              Variable.withString(c.docType),
              Variable.withString(c.period),
              Variable.withInt(c.lastNo),
            ],
            updates: {db.docCounters},
          );
        }
        await db
            .into(db.docCounterSeeds)
            .insertOnConflictUpdate(
              DocCounterSeedsCompanion.insert(
                deviceId: seed.deviceId,
                period: seed.period,
                seededAt: DateTime.now(),
              ),
            );
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static _Seed _parse(Object? res) {
    if (res is! Map) throw const FormatException('doc-counters: not an object');
    final deviceId = res['deviceId'];
    final deviceNo = res['deviceNo'];
    final period = res['period'];
    final counters = res['counters'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceNo is! int ||
        period is! String ||
        counters is! List) {
      throw const FormatException('doc-counters: missing fields');
    }
    return _Seed(deviceId, deviceNo, period, [
      for (final c in counters)
        if (c is Map &&
            c['docType'] is String &&
            c['period'] is String &&
            c['lastNo'] is int)
          (
            docType: c['docType'] as String,
            period: c['period'] as String,
            lastNo: c['lastNo'] as int,
          )
        else
          throw const FormatException('doc-counters: malformed counter'),
    ]);
  }
}

class _Seed {
  _Seed(this.deviceId, this.deviceNo, this.period, this.counters);

  final String deviceId;
  final int deviceNo;
  final String period;
  final List<({String docType, String period, int lastNo})> counters;
}
