// AppButton — brand button with primary / secondary / danger variants.
//
// Ports the preview/buttons.html language: orange primary CTA, navy secondary,
// red danger. Uppercase-ish dense POS feel via FilledButton/OutlinedButton.
// Use [AppButton] for actions; pass [icon] for a leading icon and [busy] to
// show a spinner + disable while an async action runs.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

enum AppButtonVariant { primary, secondary, danger }

class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool busy;
  final bool fullWidth;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.busy = false,
    this.fullWidth = false,
  });

  const AppButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.fullWidth = false,
  }) : variant = AppButtonVariant.secondary;

  const AppButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.fullWidth = false,
  }) : variant = AppButtonVariant.danger;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    // Label always single-line + ellipsis so a long Thai label (or an enlarged
    // text scale) shrinks gracefully instead of overflowing the button / its
    // enclosing Row.
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final child = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : (icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 8),
                  Flexible(child: labelText),
                ],
              )
            : labelText);

    final Widget button;
    switch (variant) {
      case AppButtonVariant.primary:
        button = FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.orange,
            foregroundColor: AppColors.white,
            disabledBackgroundColor: AppColors.gray500,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: child,
        );
        break;
      case AppButtonVariant.secondary:
        // Brightness-aware label: navy reads on the light surface, but on the
        // dark theme's navy surface navy-on-navy is invisible — use a light
        // foreground there. The steel-blue outline reads in both themes.
        final secondaryFg = Theme.of(context).brightness == Brightness.dark
            ? AppColors.white
            : AppColors.navy;
        button = OutlinedButton(
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: secondaryFg,
            side: const BorderSide(color: AppColors.steelBlue),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: child,
        );
        break;
      case AppButtonVariant.danger:
        button = FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: AppColors.white,
            disabledBackgroundColor: AppColors.gray500,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: child,
        );
        break;
    }

    return fullWidth ? SizedBox(width: double.infinity, child: button) : button;
  }
}
