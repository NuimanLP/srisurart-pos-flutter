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
    // #364 — `POST /platform/tenants` refuses an owner password that is absent or
    // under 12 characters (the same floor `bootstrap:admin` enforces), so the wording
    // states the rule rather than one of the two reasons. Ops-facing, not counter-facing:
    // no screen in this app provisions a tenant, so this entry exists so the code can
    // never surface as a raw English sentence if a tool ever does.
    'WEAK_PASSWORD': 'รหัสผ่านไม่ผ่านเกณฑ์ ต้องมีอย่างน้อย 12 ตัวอักษร',
    // #443 PR3 — agent ร่าง (02_API_SCREENS.md §8.1), not yet ratified by the owner.
    'TEMP_PASSWORD_EXPIRED':
        'รหัสผ่านชั่วคราวหมดอายุแล้ว กรุณาติดต่อทีมงานเพื่อขอรหัสใหม่',
    'PASSWORD_CHANGE_REQUIRED':
        'เจ้าของร้านต้องเปลี่ยนรหัสผ่านชั่วคราวก่อน จึงจะใช้งานเครื่องนี้ได้',
    // Ops-facing only (platform plane) — here so it never surfaces as raw English.
    'OWNER_PASSWORD_NOT_ACCEPTED':
        'ระบบไม่รับรหัสผ่านเจ้าของร้านจากผู้ดูแลแล้ว ระบบจะสุ่มรหัสชั่วคราวให้เอง',
    'OWNER_NOT_FOUND': 'ร้านนี้ไม่มีบัญชีเจ้าของร้านที่ใช้งานอยู่',
    'SHIFT_NOT_FOUND': 'ไม่พบข้อมูลกะ',
    // A plain `BadRequestException` (no code of its own) — agent ร่าง
    // (02_API_SCREENS.md §8.1.1), not yet ratified by the owner. Its English
    // `message` (e.g. `name is required`) used to reach the counter verbatim.
    'BAD_REQUEST': 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่',
    // Ratified by the owner 2026-10-03 (#27, PR #574) — 02_API_SCREENS.md §8/§8.1.
    // A quote cart sold through `POST /sales` `quoteId` (or `/convert`), and
    // DELETE of a converted quote.
    'QUOTE_EXPIRED': 'ใบเสนอราคาหมดอายุแล้ว — ทำซ้ำ (ต่ออายุ) ก่อนขาย',
    'QUOTE_ALREADY_CONVERTED':
        'ใบเสนอราคานี้แปลงเป็นการขายแล้ว — ล้างตะกร้าแล้วเริ่มใหม่',
    'QUOTE_CONVERTED_NOT_DELETABLE':
        'ใบเสนอราคานี้แปลงเป็นการขายแล้ว ลบไม่ได้',
    // agent ร่าง (02_API_SCREENS.md §8/§8.1), not yet ratified by the owner.
    // Owner 2026-10-03: a mechanic who still owes credit cannot be deleted.
    // The server sends no amount into this string; the Drift path and the
    // screen use `mechanicHasBalanceMessage` (with ฿X) instead.
    'MECHANIC_HAS_BALANCE': 'ช่างยังมียอดค้างชำระ — รับชำระให้ครบก่อนลบ',
    'UNAUTHENTICATED': 'กรุณาเข้าสู่ระบบ',
    'FORBIDDEN': 'ไม่มีสิทธิ์เข้าถึงข้อมูลหรือดำเนินการนี้',
  };

  /// `WEAK_PASSWORD` `details.reason` → Thai (#443 PR3) — agent ร่าง
  /// (02_API_SCREENS.md §8.1), not yet ratified by the owner. `too_short`
  /// keeps the owner-ratified #364 sentence.
  static const Map<String, String> _weakPasswordReasons = {
    'required': 'กรุณากรอกรหัสผ่านใหม่',
    'too_short': 'รหัสผ่านไม่ผ่านเกณฑ์ ต้องมีอย่างน้อย 12 ตัวอักษร',
    'too_long': 'รหัสผ่านยาวเกินไป ต้องไม่เกิน 128 ตัวอักษร',
    // The server checks a fixed brand-word list (SHOP_WORDS), not the tenant's own
    // name, so the message must not promise a shop-name check. This sentence
    // is owner-ratified 2026-10-01; the other reasons are still agent ร่าง.
    'common': 'รหัสผ่านนี้เดาง่ายเกินไป กรุณาตั้งรหัสอื่น',
    'same_as_temp': 'รหัสผ่านใหม่ต้องไม่ซ้ำกับรหัสผ่านชั่วคราว',
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

    // #443 PR3: `POST /auth/change-password` says *why* in `details.reason`,
    // and the owner at the counter needs the specific rule, not the #364 one.
    if (upperCode == 'WEAK_PASSWORD' && details is Map) {
      final reason = _weakPasswordReasons[details['reason']];
      if (reason != null) return reason;
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
