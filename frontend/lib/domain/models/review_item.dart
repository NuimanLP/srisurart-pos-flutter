// Domain model for review items requiring owner attention.
// Defined in docs/Backend_design/08_PHASE2_SPEC.md §14.

enum ReviewItemKind {
  voidOffline('void_offline', 'ยกเลิกบิลออฟไลน์'),
  creditOverride('credit_override', 'วงเงินเกิน (อนุมัติพิเศษ)'),
  shiftUncounted('shift_uncounted', 'กะไม่ได้นับเงินสด'),
  dateFlag('date_flag', 'วันที่ถูกปรับ (clamp)'),
  deviceForceRetired('device_force_retired', 'ปลดเครื่องที่ค้างส่ง'),
  receiptRenumbered('receipt_renumbered', 'เลขใบเสร็จออฟไลน์ไม่ตรงกับระบบ'),
  unknown('unknown', 'รายการตรวจสอบ');

  final String value;
  final String labelTh;

  const ReviewItemKind(this.value, this.labelTh);

  static ReviewItemKind fromString(String? raw) {
    for (final k in values) {
      if (k.value == raw) return k;
    }
    return ReviewItemKind.unknown;
  }
}

class ReviewItem {
  final String id;
  final ReviewItemKind kind;
  final String refId;
  final Map<String, dynamic> details;
  final DateTime createdAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;

  const ReviewItem({
    required this.id,
    required this.kind,
    required this.refId,
    required this.details,
    required this.createdAt,
    this.reviewedAt,
    this.reviewedBy,
  });

  factory ReviewItem.fromJson(Map<String, dynamic> json) {
    return ReviewItem(
      id: json['id'] as String? ?? '',
      kind: ReviewItemKind.fromString(json['kind'] as String?),
      refId: json['refId'] as String? ?? '',
      details: json['details'] is Map<String, dynamic>
          ? json['details'] as Map<String, dynamic>
          : (json['details'] is Map
              ? Map<String, dynamic>.from(json['details'] as Map)
              : const <String, dynamic>{}),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      reviewedAt: json['reviewedAt'] != null
          ? DateTime.tryParse(json['reviewedAt'] as String)
          : null,
      reviewedBy: json['reviewedBy'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.value,
        'refId': refId,
        'details': details,
        'createdAt': createdAt.toIso8601String(),
        'reviewedAt': reviewedAt?.toIso8601String(),
        'reviewedBy': reviewedBy,
      };
}
