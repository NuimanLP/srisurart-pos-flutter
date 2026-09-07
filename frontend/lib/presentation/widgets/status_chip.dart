// StatusChip — a small pill for document/record statuses (open, converted,
// received, voided, expired …). The screen passes the Thai label + a tone; the
// chip applies the matching brand color. There is a convenience [StatusChip.of]
// that maps common status keys to a tone + Thai label.
//
//   const StatusChip('ยังใช้ได้', tone: StatusTone.success)
//   StatusChip.of('converted')   // → ✓ แปลงแล้ว (info tone)

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

enum StatusTone { success, info, warning, danger, neutral }

class StatusChip extends StatelessWidget {
  final String label;
  final StatusTone tone;

  const StatusChip(this.label, {super.key, this.tone = StatusTone.neutral});

  /// Maps a common status key (open/converted/received/cancelled/voided/expired)
  /// to a Thai label + tone. Falls back to the raw key with a neutral tone.
  factory StatusChip.of(String status) {
    switch (status) {
      case 'open':
        return const StatusChip('เปิดอยู่', tone: StatusTone.info);
      case 'converted':
        return const StatusChip('แปลงแล้ว', tone: StatusTone.success);
      case 'received':
        return const StatusChip('รับแล้ว', tone: StatusTone.success);
      case 'expired':
        return const StatusChip('หมดอายุ', tone: StatusTone.warning);
      case 'cancelled':
        return const StatusChip('ยกเลิก', tone: StatusTone.danger);
      case 'voided':
        return const StatusChip('ยกเลิกบิล', tone: StatusTone.danger);
      default:
        return StatusChip(status);
    }
  }

  Color get _color {
    switch (tone) {
      case StatusTone.success:
        return AppColors.successLight;
      case StatusTone.info:
        return AppColors.steelBlue;
      case StatusTone.warning:
        return AppColors.warning;
      case StatusTone.danger:
        return AppColors.error;
      case StatusTone.neutral:
        return AppColors.gray500;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}
