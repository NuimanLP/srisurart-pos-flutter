// AppTextField — a labeled text field with an optional numeric variant.
//
// Mirrors preview/form-inputs.html: a small uppercase-ish label above a bordered
// field, orange focus accent (from the active theme), optional error text.
// Use [AppTextField.numeric] for quantity/price/amount inputs (decimal keyboard).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTextField extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final bool numeric;
  final bool autofocus;
  final bool enabled;
  final bool obscureText;
  final String? errorText;
  final Widget? suffix;
  final TextInputAction? textInputAction;
  final int? maxLines;

  const AppTextField({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.onSubmitted,
    this.numeric = false,
    this.autofocus = false,
    this.enabled = true,
    this.obscureText = false,
    this.errorText,
    this.suffix,
    this.textInputAction,
    this.maxLines = 1,
  });

  const AppTextField.numeric({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.errorText,
    this.suffix,
    this.textInputAction,
  }) : numeric = true,
       obscureText = false,
       maxLines = 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final field = TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      autofocus: autofocus,
      enabled: enabled,
      obscureText: obscureText,
      maxLines: maxLines,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
          : null,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      decoration: InputDecoration(
        hintText: hint,
        errorText: errorText,
        suffixIcon: suffix,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );

    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label!,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        field,
      ],
    );
  }
}
