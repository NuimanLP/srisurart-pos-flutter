// tax_identity.dart — the shop's เลขประจำตัวผู้เสียภาษี (13 digits) and สาขา
// (5 digits, 00000 = สำนักงานใหญ่), as typed in Settings → ทั่วไป and printed
// on the sales-tax report header (docs/research/thai-vat-abbreviated-invoice-
// 2026-10-23.md §3, §7.1).
//
// Validation is length + digits only: the research doc gives no check-digit
// algorithm for the Thai TIN, so none is applied here. The 5-digit branch
// format is an agent assumption ([ยังไม่ยืนยัน] — the doc only names 00000 =
// สำนักงานใหญ่, question O4).
//
// Validate first, then normalise: spaces and dashes are accepted as
// separators in a tax id (the owner may copy "0 1234 56789 01 2" off a
// certificate); anything else that is not 13 digits is refused, never trimmed
// into shape.

/// Shown under the tax-id field when it is not 13 digits — agent ร่าง.
const taxIdInvalidMessage = 'เลขประจำตัวผู้เสียภาษีต้องเป็นตัวเลข 13 หลัก';

/// Shown under the branch field when it is not 5 digits — agent ร่าง.
const branchNoInvalidMessage =
    'เลขสาขาต้องเป็นตัวเลข 5 หลัก (สำนักงานใหญ่ = 00000)';

/// The branch number of a head office.
const headOfficeBranchNo = '00000';

final _taxIdSeparators = RegExp(r'[\s-]');
final _thirteenDigits = RegExp(r'^\d{13}$');
final _fiveDigits = RegExp(r'^\d{5}$');

/// [raw] as the value to store: `value` is the 13 digits (null when the field
/// is empty — clears the tax id), `error` is the Thai refusal when it is not
/// 13 digits (then `value` is null and nothing may be saved).
({String? value, String? error}) parseTaxId(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return (value: null, error: null);
  final digits = trimmed.replaceAll(_taxIdSeparators, '');
  if (!_thirteenDigits.hasMatch(digits)) {
    return (value: null, error: taxIdInvalidMessage);
  }
  return (value: digits, error: null);
}

/// [raw] as the branch number to store: 5 digits, null when empty.
({String? value, String? error}) parseBranchNo(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return (value: null, error: null);
  if (!_fiveDigits.hasMatch(trimmed)) {
    return (value: null, error: branchNoInvalidMessage);
  }
  return (value: trimmed, error: null);
}

/// A stored 13-digit tax id grouped the way it is printed on RD forms,
/// `X-XXXX-XXXXX-XX-X`. Anything else (a legacy value typed before this
/// validation existed) is returned as it is.
String formatTaxId(String taxId) {
  if (!_thirteenDigits.hasMatch(taxId)) return taxId;
  return '${taxId.substring(0, 1)}-${taxId.substring(1, 5)}-'
      '${taxId.substring(5, 10)}-${taxId.substring(10, 12)}-'
      '${taxId.substring(12)}';
}

/// `สำนักงานใหญ่` for 00000, `สาขาที่ NNNNN` otherwise, '' when unset.
String branchLabel(String? branchNo) {
  final b = (branchNo ?? '').trim();
  if (b.isEmpty) return '';
  if (b == headOfficeBranchNo) return 'สำนักงานใหญ่';
  return 'สาขาที่ $b';
}
