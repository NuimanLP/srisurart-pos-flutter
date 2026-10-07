// Settings → กู้คืนข้อมูล on the API build: OwnerImportRepository sends the
// backup to POST /api/v1/backup/import, polls the job, and runs the pull on
// success. Every refusal is a PosException in the owner's words.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
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
  late List<http.Request> sent;
  late int pulls;

  OwnerImportRepository repo(
    Future<http.Response> Function(http.Request) handler, {
    int maxPolls = 5,
  }) {
    sent = [];
    pulls = 0;
    return OwnerImportRepository(
      ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: FakeTokenStorage(),
        httpClient: MockClient((req) {
          sent.add(req);
          return handler(req);
        }),
      ),
      onImported: () async => pulls++,
      pollInterval: Duration.zero,
      maxPolls: maxPolls,
    );
  }

  test('posts the file, polls the job until it succeeds, then pulls', () async {
    var polls = 0;
    final r = repo((req) async {
      if (req.method == 'POST') return _ok(202, {'jobId': 'job-1'});
      polls++;
      return _ok(200, {'jobId': 'job-1', 'status': polls < 3 ? 'running' : 'succeeded'});
    });

    await r.importBackup(_snapshot);

    expect(sent.first.method, 'POST');
    expect(sent.first.url.path, '/api/v1/backup/import');
    expect(jsonDecode(sent.first.body), _snapshot);
    expect(sent.first.headers.containsKey('Idempotency-Key'), isFalse);
    expect(sent.skip(1).map((q) => '${q.method} ${q.url.path}').toSet(),
        {'GET /api/v1/backup/import/job-1'});
    expect(polls, 3);
    expect(pulls, 1);
  });

  test('a failed job reports the worker\'s error and pulls nothing', () async {
    final r = repo((req) async => req.method == 'POST'
        ? _ok(202, {'jobId': 'job-1'})
        : _ok(200, {'jobId': 'job-1', 'status': 'failed', 'error': 'boom'}));

    await expectLater(
      r.importBackup(_snapshot),
      throwsA(isA<PosException>()
          .having((e) => e.message, 'message', '${OwnerImportRepository.failedMessage}: boom')),
    );
    expect(pulls, 0);
  });

  test('stops polling at the cap with a Thai "still running" message', () async {
    final r = repo(
      (req) async => req.method == 'POST'
          ? _ok(202, {'jobId': 'job-1'})
          : _ok(200, {'jobId': 'job-1', 'status': 'queued'}),
      maxPolls: 4,
    );

    await expectLater(
      r.importBackup(_snapshot),
      throwsA(isA<PosException>().having(
          (e) => e.message, 'message', OwnerImportRepository.stillRunningMessage)),
    );
    expect(sent.length, 1 + 4);
    expect(pulls, 0);
  });

  final refusals = <String, (http.Response, String)>{
    'shop not empty (409)': (
      _err(409, 'CONFLICT', "Tenant already has transaction data in table 'sales' — import rejected"),
      OwnerImportRepository.notEmptyMessage,
    ),
    'old-app file (400 INVALID_ID)': (
      _err(400, 'INVALID_ID', 'Pre-flight failed: 3 id(s) are not lowercase UUIDs'),
      OwnerImportRepository.notFromThisServerMessage,
    ),
    'pre-flight refusal (400)': (
      _err(400, 'BAD_REQUEST', 'Pre-flight failed: product x has negative stock (-1)'),
      '${OwnerImportRepository.rejectedFileMessage}: Pre-flight failed: product x has negative stock (-1)',
    ),
    'too large (413)': (
      _err(413, 'PAYLOAD_TOO_LARGE', 'request entity too large'),
      OwnerImportRepository.tooLargeMessage,
    ),
    'no enrolled device (403)': (
      _err(403, 'DEVICE_ROLE_FORBIDDEN', 'เครื่องนี้ขายของไม่ได้'),
      OwnerImportRepository.needsEnrolledDeviceMessage,
    ),
    'server error (500) reads as the connection sentence': (
      _err(500, 'INTERNAL_ERROR', 'Internal server error'),
      'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
    ),
  };
  for (final c in refusals.entries) {
    test('refusal: ${c.key}', () async {
      final r = repo((_) async => c.value.$1);
      final thrown = await r.importBackup(_snapshot).then<Object?>((_) => null, onError: (Object e) => e);
      expect(thrown, isA<PosException>());
      expect(thrown, isNot(isA<ApiException>()));
      expect((thrown as PosException).message, c.value.$2);
      expect(sent, hasLength(1), reason: 'a refused start is never polled');
      expect(pulls, 0);
    });
  }
}
