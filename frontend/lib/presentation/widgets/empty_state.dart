// EmptyState — a centered placeholder for empty lists / no-data screens.
//
//   const EmptyState(icon: Icons.inbox, message: 'ยังไม่มีรายการ')
//
// Optionally pass an [action] widget (e.g. an AppButton) below the message.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? hint;
  final Widget? action;

  const EmptyState({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.message,
    this.hint,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrolls rather than overflows on a short screen (e.g. whole-screen zoom).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon in a soft disc so the state reads as intentional, not as
            // a screen that failed to load.
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppColors.steelBlue.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: AppColors.steelBlue),
            ),
            const SizedBox(height: 16),
            // Readable message (steel-blue text was ~3:1 on off-white).
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
