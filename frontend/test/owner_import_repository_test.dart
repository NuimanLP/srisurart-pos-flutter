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
          sent.add(req);
          return handler(req);
        }),
      ),
      db,
      pull: pull ?? () async => pulls++,
      seedDocCounters: () async => seeds++,
      pollInterval: Duration.zero,
      maxPolls: maxPolls,
    );
  }

  Future<int> rows(TableInfo table) async => (await db.select(table).get()).length;

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
    });
  }
}
