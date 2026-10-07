// OwnerImportRepository — Settings → 📥 กู้คืนข้อมูล on the API build.
//
// The shop owner sends a backup file to `POST /api/v1/backup/import` (the
// server's own pre-flight decides: empty shop only, a file exported from this
// server only — 02_API_SCREENS.md §4), then polls `GET /api/v1/backup/import/:jobId`
// until the worker has finished. On success the reconnect pull runs
// (`triggerEntityPull`: products / customers / mechanics / settings), so the
// imported rows reach this device's cache — the import re-stamps every pulled
// row's `updated_at`, so an incremental pull sees all of them.
//
// No `Idempotency-Key`: the route claims none (a claim would hold a second pool
// connection next to the import's own). A resent request is refused by the
// server instead — 409 while the first job runs, 409 once it has written.
//
// Every refusal leaves as a [PosException] (CLAUDE.md: an ApiException must
// never reach a screen).

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';

class OwnerImportRepository {
  OwnerImportRepository(
    this._api, {
    this.onImported,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPolls = 90,
  });

  final ApiClient _api;

  /// Runs after a successful import — the reconnect pull.
  final Future<void> Function()? onImported;

  /// Poll cadence and cap: 90 × 2 s = 3 min, past the server's measured worst
  /// case (≈100 s for a 10 MiB file with two retries, tenant-import.service.ts).
  final Duration pollInterval;
  final int maxPolls;

  // 02_API_SCREENS.md §8.1.1 — agent ร่าง, awaiting the owner.
  static const String notEmptyMessage =
      'นำเข้าไม่ได้ — ร้านนี้มีข้อมูลการขายหรือเอกสารแล้ว หรือมีการนำเข้าที่ยังทำไม่เสร็จ';
  static const String notFromThisServerMessage =
      'ไฟล์นี้ไม่ได้ส่งออกจากระบบนี้ (ไฟล์จากโปรแกรมเดิม) — นำเข้าไม่ได้';
  static const String rejectedFileMessage =
      'ไฟล์นี้นำเข้าไม่ได้ — ข้อมูลในไฟล์ไม่ผ่านการตรวจสอบ';
  static const String tooLargeMessage =
      'ไฟล์ใหญ่เกินไป (เกิน 10 MB) — นำเข้าไม่ได้';
  static const String needsEnrolledDeviceMessage =
      'ต้องใช้เครื่องที่ลงทะเบียนแล้วจึงจะนำเข้าข้อมูลได้';
  static const String failedMessage = 'นำเข้าข้อมูลไม่สำเร็จ';
  static const String stillRunningMessage =
      'การนำเข้ายังไม่เสร็จ — กรุณาตรวจสอบอีกครั้งในภายหลัง';

  /// Sends [snapshot] (a parsed backup file) and waits for the server's job.
  /// Returns once the import has succeeded and the pull has run.
  Future<void> importBackup(Map<String, dynamic> snapshot) async {
    final jobId = await _call(() async {
      final res = await _api.post('/api/v1/backup/import', body: snapshot);
      return (res as Map)['jobId'] as String;
    });

    for (var i = 0; i < maxPolls; i++) {
      await Future<void>.delayed(pollInterval);
      final job = await _call(() async =>
          (await _api.get('/api/v1/backup/import/$jobId') as Map)
              .cast<String, dynamic>());
      switch (job['status']) {
        case 'succeeded':
          await onImported?.call();
          return;
        case 'failed':
          final error = job['error'];
          throw PosException(
            'IMPORT_FAILED',
            error is String && error.isNotEmpty
                ? '$failedMessage: $error'
                : failedMessage,
          );
      }
    }
    throw const PosException('IMPORT_STILL_RUNNING', stillRunningMessage);
  }

  Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on ApiException catch (e) {
      throw _refusal(e);
    }
  }

  /// The import's own refusals in the owner's words; everything else reads as
  /// on any other screen ([posExceptionFromApi]).
  static PosException _refusal(ApiException e) {
    final detail = e.serverMessage?.trim();
    final text = switch ((e.statusCode, e.code)) {
      (409, 'CONFLICT') => notEmptyMessage,
      (400, 'INVALID_ID') => notFromThisServerMessage,
      (400, 'BAD_REQUEST') => detail == null || detail.isEmpty
          ? rejectedFileMessage
          : '$rejectedFileMessage: $detail',
      (413, _) => tooLargeMessage,
      (403, 'DEVICE_ROLE_FORBIDDEN') => needsEnrolledDeviceMessage,
      _ => null,
    };
    return text == null
        ? posExceptionFromApi(e)
        : PosException(e.code, text, e.details);
  }
}
