// Unit tests for ServerErrorResolver and ApiException Thai message resolution.

import 'package:flutter_test/flutter_test.dart';
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
      expect(ServerErrorResolver.resolve('UNAUTHENTICATED'), 'กรุณาเข้าสู่ระบบ');
      expect(ServerErrorResolver.resolve('FORBIDDEN'), 'ไม่มีสิทธิ์เข้าถึงข้อมูลหรือดำเนินการนี้');
    });

    test('preserves verbatim English messages where specified in §8', () {
      expect(ServerErrorResolver.resolve('SALE_NOT_FOUND'), 'Sale not found');
      expect(ServerErrorResolver.resolve('SALE_VOIDED'), 'Bill already voided');
      expect(ServerErrorResolver.resolve('NO_OPEN_SHIFT'), 'No open shift');
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
}
