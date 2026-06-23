// MoneyText — renders a numeric amount via baht() with the brand price accent.
//
// ALWAYS use this (or baht() directly) for currency — never inline a format.
// [emphasis] makes it large + orange + bold (the .t-price look from the design
// tokens); the default renders an inline price in the current text style.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';

class MoneyText extends StatelessWidget {
  final num value;
  final bool emphasis;
  final TextStyle? style;
  final Color? color;

  const MoneyText(
    this.value, {
    super.key,
    this.emphasis = false,
    this.style,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final base = emphasis
        ? Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color ?? AppColors.orange,
            )
        : Theme.of(context).textTheme.bodyMedium?.copyWith(color: color);
    return Text(baht(value), style: (base ?? const TextStyle()).merge(style));
  }
}
