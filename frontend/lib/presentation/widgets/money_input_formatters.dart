import 'package:flutter/services.dart';

/// Formatters for a baht amount field: a non-negative amount only. The app's
/// usual `[0-9.]` filter drops letters ("a400" read as 0 showed a false
/// shortfall on the close tab); the second step refuses an edit that is not one
/// number with at most 2 decimals ("1.2.3", "1.234"), keeping the previous text.
///
/// Money fields only — not for quantities (`AppTextField.numeric` stays
/// permissive for those). A 0–100 percent field uses [percentInputFormatters].
final moneyInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
  TextInputFormatter.withFunction(
    (oldValue, newValue) => RegExp(r'^\d*\.?\d{0,2}$').hasMatch(newValue.text)
        ? newValue
        : oldValue,
  ),
];

/// [moneyInputFormatters] plus: an edit whose value is above 100 is refused
/// (previous text kept). For the checkout bill discount in percent mode.
final percentInputFormatters = <TextInputFormatter>[
  ...moneyInputFormatters,
  TextInputFormatter.withFunction(
    (oldValue, newValue) =>
        (double.tryParse(newValue.text) ?? 0) > 100 ? oldValue : newValue,
  ),
];
