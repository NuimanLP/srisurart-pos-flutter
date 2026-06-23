// confirm_dialog — Thai confirmation dialog, the Flutter replacement for the
// JS window.confirm(). Buttons: ตกลง (confirm) / ยกเลิก (cancel).
//
//   final ok = await showConfirm(context, 'ลบสินค้า', 'ต้องการลบรายการนี้?');
//   if (ok) { ... }
//
// Pass [danger] true to color the confirm button red (deletes/voids).

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Shows a modal confirmation. Resolves to true on ตกลง, false on ยกเลิก /
/// dismiss. [confirmLabel] / [cancelLabel] override the default Thai labels.
Future<bool> showConfirm(
  BuildContext context,
  String title,
  String message, {
  bool danger = false,
  String confirmLabel = 'ตกลง',
  String cancelLabel = 'ยกเลิก',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: danger ? AppColors.error : AppColors.orange,
            foregroundColor: AppColors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
