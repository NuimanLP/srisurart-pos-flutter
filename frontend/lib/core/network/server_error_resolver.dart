// Standardized error resolver for Srisurart POS backend errors.
//
// Maps server error codes to verbatim Thai error strings per:
//   docs/Backend_design/02_API_SCREENS.md §8 & §8.1

import 'dart:async';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

class ServerErrorResolver {
  ServerErrorResolver._();

  /// Resolves an error occurring at the counter into a cashier-facing message.
  ///
  /// - A server verdict ([PosException]) keeps its message verbatim.
  /// - Transport failures ([http.ClientException], [TimeoutException]) resolve
  ///   to the canonical Thai connection sentence (), hiding raw
  ///   English and URLs from cashiers (#199).
  /// - An unhandled [ApiException] resolves to its Thai mapping ([resolve(null)] for 5xx).
  /// - Generic exceptions drop the leading `Exception: ` prefix, while defensively
  ///   masking any leaked URLs.
  static String resolveCounterError(Object error) {
    if (error is PosException) {
      return error.message;
    }
    if (error is ApiException) {
      if (error.statusCode >= 500) return resolve(null);
      return error.thaiMessage;
    }
    if (error is http.ClientException || error is TimeoutException) {
      return resolve(null);
    }
    final s = error.toString();
    final clean =
        s.startsWith('Exception: ') ? s.substring('Exception: '.length) : s;
    if (clean.contains('http://') || clean.contains('https://')) {
      return resolve(null);
    }
    return clean;
  }

  /// Canonical error strings mapped from 02_API_SCREENS.md §8 & §8.1.
  static const Map<String, String> _canonicalMessages = {
    'INSUFFICIENT_STOCK': 'สต็อกไม่พอ',
    'OVER_REFUND': 'คืนเกินจำนวนที่ขาย',
    'SALE_NOT_FOUND': 'Sale not found',
    'SALE_VOIDED': 'Bill already voided',
    'DRAWER_CLOSED': 'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
    'INVALID_BACKUP': 'ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta',
    // §8 lists the English `No open shift` (the Drift service's own throw), but
    // since 2026-09-13 it also refuses sales and credit payments at the counter,
    // so the owner wants it in Thai. The sale / credit-payment paths use their
    // own sentences (`api_wire.dart`); this is the drawer-entry / close / flush one.
    'NO_OPEN_SHIFT': 'กรุณาเปิดกะก่อน',
    'PO_ALREADY_RECEIVED': 'ใบสั่งซื้อนี้รับของแล้ว',
    'DUPLICATE_PART_NO': 'รหัสอะไหล่นี้มีอยู่แล้ว',
    'TOTAL_MISMATCH': 'ยอดเงินไม่ตรงกัน กรุณาทำรายการใหม่',
    'OFFLINE_NOT_ALLOWED': 'สินค้านี้ขายตอนออฟไลน์ไม่ได้',
    'TENANT_SUSPENDED': 'ร้านนี้ถูกระงับการใช้งาน',
    'DEVICE_ROLE_FORBIDDEN': 'เครื่องนี้ขายของไม่ได้',
    'RATE_LIMITED': 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
    'CREDIT_LIMIT_EXCEEDED': 'เกินวงเงินเครดิต',
    'DOC_NUMBER_EXHAUSTED': 'เลขเอกสารเต็มโควตา',
    'SALE_HAS_RETURNS': 'บิลนี้มีใบลดหนี้แล้ว ไม่สามารถยกเลิกบิลได้',
    'SALE_ID_REUSED': 'รหัสบิลซ้ำ',
    'SHIFT_ALREADY_CLOSED': 'กะนี้ปิดแล้ว',
    'RETURN_PRICE_MISMATCH': 'ราคาใบลดหนี้ไม่ตรงกับบิลขาย',
    'REFUND_METHOD_NOT_ALLOWED': 'วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้',
    'IDEMPOTENCY_KEY_REUSED': 'คีย์การทำรายการซ้ำกับคำขออื่น',
    'IDEMPOTENCY_KEY_IN_FLIGHT': 'คำขอก่อนหน้ากำลังดำเนินการ กรุณารอสักครู่',
    'IDEMPOTENCY_KEY_INVALID': 'คีย์การทำรายการไม่ถูกต้อง',
    'RECEIPT_NO_CONFLICT': 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่',
    'CREDIT_PAYMENT_EXCEEDS_BALANCE': 'จำนวนเงินเกินยอดค้างชำระของช่าง',
    'CREDIT_PAYMENT_ID_REUSED': 'รหัสการรับชำระเงินซ้ำ',
    // Owner's wording, 2026-09-15 (#145).
    'SALE_NOT_IN_OPEN_SHIFT':
        'บิลนี้ไม่ได้อยู่ในกะที่เปิดอยู่ ยกเลิกบิลไม่ได้ กรุณาทำรายการคืนสินค้า (ใบลดหนี้) แทน',
    // Owner's wording, 2026-09-15 (#163) — device management, owner-facing.
    'POS_DEVICE_EXISTS':
        'ร้านมีเครื่องขายอยู่แล้ว 1 เครื่อง กรุณาปลดเครื่องขายเดิมก่อนเพิ่มเครื่องใหม่',
    'DEVICE_NO_EXHAUSTED': 'เพิ่มเครื่องไม่ได้ ร้านใช้เลขเครื่องครบ 99 เครื่องแล้ว',
    'DEVICE_ALREADY_RETIRED': 'เครื่องนี้ถูกปลดไปแล้ว',
    'PHYSICAL_CASH_REQUIRED':
        'เครื่องนี้ยังมีกะเปิดอยู่ กรุณานับเงินในลิ้นชักและกรอกยอดก่อนปลดเครื่อง',
    // Owner's wording, 2026-09-17 (#268, F10) — Phase 2 offline/sync/devices.
    'DOC_NUMBER_REQUIRED': 'จำเป็นต้องระบุเลขที่เอกสาร',
    'DOC_NUMBER_INVALID': 'รูปแบบเลขที่เอกสารไม่ถูกต้อง',
    'VOID_NEEDS_ONLINE':
        'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น',
    'CLIENT_ID_REUSED': 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
    'DEVICE_HAS_UNSYNCED_OPS':
        'เครื่องนี้ยังมีรายการขายค้างส่ง กรุณาเชื่อมต่อเน็ตเพื่อส่งข้อมูลก่อนปลดเครื่อง',
    'SHIFT_NOT_FOUND': 'ไม่พบข้อมูลกะ',
    'UNAUTHENTICATED': 'กรุณาเข้าสู่ระบบ',
    'FORBIDDEN': 'ไม่มีสิทธิ์เข้าถึงข้อมูลหรือดำเนินการนี้',
  };

  /// Resolves an error code and optional server-provided message into a user-facing string.
  ///
  /// Priority:
  /// 1. If server provides a detailed Thai message (e.g. detailed stock breakdown or suspension),
  ///    prefer that message if it starts with Thai.
  /// 2. Canonical mapping from 02_API_SCREENS.md §8 & §8.1.
  /// 3. Server message if present.
  /// 4. Fallback generic Thai message.
  static String resolve(
    String? code, {
    String? serverMessage,
    dynamic details,
  }) {
    if (code == null || code.isEmpty) {
      return (serverMessage != null && serverMessage.trim().isNotEmpty)
          ? serverMessage
          : 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์';
    }

    final upperCode = code.toUpperCase().trim();

    // If server sent a formatted message starting with Thai text, it is usually the most specific
    // (e.g. "สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1").
    // We check _startsWithThai so English messages quoting Thai words (e.g. "Refund method 'หักจากเครดิต'...")
    // do not hijack the canonical Thai mapping.
    if (serverMessage != null &&
        serverMessage.trim().isNotEmpty &&
        _startsWithThai(serverMessage)) {
      return serverMessage.trim();
    }

    // Look up canonical message
    if (_canonicalMessages.containsKey(upperCode)) {
      return _canonicalMessages[upperCode]!;
    }

    // Fall back to server message if available
    if (serverMessage != null && serverMessage.trim().isNotEmpty) {
      return serverMessage.trim();
    }

    return 'เกิดข้อผิดพลาด ($upperCode)';
  }

  static bool _startsWithThai(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    for (final rune in trimmed.runes) {
      // Skip leading whitespace, quotes, dashes, brackets
      if (rune == 0x20 ||
          rune == 0x22 ||
          rune == 0x27 ||
          rune == 0x2D ||
          rune == 0x28 ||
          rune == 0x5B) {
        continue;
      }
      return rune >= 0x0E00 && rune <= 0x0E7F;
    }
    return false;
  }
}
