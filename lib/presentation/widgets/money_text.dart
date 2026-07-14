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

  /// When true, render inside a `FittedBox(scaleDown)` so a large baht value
  /// (e.g. ฿1,234,567) or an enlarged accessibility text scale shrinks to fit
  /// its (constrained) cell on one line instead of wrapping or overflowing.
  final bool scaleDown;

  const MoneyText(
    this.value, {
    super.key,
    this.emphasis = false,
    this.style,
    this.color,
    this.scaleDown = false,
  });

  @override
  Widget build(BuildContext context) {
    final base = emphasis
        ? Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: color ?? AppColors.orange,
          )
        : Theme.of(context).textTheme.bodyMedium?.copyWith(color: color);
    final text = Text(
      baht(value),
      maxLines: 1,
      softWrap: !scaleDown,
      overflow: TextOverflow.ellipsis,
      style: (base ?? const TextStyle()).merge(style),
    );
    if (!scaleDown) return text;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: text,
    );
  }
}
