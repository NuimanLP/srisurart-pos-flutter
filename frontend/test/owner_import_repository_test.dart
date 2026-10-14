// Settings → กู้คืนข้อมูล on the API build: OwnerImportRepository replaces the
// shop's data on the server (POST /api/v1/backup/import?mode=replace…), polls the
// job, then empties this device's cache of the old data, pulls and re-reads the
// document counters. Every refusal is a Thai PosException.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/owner_import_repository.dart';

import 'auth_repository_test.dart';

http.Response _ok(int status, Object data) => http.Response(
      jsonEncode({'status': 'success', 'data': data}),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _err(int status, String code, String message) => http.Response(
      jsonEncode({
        'status': 'error',
        'error': {'code': code, 'message': message},
      }),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const _snapshot = {
  '__meta': {'version': 2},
  'sa_products': <Object>[],
};

/// `GET /sales` / `GET /returns` as the server pages them (`Paginated`).
http.Response _page(List<Map<String, dynamic>> rows) => http.Response(
      jsonEncode({
        'status': 'success',
        'data': rows,
        'meta': {'total': rows.length, 'page': 1, 'limit': 200},
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

final _importedSale = <String, dynamic>{
  'id': 'imp-sale-1',
  'receiptNo': 'RC90003021E869',
  'subtotal': '300.00',
  'discount': '0.00',
  'total': '300.00',
  'paymentMethod': 'เงินสด',
  'customerId': null,
  'customerName': null,
  'mechanicId': null,
  'mechanicName': null,
  'mechanicDelta': null,
  'pointsGranted': 30,
  'date': '2026-10-05T03:00:00.000Z',
  'voided': false,
  'voidedAt': null,
  'voidReason': null,
  'soldOffline': false,
  'shiftId': null,
  'items': [
    {'lineNo': 2, 'productId': 'p2', 'partNo': null, 'name': 'B', 'nameTH': null, 'qty': 1, 'price': '100.00', 'costAtSale': null},
    {'lineNo': 1, 'productId': 'p1', 'partNo': 'P-1', 'name': 'A', 'nameTH': 'เอ', 'qty': 2, 'price': '100.00', 'costAtSale': '60.00'},
  ],
};

final _importedReturn = <String, dynamic>{
  'id': 'imp-ret-1',
  'cnNo': 'CN9000202305AD',
  'saleId': 'imp-sale-1',
  'receiptNo': 'RC90003021E869',
  'refundSubtotal': '100.00',
  'refundDiscount': '0.00',
  'refundTotal': '100.00',
  'refundMethod': 'เงินสด',
  'reason': 'ผิดรุ่น',
  'customerId': null,
  'mechanicId': null,
  'mechanicName': null,
  'date': '2026-10-06T03:00:00.000Z',
  'shiftId': null,
  'items': [
    {'lineNo': 1, 'productId': 'p1', 'name': 'A', 'qty': 1, 'price': '100.00', 'originalQty': 2, 'costAtSale': '60.00'},
  ],
};

void main() {
  late AppDatabase db;
  late List<http.Request> sent;
  late int pulls;
  late int seeds;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
    // Old data in the cache: a product and a till-only shift.
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: 'old-p1',
          partNo: 'OLD-1',
          name: 'Old part',
          nameTH: 'ของเก่า',
          category: 'เบรก',
          brand: 'X',
          price: 100,
          cost: 60,
          stock: 5,
          minStock: 1,
        ));
    await db.into(db.shifts).insert(ShiftsCompanion.insert(
          id: 'old-shift',
          dateStr: '2026-10-07',
          startingCash: 500,
          openedAt: DateTime(2026, 10, 7, 8),
          isActive: const Value(true),
        ));
    await db.into(db.appMeta).insert(
        AppMetaCompanion.insert(key: 'tenant_id', value: 'tenant-1'));
  });
  tearDown(() => db.close());

  OwnerImportRepository repo(
    Future<http.Response> Function(http.Request) handler, {
    int maxPolls = 5,
    Future<void> Function()? pull,
  }) {
    sent = [];
    pulls = 0;
    seeds = 0;
    return OwnerImportRepository(
      ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) {
          // The one-time history copy after a successful import.
          if (req.url.path == '/api/v1/sales') return Future.value(_page([_importedSale]));
          if (req.url.path == '/api/v1/returns') return Future.value(_page([_importedReturn]));
          sent.add(req);
          return handler(req);
        }),
      ),
      db,
      pull: pull ?? () async => pulls++,
      seedDocCounters: () async => seeds++,
      pollInterval: Duration.zero,
      maxPolls: maxPolls,
      exportPollInterval: Duration.zero,
      maxExportPolls: 3,
    );
  }

  Future<int> rows(TableInfo table) async => (await db.select(table).get()).length;
  Future<String?> marker() async => (await (db.select(db.appMeta)
            ..where((t) => t.key.equals(OwnerImportRepository.pendingImportKey)))
          .getSingleOrNull())
      ?.value;

  test('sends the file with mode=replace, the typed name and its own job id; polls; resets and pulls', () async {
    var polls = 0;
    final r = repo((req) async {
      if (req.method == 'POST') return _ok(202, {'jobId': req.url.queryParameters['jobId']});
      polls++;
      return _ok(200, {'status': polls < 3 ? 'running' : 'succeeded'});
    });

    final outcome = await r.importBackup(_snapshot, confirmShopName: 'ร้านทดสอบ');

    final post = sent.first;
    expect(post.method, 'POST');
    expect(post.url.path, '/api/v1/backup/import');
    expect(post.url.queryParameters['mode'], 'replace');
    expect(post.url.queryParameters['confirmShopName'], 'ร้านทดสอบ');
    final jobId = post.url.queryParameters['jobId']!;
    expect(jobId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(jsonDecode(post.body), _snapshot);
    expect(post.headers.containsKey('Idempotency-Key'), isFalse);
    expect(sent.skip(1).map((q) => '${q.method} ${q.url.path}').toSet(),
        {'GET /api/v1/backup/import/$jobId'});

    expect(outcome.refreshed, isTrue);
    expect(pulls, 1);
    expect(seeds, 1);
    // The old data is gone from this device; the tenant marker stays.
    expect(await rows(db.products), 0);
    expect(await rows(db.shifts), 0);
    expect(
      (await (db.select(db.appMeta)..where((t) => t.key.equals('tenant_id'))).getSingleOrNull())?.value,
      'tenant-1',
    );
    // The shop's history is on this device now, lines in lineNo order, and the marker is gone.
    final sale = await (db.select(db.sales)..where((t) => t.id.equals('imp-sale-1'))).getSingle();
    expect(sale.receiptNo, 'RC90003021E869');
    expect(sale.total, 300);
    final lines = await (db.select(db.saleItems)..orderBy([(t) => OrderingTerm.asc(t.rowId)])).get();
    expect(lines.map((l) => l.productId), ['p1', 'p2']);
    expect(lines.first.costAtSale, 60);
    expect(lines.last.costAtSale, isNull);
    expect(await rows(db.returns), 1);
    expect(await rows(db.returnItems), 1);
    expect(await marker(), isNull);
  });

  test('the marker is written before the upload and kept when the outcome is unknown', () async {
    String? atUpload;
    final r = repo(
      (req) async {
        if (req.method == 'POST') {
          atUpload = await marker();
          throw http.ClientException('timeout');
        }
        return _ok(200, {'status': 'running'});
      },
      maxPolls: 2,
    );
    await expectLater(r.importBackup(_snapshot, confirmShopName: 'x'), throwsA(isA<PosException>()));
    expect(atUpload, isNotNull);
    expect(await marker(), atUpload);
    expect(await rows(db.products), 1, reason: 'nothing reset while the outcome is unknown');
  });

  test('resume at sign-in: succeeded → reset, pull, history, counters, marker cleared', () async {
    await db.into(db.appMeta).insert(AppMetaCompanion.insert(
        key: OwnerImportRepository.pendingImportKey, value: 'job-1'));
    final r = repo((req) async => _ok(200, {'status': 'succeeded'}));
    await r.resumePendingImport();
    expect(sent.single.url.path, '/api/v1/backup/import/job-1');
    expect(await rows(db.products), 0);
    expect(await rows(db.sales), 1);
    expect(pulls, 1);
    expect(seeds, 1);
    expect(await marker(), isNull);
  });

  test('resume: failed or unknown job → marker cleared, cache kept; running or no answer → marker kept', () async {
    Future<String?> resumeWith(http.Response reply) async {
      await db.into(db.appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(
          key: OwnerImportRepository.pendingImportKey, value: 'job-1'));
      await repo((_) async => reply).resumePendingImport();
      return marker();
    }

    expect(await resumeWith(_ok(200, {'status': 'failed'})), isNull);
    expect(await resumeWith(_err(404, 'NOT_FOUND', 'no such job')), isNull);
    expect(await resumeWith(_ok(200, {'status': 'running'})), 'job-1');
    expect(await resumeWith(_err(503, 'SERVICE_UNAVAILABLE', 'busy')), 'job-1');
    expect(await rows(db.products), 1);
  });

  test('resume with unsent work on the device keeps the marker and touches nothing', () async {
    await db.into(db.appMeta).insert(AppMetaCompanion.insert(
        key: OwnerImportRepository.pendingImportKey, value: 'job-1'));
    await db.into(db.outboxOps).insert(OutboxOpsCompanion.insert(
          opId: 'op-1',
          idempotencyKey: 'idem-1',
          type: 'sale.create',
          payload: '{}',
          aggregates: '[]',
          createdAt: DateTime(2026, 10, 7),
          status: 'pending',
        ));
    await repo((_) async => _ok(200, {'status': 'succeeded'})).resumePendingImport();
    expect(await marker(), 'job-1');
    expect(await rows(db.products), 1);
    expect(pulls, 0);
  });

  test('resume with no marker sends nothing', () async {
    final r = repo((_) async => _ok(200, {'status': 'succeeded'}));
    await r.resumePendingImport();
    expect(sent, isEmpty);
  });

  test('refuses before sending anything while this device has unsent work', () async {
    await db.into(db.outboxOps).insert(OutboxOpsCompanion.insert(
          opId: 'op-1',
          idempotencyKey: 'idem-1',
          type: 'sale.create',
          payload: '{}',
          aggregates: '[]',
          createdAt: DateTime(2026, 10, 7),
          status: 'pending',
        ));
    final r = repo((_) async => _ok(202, {}));
    await expectLater(
      r.importBackup(_snapshot, confirmShopName: 'x'),
      throwsA(isA<PosException>().having(
          (e) => e.message, 'message', OwnerImportRepository.unsentWorkMessage)),
    );
    expect(sent, isEmpty);
    expect(await rows(db.products), 1);
  });

  test('a failed job reads in Thai only, and the cache is kept', () async {
    final r = repo((req) async => req.method == 'POST'
        ? _ok(202, {'jobId': 'j'})
        : _ok(200, {'status': 'failed', 'error': 'duplicate key value violates unique constraint'}));
    await expectLater(
      r.importBackup(_snapshot, confirmShopName: 'x'),
      throwsA(isA<PosException>().having(
          (e) => e.message, 'message', OwnerImportRepository.failedMessage)),
    );
    expect(pulls, 0);
    expect(await rows(db.products), 1);
  });

  test('a transient poll failure (503, dropped socket) does not abort the wait', () async {
    var polls = 0;
    final r = repo((req) async {
      if (req.method == 'POST') return _ok(202, {'jobId': 'j'});
      polls++;
      if (polls == 1) return _err(503, 'SERVICE_UNAVAILABLE', 'busy');
      if (polls == 2) throw http.ClientException('reset');
      return _ok(200, {'status': 'succeeded'});
    });
    final outcome = await r.importBackup(_snapshot, confirmShopName: 'x');
    expect(outcome.refreshed, isTrue);
    expect(polls, 3);
  });

  test('a lost upload reply is followed by polling the named job, never by sending again', () async {
    var polls = 0;
    final r = repo((req) async {
      if (req.method == 'POST') throw http.ClientException('timeout');
      polls++;
      // Not there yet while the server still checks the file, then running, then done.
      if (polls == 1) return _err(404, 'NOT_FOUND', 'no such job');
      return _ok(200, {'status': polls < 3 ? 'running' : 'succeeded'});
    });
    final outcome = await r.importBackup(_snapshot, confirmShopName: 'x');
    expect(outcome.refreshed, isTrue);
    expect(sent.where((q) => q.method == 'POST'), hasLength(1));
  });

  test('a lost upload that never shows up reads as "not received"', () async {
    final r = repo(
      (req) async => req.method == 'POST'
          ? throw http.ClientException('timeout')
          : _err(404, 'NOT_FOUND', 'no such job'),
      maxPolls: 3,
    );
    await expectLater(
      r.importBackup(_snapshot, confirmShopName: 'x'),
      throwsA(isA<PosException>().having(
          (e) => e.message, 'message', OwnerImportRepository.uploadLostMessage)),
    );
  });

  test('a 5xx on the upload is not a verdict: the named job is polled, not the file re-sent', () async {
    var polls = 0;
    final r = repo((req) async {
      if (req.method == 'POST') return _err(502, 'BAD_GATEWAY', 'proxy');
      polls++;
      return _ok(200, {'status': 'succeeded'});
    });
    final outcome = await r.importBackup(_snapshot, confirmShopName: 'x');
    expect(outcome.refreshed, isTrue);
    expect(sent.where((q) => q.method == 'POST'), hasLength(1));
    expect(polls, 1);
  });

  test('stops polling at the cap with a Thai "still running" message', () async {
    final r = repo(
      (req) async => req.method == 'POST' ? _ok(202, {'jobId': 'j'}) : _ok(200, {'status': 'queued'}),
      maxPolls: 4,
    );
    await expectLater(
      r.importBackup(_snapshot, confirmShopName: 'x'),
      throwsA(isA<PosException>().having(
          (e) => e.message, 'message', OwnerImportRepository.stillRunningMessage)),
    );
    expect(sent.length, 1 + 4);
  });

  test('a pull that throws after a committed import is not an error — only "please reload"', () async {
    final r = repo(
      (req) async => req.method == 'POST' ? _ok(202, {'jobId': 'j'}) : _ok(200, {'status': 'succeeded'}),
      pull: () async => throw http.ClientException('offline'),
    );
    final outcome = await r.importBackup(_snapshot, confirmShopName: 'x');
    expect(outcome.refreshed, isFalse);
  });

  final refusals = <String, (http.Response, String)>{
    'shop not empty (409)': (
      _err(409, 'TENANT_NOT_EMPTY', "Tenant already has transaction data in table 'sales' — import rejected"),
      OwnerImportRepository.notEmptyMessage,
    ),
    'another import running (409)': (
      _err(409, 'IMPORT_IN_PROGRESS', 'An import is already queued or running for this tenant'),
      OwnerImportRepository.inProgressMessage,
    ),
    'typed name does not match (400)': (
      _err(400, 'CONFIRM_SHOP_NAME_MISMATCH', 'confirmShopName does not match'),
      OwnerImportRepository.shopNameMismatchMessage,
    ),
    'old-app file (400 INVALID_ID)': (
      _err(400, 'INVALID_ID', 'Pre-flight failed: 3 id(s) are not lowercase UUIDs'),
      OwnerImportRepository.notFromThisServerMessage,
    ),
    'pre-flight refusal (400): Thai only, no English detail': (
      _err(400, 'BAD_REQUEST', 'Pre-flight failed: product x has negative stock (-1)'),
      OwnerImportRepository.rejectedFileMessage,
    ),
    'too large (413)': (
      _err(413, 'PAYLOAD_TOO_LARGE', 'request entity too large'),
      OwnerImportRepository.tooLargeMessage,
    ),
    'no enrolled device (403)': (
      _err(403, 'DEVICE_ROLE_FORBIDDEN', 'เครื่องนี้ขายของไม่ได้'),
      OwnerImportRepository.needsEnrolledDeviceMessage,
    ),
  };
  for (final c in refusals.entries) {
    test('refusal: ${c.key}', () async {
      final r = repo((_) async => c.value.$1);
      final thrown = await r
          .importBackup(_snapshot, confirmShopName: 'x')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(thrown, isA<PosException>());
      expect(thrown, isNot(isA<ApiException>()));
      expect((thrown as PosException).message, c.value.$2);
      expect(sent, hasLength(1), reason: 'a refused upload is never polled');
      expect(pulls, 0);
      expect(await rows(db.products), 1);
      expect(await marker(), isNull, reason: 'a refused upload created no job');
    });
  }

  group('product images (2026-10-10): raw upload and the .zip export', () {
    final zip = [0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 0xFF];

    test('a .zip is sent raw as application/zip; a .json as application/json', () async {
      final r = repo((req) async => req.method == 'POST'
          ? _ok(202, {'jobId': req.url.queryParameters['jobId']})
          : _ok(200, {'status': 'succeeded'}));
      await r.importBackupFile(zip,
          contentType: OwnerImportRepository.zipContentType, confirmShopName: 'ร้าน');
      expect(sent.first.url.path, '/api/v1/backup/import');
      expect(sent.first.headers['content-type'], 'application/zip');
      expect(sent.first.bodyBytes, zip);
      expect(sent.first.url.queryParameters['mode'], 'replace');

      final r2 = repo((req) async => req.method == 'POST'
          ? _ok(202, {'jobId': req.url.queryParameters['jobId']})
          : _ok(200, {'status': 'succeeded'}));
      await r2.importBackup(_snapshot, confirmShopName: 'ร้าน');
      expect(sent.first.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(utf8.decode(sent.first.bodyBytes)), _snapshot);
    });

    test('a .zip over the server cap reads as the 200 MB sentence', () async {
      final r = repo((req) async => _err(413, 'PAYLOAD_TOO_LARGE', 'too big'));
      await expectLater(
        r.importBackupFile(zip,
            contentType: OwnerImportRepository.zipContentType, confirmShopName: 'ร้าน'),
        throwsA(isA<PosException>().having(
            (e) => e.message, 'message', OwnerImportRepository.zipTooLargeMessage)),
      );
      expect(await marker(), isNull);
    });

    test('export: queue, poll the job, download the .zip from its downloadPath', () async {
      var polls = 0;
      final r = repo((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path == '/api/v1/backup/export') {
          return _ok(202, {'jobId': 'j1', 'status': 'queued'});
        }
        if (path == '/api/v1/backup/jobs/j1') {
          polls++;
          return _ok(200, polls < 2
              ? {'status': 'active'}
              : {
                  'status': 'completed',
                  'data': {'downloadPath': '/api/v1/backup/jobs/j1/download'},
                });
        }
        if (path == '/api/v1/backup/jobs/j1/download') {
          return http.Response.bytes(zip, 200,
              headers: {'content-type': 'application/zip'});
        }
        return _err(404, 'NOT_FOUND', path);
      });
      expect(await r.exportBackup(), zip);
      expect(sent.map((q) => '${q.method} ${q.url.path}').toList(), [
        'POST /api/v1/backup/export',
        'GET /api/v1/backup/jobs/j1',
        'GET /api/v1/backup/jobs/j1',
        'GET /api/v1/backup/jobs/j1/download',
      ]);
    });

    for (final c in {
      'failed job': (
        (http.Request req) async => req.method == 'POST'
            ? _ok(202, {'jobId': 'j1'})
            : _ok(200, {'status': 'failed'}),
        OwnerImportRepository.exportFailedMessage,
      ),
      'never finishes': (
        (http.Request req) async => req.method == 'POST'
            ? _ok(202, {'jobId': 'j1'})
            : _ok(200, {'status': 'active'}),
        OwnerImportRepository.exportTimedOutMessage,
      ),
      'not an enrolled device': (
        (http.Request req) async => _err(403, 'DEVICE_ROLE_FORBIDDEN', 'device'),
        OwnerImportRepository.exportNeedsEnrolledDeviceMessage,
      ),
      '5xx': (
        (http.Request req) async => http.Response('<html>bad gateway</html>', 502),
        'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
      ),
    }.entries) {
      test('export refusal in Thai: ${c.key}', () async {
        final r = repo(c.value.$1);
        await expectLater(
          r.exportBackup(),
          throwsA(isA<PosException>().having((e) => e.message, 'message', c.value.$2)),
        );
      });
    }
  });
}
