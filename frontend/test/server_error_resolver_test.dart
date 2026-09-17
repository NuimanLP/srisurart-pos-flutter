// Unit tests for ServerErrorResolver and ApiException Thai message resolution.

import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/core/network/server_error_resolver.dart';

void main() {
  group('ServerErrorResolver', () {
    test('resolves canonical error strings from 02_API_SCREENS.md §8 & §8.1', () {
      expect(ServerErrorResolver.resolve('DRAWER_CLOSED'), 'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้');
      expect(ServerErrorResolver.resolve('INVALID_BACKUP'), 'ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta');
      expect(ServerErrorResolver.resolve('PO_ALREADY_RECEIVED'), 'ใบสั่งซื้อนี้รับของแล้ว');
      expect(ServerErrorResolver.resolve('DUPLICATE_PART_NO'), 'รหัสอะไหล่นี้มีอยู่แล้ว');
      expect(ServerErrorResolver.resolve('TOTAL_MISMATCH'), 'ยอดเงินไม่ตรงกัน กรุณาทำรายการใหม่');
      expect(ServerErrorResolver.resolve('OFFLINE_NOT_ALLOWED'), 'สินค้านี้ขายตอนออฟไลน์ไม่ได้');
      expect(ServerErrorResolver.resolve('TENANT_SUSPENDED'), 'ร้านนี้ถูกระงับการใช้งาน');
      expect(ServerErrorResolver.resolve('DEVICE_ROLE_FORBIDDEN'), 'เครื่องนี้ขายของไม่ได้');
      expect(ServerErrorResolver.resolve('RATE_LIMITED'), 'ระบบกำลังทำงานหนัก กรุณารอสักครู่');
      expect(ServerErrorResolver.resolve('CREDIT_LIMIT_EXCEEDED'), 'เกินวงเงินเครดิต');
      expect(ServerErrorResolver.resolve('DOC_NUMBER_EXHAUSTED'), 'เลขเอกสารเต็มโควตา');
      expect(ServerErrorResolver.resolve('SALE_HAS_RETURNS'), 'บิลนี้มีใบลดหนี้แล้ว ไม่สามารถยกเลิกบิลได้');
      expect(ServerErrorResolver.resolve('SALE_ID_REUSED'), 'รหัสบิลซ้ำ');
      expect(ServerErrorResolver.resolve('SHIFT_ALREADY_CLOSED'), 'กะนี้ปิดแล้ว');
      expect(ServerErrorResolver.resolve('RETURN_PRICE_MISMATCH'), 'ราคาใบลดหนี้ไม่ตรงกับบิลขาย');
      expect(ServerErrorResolver.resolve('REFUND_METHOD_NOT_ALLOWED'), 'วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้');
      expect(ServerErrorResolver.resolve('IDEMPOTENCY_KEY_REUSED'), 'คีย์การทำรายการซ้ำกับคำขออื่น');
      expect(ServerErrorResolver.resolve('IDEMPOTENCY_KEY_IN_FLIGHT'), 'คำขอก่อนหน้ากำลังดำเนินการ กรุณารอสักครู่');
      expect(ServerErrorResolver.resolve('IDEMPOTENCY_KEY_INVALID'), 'คีย์การทำรายการไม่ถูกต้อง');
      expect(ServerErrorResolver.resolve('RECEIPT_NO_CONFLICT'), 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่');
      expect(ServerErrorResolver.resolve('CREDIT_PAYMENT_EXCEEDS_BALANCE'), 'จำนวนเงินเกินยอดค้างชำระของช่าง');
      expect(ServerErrorResolver.resolve('CREDIT_PAYMENT_ID_REUSED'), 'รหัสการรับชำระเงินซ้ำ');
      expect(ServerErrorResolver.resolve('SALE_NOT_IN_OPEN_SHIFT'), 'บิลนี้ไม่ได้อยู่ในกะที่เปิดอยู่ ยกเลิกบิลไม่ได้ กรุณาทำรายการคืนสินค้า (ใบลดหนี้) แทน');
      expect(ServerErrorResolver.resolve('POS_DEVICE_EXISTS'), 'ร้านมีเครื่องขายอยู่แล้ว 1 เครื่อง กรุณาปลดเครื่องขายเดิมก่อนเพิ่มเครื่องใหม่');
      expect(ServerErrorResolver.resolve('DEVICE_NO_EXHAUSTED'), 'เพิ่มเครื่องไม่ได้ ร้านใช้เลขเครื่องครบ 99 เครื่องแล้ว');
      expect(ServerErrorResolver.resolve('DEVICE_ALREADY_RETIRED'), 'เครื่องนี้ถูกปลดไปแล้ว');
      expect(ServerErrorResolver.resolve('PHYSICAL_CASH_REQUIRED'), 'เครื่องนี้ยังมีกะเปิดอยู่ กรุณานับเงินในลิ้นชักและกรอกยอดก่อนปลดเครื่อง');
      // Phase 2 (#268, F10)
      expect(ServerErrorResolver.resolve('DOC_NUMBER_REQUIRED'), 'จำเป็นต้องระบุเลขที่เอกสาร');
      expect(ServerErrorResolver.resolve('DOC_NUMBER_INVALID'), 'รูปแบบเลขที่เอกสารไม่ถูกต้อง');
      expect(ServerErrorResolver.resolve('VOID_NEEDS_ONLINE'), 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น');
      expect(ServerErrorResolver.resolve('CLIENT_ID_REUSED'), 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ');
      expect(ServerErrorResolver.resolve('DEVICE_HAS_UNSYNCED_OPS'), 'เครื่องนี้ยังมีรายการขายค้างส่ง กรุณาเชื่อมต่อเน็ตเพื่อส่งข้อมูลก่อนปลดเครื่อง');
      expect(ServerErrorResolver.resolve('SHIFT_NOT_FOUND'), 'ไม่พบข้อมูลกะ');
      expect(ServerErrorResolver.resolve('UNAUTHENTICATED'), 'กรุณาเข้าสู่ระบบ');
      expect(ServerErrorResolver.resolve('FORBIDDEN'), 'ไม่มีสิทธิ์เข้าถึงข้อมูลหรือดำเนินการนี้');
    });

    test('English server message quoting Thai phrase falls back to canonical Thai mapping (#83)', () {
      expect(
        ServerErrorResolver.resolve(
          'REFUND_METHOD_NOT_ALLOWED',
          serverMessage: "Refund method 'หักจากเครดิต' needs a bill with a mechanic.",
        ),
        'วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้',
      );
    });

    test('preserves verbatim English messages where specified in §8', () {
      expect(ServerErrorResolver.resolve('SALE_NOT_FOUND'), 'Sale not found');
      expect(ServerErrorResolver.resolve('SALE_VOIDED'), 'Bill already voided');
    });

    test('NO_OPEN_SHIFT renders in Thai even though the server sends English', () {
      // Owner, 2026-09-13: the code now refuses money at the counter.
      expect(
        ServerErrorResolver.resolve('NO_OPEN_SHIFT', serverMessage: 'No open shift'),
        'กรุณาเปิดกะก่อน',
      );
    });

    test('prefers server message when server provides formatted Thai details', () {
      const detailedMessage = 'สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1';
      expect(
        ServerErrorResolver.resolve('INSUFFICIENT_STOCK', serverMessage: detailedMessage),
        detailedMessage,
      );

      const refundDetail = 'คืนเกินจำนวนที่ขาย:\nกรองน้ำมันเครื่อง: คืนได้อีก 2 แต่ขอคืน 3';
      expect(
        ServerErrorResolver.resolve('OVER_REFUND', serverMessage: refundDetail),
        refundDetail,
      );
    });

    test('case-insensitivity of error codes', () {
      expect(ServerErrorResolver.resolve('tenant_suspended'), 'ร้านนี้ถูกระงับการใช้งาน');
      expect(ServerErrorResolver.resolve('  Device_Role_Forbidden  '), 'เครื่องนี้ขายของไม่ได้');
    });

    test('fallback for unknown code and empty code', () {
      expect(ServerErrorResolver.resolve('SOME_RANDOM_CODE'), 'เกิดข้อผิดพลาด (SOME_RANDOM_CODE)');
      expect(ServerErrorResolver.resolve('', serverMessage: 'Custom error'), 'Custom error');
      expect(ServerErrorResolver.resolve(null), 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์');
    });
  });

  group('ApiException', () {
    test('computes thaiMessage and formatted toString()', () {
      final ex = ApiException(
        statusCode: 429,
        code: 'RATE_LIMITED',
        retryAfterSeconds: 30,
      );

      expect(ex.statusCode, 429);
      expect(ex.code, 'RATE_LIMITED');
      expect(ex.retryAfterSeconds, 30);
      expect(ex.thaiMessage, 'ระบบกำลังทำงานหนัก กรุณารอสักครู่');
      expect(ex.toString(), contains('Retry-After: 30s'));
    });
  });

  group('resolveCounterError (#199)', () {
    test('preserves PosException message verbatim', () {
      const ex1 = PosException('INSUFFICIENT_STOCK', 'สต็อกไม่พอ');
      expect(ServerErrorResolver.resolveCounterError(ex1), 'สต็อกไม่พอ');

      const ex2 = PosException('SALE_NOT_FOUND', 'Sale not found');
      expect(ServerErrorResolver.resolveCounterError(ex2), 'Sale not found');

      const ex3 = PosException('DRAWER_CLOSED', 'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้');
      expect(
        ServerErrorResolver.resolveCounterError(ex3),
        'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
      );
    });

    test('renders canonical connection sentence on http.ClientException', () {
      final ex = http.ClientException(
        'Connection closed before full header was received',
        Uri.parse('http://127.0.0.1:3000/api/v1/sales'),
      );
      final res = ServerErrorResolver.resolveCounterError(ex);
      expect(res, ServerErrorResolver.resolve(null));
      expect(res, 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์');
      expect(res, isNot(contains('http://')));
      expect(res, isNot(contains('ClientException')));
    });

    test('renders canonical connection sentence on ApiTimeoutException (#183/#199)', () {
      final ex = ApiTimeoutException(
        const Duration(seconds: 40),
        Uri.parse('http://pos-server.local:3000/api/v1/sales'),
      );
      final res = ServerErrorResolver.resolveCounterError(ex);
      expect(res, ServerErrorResolver.resolve(null));
      expect(res, 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์');
      expect(res, isNot(contains('40000 ms')));
      expect(res, isNot(contains('http://pos-server.local')));
      expect(res, isNot(contains('ClientException')));
    });

    test('renders canonical connection sentence on TimeoutException', () {
      final ex = TimeoutException('Timeout expired after 40 seconds');
      final res = ServerErrorResolver.resolveCounterError(ex);
      expect(res, ServerErrorResolver.resolve(null));
      expect(res, 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์');
      expect(res, isNot(contains('TimeoutException')));
    });

    test('renders canonical connection sentence on 5xx ApiException', () {
      final ex = ApiException(statusCode: 502, code: 'BAD_GATEWAY', serverMessage: 'Bad Gateway');
      expect(
        ServerErrorResolver.resolveCounterError(ex),
        ServerErrorResolver.resolve(null),
      );
    });

    test('renders thaiMessage on 4xx ApiException', () {
      final ex = ApiException(statusCode: 429, code: 'RATE_LIMITED');
      expect(
        ServerErrorResolver.resolveCounterError(ex),
        'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
      );
    });

    test('cleans leading Exception: on standard exceptions', () {
      final ex = Exception('ข้อผิดพลาดทั่วไป');
      expect(ServerErrorResolver.resolveCounterError(ex), 'ข้อผิดพลาดทั่วไป');
    });

    test('defensively masks any exception that leaks a URL (#199)', () {
      final ex = Exception('Failed to connect to http://192.168.1.50:3000/endpoint');
      final res = ServerErrorResolver.resolveCounterError(ex);
      expect(res, ServerErrorResolver.resolve(null));
      expect(res, isNot(contains('192.168.1.50')));
    });
  });
}
