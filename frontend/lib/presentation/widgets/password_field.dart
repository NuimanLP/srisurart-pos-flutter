// PasswordField — the one secret-text field with a show/hide (eye) toggle, and
// PasswordRequirements — the live checklist for forms that SET a password.
//
// The checklist mirrors the server, never invents rules: `server/src/common/password.ts`
// — `passwordPolicyViolation` (not blank, length >= MIN_PASSWORD_LENGTH) and
// `chosenPasswordViolation` (length <= MAX_PASSWORD_LENGTH). The blocklist and
// "differs from the temporary password" are server-only (the list lives there, the
// temporary password is not on this form), so they are a note, not a tick. No
// strength meter: the server has no strength rule, so one would mislead.
//
// Length is counted in UTF-16 code units, as JS `.length` is. The server measures
// after NFC; for Thai NFC only reorders marks, so the count is the same. A
// decomposed Latin accent could count one higher here — the server stays the
// authority and answers WEAK_PASSWORD.
//
// Strings: agent ร่าง (02_API_SCREENS.md §8.1.1) — not yet ratified.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Mirrors `MIN_PASSWORD_LENGTH` in `server/src/common/password.ts`.
const int kMinPasswordLength = 12;

/// Mirrors `MAX_PASSWORD_LENGTH` in `server/src/common/password.ts`.
const int kMaxPasswordLength = 128;

class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    this.controller,
    this.initialValue,
    this.isPin = false,
    this.decoration = const InputDecoration(),
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  static const String showTooltip = 'แสดงรหัสผ่าน';
  static const String hideTooltip = 'ซ่อนรหัสผ่าน';
  static const String showPinTooltip = 'แสดงรหัส PIN';
  static const String hidePinTooltip = 'ซ่อนรหัส PIN';

  final TextEditingController? controller;
  final String? initialValue;

  /// The secret is a PIN, not a password — only changes the eye's tooltip.
  final bool isPin;
  final InputDecoration decoration;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      initialValue: widget.controller == null ? widget.initialValue : null,
      obscureText: _obscured,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      decoration: widget.decoration.copyWith(
        suffixIcon: IconButton(
          icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
          tooltip: switch ((widget.isPin, _obscured)) {
            (false, true) => PasswordField.showTooltip,
            (false, false) => PasswordField.hideTooltip,
            (true, true) => PasswordField.showPinTooltip,
            (true, false) => PasswordField.hidePinTooltip,
          },
          onPressed: widget.enabled
              ? () {
                  setState(() {
                    _obscured = !_obscured;
                  });
                }
              : null,
        ),
      ),
    );
  }
}

/// One line of the checklist: its label and whether it is met right now.
typedef PasswordRule = ({String label, bool met});

/// The server's rules for a chosen password, evaluated live. [confirm] is null
/// when the form has no confirm box.
List<PasswordRule> passwordRules(String password, {String? confirm}) => [
  (
    label: PasswordRequirements.minLabel,
    met: password.trim().isNotEmpty && password.length >= kMinPasswordLength,
  ),
  (
    label: PasswordRequirements.maxLabel,
    // Neutral (unticked) while empty — an empty box has met nothing yet.
    met: password.isNotEmpty && password.length <= kMaxPasswordLength,
  ),
  if (confirm != null)
    (
      label: PasswordRequirements.matchLabel,
      met: password.isNotEmpty && password == confirm,
    ),
];

bool passwordRulesMet(String password, {String? confirm}) =>
    passwordRules(password, confirm: confirm).every((r) => r.met);

class PasswordRequirements extends StatelessWidget {
  const PasswordRequirements({super.key, required this.password, this.confirm});

  static const String minLabel = 'อย่างน้อย $kMinPasswordLength ตัวอักษร';
  static const String maxLabel = 'ไม่เกิน $kMaxPasswordLength ตัวอักษร';
  static const String matchLabel = 'รหัสผ่านทั้งสองช่องตรงกัน';
  static const String serverNote =
      'เมื่อกดบันทึก ระบบจะตรวจด้วยว่าไม่ใช่รหัสผ่านที่เดาง่าย และไม่ซ้ำรหัสผ่านชั่วคราว';

  final String password;
  final String? confirm;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in passwordRules(password, confirm: confirm))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(
                  r.met ? Icons.check_circle : Icons.radio_button_unchecked,
                  key: Key('pw-rule-${r.met ? 'met' : 'unmet'}'),
                  size: 18,
                  color: r.met ? AppColors.success : muted,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(r.label)),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          serverNote,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}
