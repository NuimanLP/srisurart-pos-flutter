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
// mechanics / settings from zero, copies the shop's bills and credit notes down
// once (`GET /sales`, `GET /returns` — nothing else ever pulls history) and
// re-reads its document counters. Other devices keep their old cache.
//
// Ghost rows: from the moment the file is sent until that refresh succeeded,
// app_meta [pendingImportKey] holds the job id. If the app is closed, the
// network drops or the wait runs out in between, [resumePendingImport] (app
// open / login) finishes the refresh later instead of leaving the old data on
// this device for good.
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

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../services/tenant_cache_guard.dart';
import 'api/api_wire.dart';

/// What a successful import left behind on this device.
class OwnerImportOutcome {
  const OwnerImportOutcome({required this.refreshed});

  /// False when the refresh after the import failed: the import itself
  /// committed, and [OwnerImportRepository.resumePendingImport] retries the
  /// refresh at the next app open / login.
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

  /// The reconnect pull (`triggerEntityPull`): settings, suppliers, products, customers, mechanics.
  final Future<void> Function()? pull;

  /// `DocCounterSeeder.seed` — never throws.
  final Future<void> Function()? seedDocCounters;

  /// Poll cadence and cap: 90 × 2 s = 3 min, past the server's measured worst
  /// case (≈100 s for a 10 MiB file with two retries, tenant-import.service.ts).
  final Duration pollInterval;
  final int maxPolls;

  /// The upload itself: up to 10 MiB, which `ApiClient.defaultWriteTimeout` (40 s) does not cover.
  final Duration uploadTimeout;

  /// app_meta: the import job whose outcome this device has not applied yet.
  static const String pendingImportKey = 'pending_server_import';

  /// `GET /sales` / `GET /returns` page size — the server's `MAX_LIMIT`.
  static const int historyPageSize = 200;

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
      'การนำเข้ายังไม่เสร็จ — เครื่องนี้จะตรวจผลอีกครั้งเมื่อเปิดแอปหรือเข้าสู่ระบบครั้งถัดไป';
  static const String uploadLostMessage =
      'ไม่ได้รับคำตอบจากระบบ — ยังไม่ทราบว่าระบบได้รับไฟล์หรือไม่ '
      'เครื่องนี้จะตรวจผลอีกครั้งเมื่อเปิดแอปหรือเข้าสู่ระบบครั้งถัดไป กรุณาอย่าส่งไฟล์ซ้ำทันที';

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
    await _setPending(jobId);
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
      if (isVerdict(e)) {
        await _clearPending(); // refused before any job was created
        throw _refusal(e);
      }
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
        job = await _job(jobId);
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
          return OwnerImportOutcome(refreshed: await _applySucceeded(guard));
        case 'failed':
          await _clearPending();
          throw const PosException('IMPORT_FAILED', failedMessage);
      }
    }
    // The marker stays: the next app open / login looks at the job again.
    throw seen
        ? const PosException('IMPORT_STILL_RUNNING', stillRunningMessage)
        : const PosException('IMPORT_UPLOAD_LOST', uploadLostMessage);
  }

  /// App open / login (`resumeImportOnSignIn`): applies the outcome of an
  /// import this device started but did not finish refreshing for. Never throws.
  ///
  /// - succeeded → reset, pull, history, counters; marker cleared once all of it worked.
  /// - failed, or no such job (the upload never arrived) → marker cleared, cache kept.
  /// - still running, or no answer → marker kept for the next time.
  Future<void> resumePendingImport() async {
    try {
      final jobId = await pendingImportJobId();
      if (jobId == null) return;
      final Map<String, dynamic> job;
      try {
        job = await _job(jobId);
      } on ApiException catch (e) {
        if (e.statusCode == 404) await _clearPending();
        return;
      }
      switch (job['status']) {
        case 'succeeded':
          await _applySucceeded(TenantCacheGuard(_db));
        case 'failed':
          await _clearPending();
      }
    } catch (e) {
      debugPrint('resumePendingImport: $e — retrying at the next sign-in');
    }
  }

  /// The job id an unfinished import left in app_meta, if any.
  Future<String?> pendingImportJobId() async => (await (_db.select(_db.appMeta)
            ..where((t) => t.key.equals(pendingImportKey)))
          .getSingleOrNull())
      ?.value;

  /// The import committed; whatever happens here must not read as a failure.
  /// True — and the marker cleared — only when this device now shows the new data.
  Future<bool> _applySucceeded(TenantCacheGuard guard) async {
    try {
      // Work queued since the upload would be destroyed by the reset: keep the
      // cache and the marker, and let the next sign-in try again.
      if (await guard.hasLocalWork()) {
        debugPrint('owner import: unsent local work — refresh postponed');
        return false;
      }
      await _db.resetAfterServerImport();
      await pull?.call();
      await _pullHistory();
      await seedDocCounters?.call();
      await _clearPending();
      return true;
    } catch (e) {
      debugPrint('owner import: refresh failed ($e) — retrying at the next sign-in');
      return false;
    }
  }

  /// One copy of the shop's bills and credit notes into the emptied cache —
  /// the screens that read history (sales list, reports, returns lookup) read
  /// Drift only, and no pull brings history otherwise. Pages are newest
  /// first, so a bill another device rings up meanwhile only shifts rows that
  /// are fetched again (insert-or-ignore), never skipped. Stock and ledgers
  /// are not touched: the catalogue / customer / mechanic pull owns them.
  Future<void> _pullHistory() async {
    final gen = _db.cacheGeneration;
    await _pages('/api/v1/sales', (rows) async {
      for (final r in rows) {
        await _db.into(_db.sales).insert(
              SalesCompanion.insert(
                id: r['id'] as String,
                receiptNo: r['receiptNo'] as String,
                subtotal: money(r['subtotal']),
                discount: Value(money(r['discount'])),
                total: money(r['total']),
                paymentMethod: r['paymentMethod'] as String,
                customerId: Value(r['customerId'] as String?),
                customerName: Value(r['customerName'] as String?),
                mechanicId: Value(r['mechanicId'] as String?),
                mechanicName: Value(r['mechanicName'] as String?),
                mechanicDelta: Value(moneyOrNull(r['mechanicDelta'])),
                pointsGranted: Value(r['pointsGranted'] as int? ?? 0),
                date: stamp(r['date']),
                voided: Value(r['voided'] as bool? ?? false),
                voidedAt: Value(stampOrNull(r['voidedAt'])),
                voidReason: Value(r['voidReason'] as String?),
                soldOffline: Value(r['soldOffline'] as bool? ?? false),
                shiftId: Value(r['shiftId'] as String?),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        if ((await (_db.select(_db.saleItems)
                  ..where((t) => t.saleId.equals(r['id'] as String))
                  ..limit(1))
                .get())
            .isNotEmpty) {
          continue;
        }
        for (final l in _lines(r)) {
          await _db.into(_db.saleItems).insert(SaleItemsCompanion.insert(
                saleId: r['id'] as String,
                productId: l['productId'] as String,
                partNo: Value(l['partNo'] as String?),
                name: l['name'] as String,
                nameTH: Value(l['nameTH'] as String?),
                qty: l['qty'] as int,
                price: money(l['price']),
                costAtSale: Value(moneyOrNull(l['costAtSale'])),
              ));
        }
      }
    }, gen);
    await _pages('/api/v1/returns', (rows) async {
      for (final r in rows) {
        await _db.into(_db.returns).insert(
              ReturnsCompanion.insert(
                id: r['id'] as String,
                cnNo: r['cnNo'] as String,
                saleId: r['saleId'] as String,
                receiptNo: r['receiptNo'] as String,
                refundSubtotal: money(r['refundSubtotal']),
                refundDiscount: money(r['refundDiscount']),
                refundTotal: money(r['refundTotal']),
                refundMethod: r['refundMethod'] as String,
                reason: Value(r['reason'] as String? ?? ''),
                customerId: Value(r['customerId'] as String?),
                mechanicId: Value(r['mechanicId'] as String?),
                mechanicName: Value(r['mechanicName'] as String?),
                date: stamp(r['date']),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        if ((await (_db.select(_db.returnItems)
                  ..where((t) => t.returnId.equals(r['id'] as String))
                  ..limit(1))
                .get())
            .isNotEmpty) {
          continue;
        }
        for (final l in _lines(r)) {
          await _db.into(_db.returnItems).insert(ReturnItemsCompanion.insert(
                returnId: r['id'] as String,
                productId: l['productId'] as String,
                name: l['name'] as String,
                qty: l['qty'] as int,
                price: money(l['price']),
                originalQty: Value(l['originalQty'] as int?),
              ));
        }
      }
    }, gen);
  }

  static List<Map<String, dynamic>> _lines(Map<String, dynamic> r) =>
      (r['items'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList()
        ..sort((a, b) => (a['lineNo'] as int? ?? 0).compareTo(b['lineNo'] as int? ?? 0));

  /// Every page of a `Paginated` list, each written in one cache transaction
  /// fenced by [gen] (a tenant switch mid-way writes nothing more).
  Future<void> _pages(
    String path,
    Future<void> Function(List<Map<String, dynamic>> rows) write,
    int gen,
  ) async {
    for (var page = 1;; page++) {
      final res = await _api.getPaginated(path, queryParameters: {
        'page': '$page',
        'limit': '$historyPageSize',
      });
      final rows = res.data.map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (!await _db.writeCacheIfCurrent(gen, () => write(rows))) {
        throw StateError('cache reset during the history pull');
      }
      final total = (res.meta['total'] as num?)?.toInt() ?? 0;
      if (rows.length < historyPageSize || page * historyPageSize >= total) return;
    }
  }

  Future<Map<String, dynamic>> _job(String jobId) async =>
      (await _api.get('/api/v1/backup/import/$jobId') as Map).cast<String, dynamic>();

  Future<void> _setPending(String jobId) => _db.into(_db.appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(key: pendingImportKey, value: jobId),
      );

  Future<void> _clearPending() =>
      (_db.delete(_db.appMeta)..where((t) => t.key.equals(pendingImportKey))).go();

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
