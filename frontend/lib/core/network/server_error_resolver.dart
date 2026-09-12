// Standardized error resolver for Srisurart POS backend errors.
//
// Maps server error codes to verbatim Thai error strings per:
//   docs/Backend_design/02_API_SCREENS.md §8 & §8.1

class ServerErrorResolver {
  ServerErrorResolver._();

  /// Canonical error strings mapped from 02_API_SCREENS.md §8 & §8.1.
  static const Map<String, String> _canonicalMessages = {
    'INSUFFICIENT_STOCK': 'สต็อกไม่พอ',
    'OVER_REFUND': 'คืนเกินจำนวนที่ขาย',
    'SALE_NOT_FOUND': 'Sale not found',
    'SALE_VOIDED': 'Bill already voided',
    'DRAWER_CLOSED': 'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
    'INVALID_BACKUP': 'ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta',
    'NO_OPEN_SHIFT': 'No open shift',
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
    'UNAUTHENTICATED': 'กรุณาเข้าสู่ระบบ',
    'FORBIDDEN': 'ไม่มีสิทธิ์เข้าถึงข้อมูลหรือดำเนินการนี้',
  };

  /// Resolves an error code and optional server-provided message into a user-facing string.
  ///
  /// Priority:
  /// 1. If server provides a detailed Thai message (e.g. detailed stock breakdown or suspension),
  ///    prefer that message if it starts with Thai or contains informative details.
  /// 2. Canonical mapping from 02_API_SCREENS.md §8.
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

    // If server sent a formatted message containing Thai text, it is usually the most specific
    // (e.g. "สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1").
    if (serverMessage != null &&
        serverMessage.trim().isNotEmpty &&
        _containsThai(serverMessage)) {
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

  static bool _containsThai(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x0E00 && rune <= 0x0E7F) {
        return true;
      }
    }
    return false;
  }
}
