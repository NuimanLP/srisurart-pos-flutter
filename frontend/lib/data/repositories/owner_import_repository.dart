// OwnerImportRepository — Settings → 📥 กู้คืนข้อมูล on the API build.
//
// The shop owner replaces the shop's data on the server with a backup file:
// `POST /api/v1/backup/import?mode=replace&confirmShopName=…` (the typed shop
// name is the server's second check), then polls `GET /api/v1/backup/import/:jobId`
// until the worker is done. The server copies the old data to a file, deletes
// it and writes the file's, in one transaction (02_API_SCREENS.md §3.10).
//
// This device then drops every cached row of the old data
// (`AppDatabase.resetAfterServerImport`), pulls products / customers /
// mechanics / settings from zero and re-reads its document counters. Other
// devices keep their old cache until they refresh — the screen says so.
//
// Refused before anything is sent while this device has unsent work (outbox
// ops, queued credit payments, parked bills): the reset would destroy it, and
// on the server it would land in the replaced shop.
//
// No `Idempotency-Key`: the route claims none (a claim would hold a second pool
// connection next to the import's own). The client names the job (`jobId`), so a
// lost reply is followed by polling that job, never by sending the file twice.
//
// Every refusal leaves as a Thai [PosException] (CLAUDE.md: an ApiException must
// never reach a screen); the server's English detail stays in its logs and in
// `import_jobs.error`.

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../services/tenant_cache_guard.dart';
import 'api/api_wire.dart';

/// What a successful import left behind on this device.
class OwnerImportOutcome {
  const OwnerImportOutcome({required this.refreshed});

  /// False when the pull after the import failed: the import itself committed,
  /// but this device still shows the old data until the page is reloaded.
  final bool refreshed;
}

class OwnerImportRepository {
  OwnerImportRepository(
    this._api,
    this._db, {
    this.pull,
    this.seedDocCounters,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPolls = 90,
    this.uploadTimeout = const Duration(minutes: 3),
  });

  final ApiClient _api;
  final AppDatabase _db;

  /// The reconnect pull (`triggerEntityPull`): settings, products, customers, mechanics.
  final Future<void> Function()? pull;

  /// `DocCounterSeeder.seed` — never throws.
  final Future<void> Function()? seedDocCounters;

  /// Poll cadence and cap: 90 × 2 s = 3 min, past the server's measured worst
  /// case (≈100 s for a 10 MiB file with two retries, tenant-import.service.ts).
  final Duration pollInterval;
  final int maxPolls;

  /// The upload itself: up to 10 MiB, which `ApiClient.defaultWriteTimeout` (40 s) does not cover.
  final Duration uploadTimeout;

  // 02_API_SCREENS.md §8.1.1 — agent ร่าง, awaiting the owner.
  static const String unsentWorkMessage =
      'นำเข้าข้อมูลไม่ได้ เพราะเครื่องนี้ยังมีงานค้างอยู่ (รายการค้างส่ง ชำระเครดิตค้างส่ง '
      'หรือบิลพัก) กรุณาส่งหรือยกเลิกรายการให้เรียบร้อยก่อน';
  static const String notEmptyMessage =
      'นำเข้าไม่ได้ — ร้านนี้มีข้อมูลการขายหรือเอกสารแล้ว';
  static const String inProgressMessage =
      'มีการนำเข้าข้อมูลที่ยังทำไม่เสร็จ กรุณารอสักครู่แล้วลองใหม่';
  static const String shopNameMismatchMessage =
      'ชื่อร้านที่พิมพ์ไม่ตรงกับชื่อร้านในระบบ — ยังไม่ได้นำเข้าข้อมูล';
  static const String notFromThisServerMessage =
      'ไฟล์นี้ไม่ได้ส่งออกจากระบบนี้ (ไฟล์จากโปรแกรมเดิม) — นำเข้าไม่ได้';
  static const String rejectedFileMessage =
      'ไฟล์นี้นำเข้าไม่ได้ — ข้อมูลในไฟล์ไม่ผ่านการตรวจสอบ';
  static const String tooLargeMessage =
      'ไฟล์ใหญ่เกินไป (เกิน 10 MB) — นำเข้าไม่ได้';
  static const String needsEnrolledDeviceMessage =
      'ต้องใช้เครื่องที่ลงทะเบียนแล้วจึงจะนำเข้าข้อมูลได้';
  static const String failedMessage =
      'นำเข้าข้อมูลไม่สำเร็จ ข้อมูลเดิมของร้านยังอยู่ครบ';
  static const String stillRunningMessage =
      'การนำเข้ายังไม่เสร็จ — กรุณาตรวจสอบอีกครั้งในภายหลัง';
  static const String uploadLostMessage =
      'ส่งไฟล์ไม่สำเร็จ — ระบบไม่ได้รับไฟล์ ข้อมูลเดิมของร้านยังอยู่ครบ กรุณาลองใหม่';

  /// Sends [snapshot] (a parsed backup file) to replace this shop's data and
  /// waits for the server's job. [confirmShopName] is what the owner typed.
  Future<OwnerImportOutcome> importBackup(
    Map<String, dynamic> snapshot, {
    required String confirmShopName,
  }) async {
    final guard = TenantCacheGuard(_db);
    if (await guard.hasLocalWork()) {
      throw const PosException('IMPORT_UNSENT_WORK', unsentWorkMessage);
    }

    // The job is named here, so a lost reply can still be followed by polling it.
    final jobId = newUuid();
    final path = Uri(
      path: '/api/v1/backup/import',
      queryParameters: {
        'mode': 'replace',
        'confirmShopName': confirmShopName,
        'jobId': jobId,
      },
    ).toString();
    var accepted = true;
    try {
      await _api.post(path, body: snapshot, timeout: uploadTimeout);
    } on ApiException catch (e) {
      // Only a 4xx is a verdict; after a 5xx / 429 the job may exist (08 §5).
      if (isVerdict(e)) throw _refusal(e);
      accepted = false;
    } catch (_) {
      // No reply (timeout / dropped connection): the server may have taken the
      // file anyway — find out by polling, never by sending it again.
      accepted = false;
    }

    var seen = accepted;
    for (var i = 0; i < maxPolls; i++) {
      await Future<void>.delayed(pollInterval);
      final Map<String, dynamic> job;
      try {
        job = (await _api.get('/api/v1/backup/import/$jobId') as Map)
            .cast<String, dynamic>();
      } on ApiException catch (e) {
        // Not there (yet) after a lost reply: the server may still be checking the file.
        if (!seen && e.statusCode == 404) continue;
        // A 5xx / 429 is a bad moment, not an answer: the job keeps running.
        if (isVerdict(e)) throw _refusal(e);
        continue;
      } catch (_) {
        continue; // transport hiccup — keep polling within the cap
      }
      seen = true;
      switch (job['status']) {
        case 'succeeded':
          return OwnerImportOutcome(refreshed: await _refreshLocal(guard));
        case 'failed':
          throw const PosException('IMPORT_FAILED', failedMessage);
      }
    }
    throw seen
        ? const PosException('IMPORT_STILL_RUNNING', stillRunningMessage)
        : const PosException('IMPORT_UPLOAD_LOST', uploadLostMessage);
  }

  /// The import committed; whatever happens here must not read as a failure.
  Future<bool> _refreshLocal(TenantCacheGuard guard) async {
    try {
      // Work queued while the job ran would be destroyed by the reset: keep
      // the cache and let a reload sort it out instead.
      if (await guard.hasLocalWork()) return false;
      await _db.resetAfterServerImport();
      await pull?.call();
      await seedDocCounters?.call();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The import's own refusals in the owner's words; everything else reads as
  /// on any other screen ([posExceptionFromApi]).
  static PosException _refusal(ApiException e) {
    final text = switch ((e.statusCode, e.code)) {
      (409, 'TENANT_NOT_EMPTY') => notEmptyMessage,
      (409, 'IMPORT_IN_PROGRESS') => inProgressMessage,
      (400, 'CONFIRM_SHOP_NAME_MISMATCH') => shopNameMismatchMessage,
      (400, 'INVALID_ID') => notFromThisServerMessage,
      (400, _) => rejectedFileMessage,
      (413, _) => tooLargeMessage,
      (403, 'DEVICE_ROLE_FORBIDDEN') => needsEnrolledDeviceMessage,
      _ => null,
    };
    return text == null
        ? posExceptionFromApi(e)
        : PosException(e.code, text, e.details);
  }
}
