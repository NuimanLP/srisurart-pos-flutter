// AppTextField — a labeled text field with an optional numeric variant.
//
// Mirrors preview/form-inputs.html: a small uppercase-ish label above a bordered
// field, orange focus accent (from the active theme), optional error text.
// Use [AppTextField.numeric] for quantity/price/amount inputs (decimal keyboard).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'password_field.dart';

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

  /// With [obscureText]: the secret is a PIN (the eye's tooltip says PIN).
  final bool isPin;
  final String? errorText;
  final Widget? suffix;
  final TextInputAction? textInputAction;
  final int? maxLines;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

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
    this.isPin = false,
    this.errorText,
    this.suffix,
    this.textInputAction,
    this.maxLines = 1,
    this.keyboardType,
    this.inputFormatters,
  }) : assert(
         !obscureText || suffix == null,
         'obscureText fields carry the show/hide toggle as their suffix',
       ),
       assert(!obscureText || maxLines == 1, 'a secret field is one line'),
       assert(!isPin || obscureText, 'isPin only applies to a secret field');

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
    this.inputFormatters,
  }) : numeric = true,
       obscureText = false,
       isPin = false,
       maxLines = 1,
       keyboardType = const TextInputType.numberWithOptions(decimal: true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decoration = InputDecoration(
      hintText: hint,
      errorText: errorText,
      suffixIcon: suffix,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
    );
    // A secret field always gets the show/hide toggle as its suffix.
    final Widget field = obscureText
        ? PasswordField(
            controller: controller,
            initialValue: initialValue,
            isPin: isPin,
            autofocus: autofocus,
            enabled: enabled,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            textInputAction: textInputAction,
            onChanged: onChanged,
            onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
            decoration: decoration,
          )
        : TextFormField(
            controller: controller,
            initialValue: controller == null ? initialValue : null,
            autofocus: autofocus,
            enabled: enabled,
            maxLines: maxLines,
            keyboardType:
                keyboardType ??
                (numeric
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text),
            inputFormatters:
                inputFormatters ??
                (numeric
                    ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
                    : null),
            textInputAction: textInputAction,
            onChanged: onChanged,
            onFieldSubmitted: onSubmitted == null
                ? null
                : (_) => onSubmitted!(),
            decoration: decoration,
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
