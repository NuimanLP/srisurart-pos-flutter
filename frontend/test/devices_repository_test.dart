// Unit tests for DevicesRepository and DeviceModel (Slice 21, #192).

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/repositories/devices_repository.dart';
import 'package:srisurart_pos/domain/models/device_model.dart';

import 'auth_repository_test.dart';

void main() {
  group('DeviceModel', () {
    test('parses fromJson with full fields and validates helpers', () {
      final json = {
        'id': 'dev_001',
        'label': 'เคาน์เตอร์ 1',
        'deviceNo': 1,
        'role': 'pos',
        'retiredAt': null,
        'enrolled': true,
        'enrolExpiresAt': '2026-09-20T12:00:00.000Z',
        'lastSeenAt': '2026-09-19T10:00:00.000Z',
        'unsyncedOps': 3,
        'unsyncedReportedAt': '2026-09-19T09:30:00.000Z',
      };

      final device = DeviceModel.fromJson(json);

      expect(device.id, 'dev_001');
      expect(device.label, 'เคาน์เตอร์ 1');
      expect(device.deviceNo, 1);
      expect(device.role, 'pos');
      expect(device.isPos, isTrue);
      expect(device.isBackoffice, isFalse);
      expect(device.isRetired, isFalse);
      expect(device.enrolled, isTrue);
      expect(device.unsyncedOps, 3);
      expect(device.lastSeenAt, isNotNull);
      expect(device.unsyncedReportedAt, isNotNull);
      expect(device.toJson()['id'], 'dev_001');
    });

    test('correctly identifies retired device and pending enrolment code', () {
      final retired = DeviceModel.fromJson({
        'id': 'dev_002',
        'label': 'เครื่องเก่า',
        'deviceNo': 2,
        'role': 'backoffice',
        'retiredAt': '2026-09-18T10:00:00.000Z',
        'enrolled': false,
      });
      expect(retired.isRetired, isTrue);
      expect(retired.isBackoffice, isTrue);

      final futureExpire = DateTime.now().add(const Duration(minutes: 10));
      final pending = DeviceModel(
        id: 'dev_003',
        label: 'เครื่องใหม่',
        deviceNo: 3,
        role: 'pos',
        enrolled: false,
        enrolExpiresAt: futureExpire,
      );
      expect(pending.isEnrolCodeActive, isTrue);

      final pastExpire = DateTime.now().subtract(const Duration(minutes: 10));
      final expired = DeviceModel(
        id: 'dev_004',
        label: 'เครื่องหมดอายุ',
        deviceNo: 4,
        role: 'pos',
        enrolled: false,
        enrolExpiresAt: pastExpire,
      );
      expect(expired.isEnrolCodeActive, isFalse);
    });
  });

  group('DevicesRepository', () {
    late FakeTokenStorage tokenStorage;

    setUp(() {
      tokenStorage = FakeTokenStorage();
      tokenStorage.accessToken = 'test-token';
    });

    test('listDevices() returns mapped devices list', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/devices');

        final responseBody = jsonEncode([
          {
            'id': 'dev_01',
            'label': 'POS Main',
            'deviceNo': 1,
            'role': 'pos',
            'enrolled': true,
            'unsyncedOps': 0,
          },
          {
            'id': 'dev_02',
            'label': 'Backoffice 1',
            'deviceNo': 2,
            'role': 'backoffice',
            'enrolled': false,
            'unsyncedOps': 0,
          },
        ]);

        return http.Response(responseBody, 200, headers: {'content-type': 'application/json'});
      });

      final apiClient = ApiClient(
        baseUrl: 'http://localhost:3000',
        tokenStorage: tokenStorage,
        httpClient: mockClient,
      );
      final repo = DevicesRepository(apiClient);

      final devices = await repo.listDevices();

      expect(devices, hasLength(2));
      expect(devices[0].label, 'POS Main');
      expect(devices[0].isPos, isTrue);
      expect(devices[1].label, 'Backoffice 1');
      expect(devices[1].isBackoffice, isTrue);
    });

    test('createDevice() sends label and role with Idempotency-Key and returns code', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices');
        expect(request.headers.containsKey('Idempotency-Key'), isTrue);

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['label'], 'เคาน์เตอร์ 2');
        expect(body['role'], 'pos');

        final responseBody = jsonEncode({
          'device': {
            'id': 'dev_new',
            'label': 'เคาน์เตอร์ 2',
            'deviceNo': 3,
            'role': 'pos',
            'enrolled': false,
            'enrolExpiresAt': '2026-09-19T16:00:00.000Z',
            'unsyncedOps': 0,
          },
          'enrolCode': '491823',
        });

        return http.Response(responseBody, 201, headers: {'content-type': 'application/json'});
      });

      final apiClient = ApiClient(
        baseUrl: 'http://localhost:3000',
        tokenStorage: tokenStorage,
        httpClient: mockClient,
      );
      final repo = DevicesRepository(apiClient);

      final res = await repo.createDevice(label: '  เคาน์เตอร์ 2  ', role: 'pos');

      expect(res.enrolCode, '491823');
      expect(res.device.id, 'dev_new');
      expect(res.device.deviceNo, 3);
      expect(res.device.role, 'pos');
    });

    test('retireDevice() sends physicalCash and force note when specified', () async {
      String? capturedPath;
      Map<String, dynamic>? capturedBody;

      final mockClient = MockClient((request) async {
        expect(request.method, 'POST');
        capturedPath = request.url.path;
        expect(request.headers.containsKey('Idempotency-Key'), isTrue);

        if (request.body.isNotEmpty) {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        }

        return http.Response(
          jsonEncode({'device': {'id': 'dev_01', 'retiredAt': '2026-09-19T12:00:00.000Z'}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiClient = ApiClient(
        baseUrl: 'http://localhost:3000',
        tokenStorage: tokenStorage,
        httpClient: mockClient,
      );
      final repo = DevicesRepository(apiClient);

      await repo.retireDevice(
        deviceId: 'dev_01',
        physicalCash: 1250.50,
        force: true,
        note: 'เครื่องพังเปิดไม่ติด',
      );

      expect(capturedPath, '/api/v1/devices/dev_01/retire');
      expect(capturedBody?['physicalCash'], '1250.50');
      expect(capturedBody?['force'], isTrue);
      expect(capturedBody?['note'], 'เครื่องพังเปิดไม่ติด');
    });
  });
}
