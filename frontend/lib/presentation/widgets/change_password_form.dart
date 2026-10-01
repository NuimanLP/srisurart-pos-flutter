// ChangePasswordForm — the forced first change of a temporary owner password
// (#443 PR3). Shown in place of LoginForm while AuthCubit is in
// AuthPasswordChangeRequired, so it works on the /login route and inside the
// Settings LoginDialog alike, with no route of its own: the router already keeps
// every non-signed-in state on /login, and a successful change is an ordinary
// sign-in that the redirect takes onward.
//
// The server enforces the rules (12..128, blocklist, ≠ temporary password) and
// says why in WEAK_PASSWORD's `details.reason`. Locally, PasswordRequirements
// ticks the rules that need no server (length bounds, both boxes equal) live,
// and submit stays disabled until they all hold — see password_field.dart.
//
// Strings: agent ร่าง (#443 PR3, 02_API_SCREENS.md §8.1) — not yet ratified.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/auth_cubit.dart';
import 'password_field.dart';

class ChangePasswordForm extends StatefulWidget {
  const ChangePasswordForm({super.key, this.onSuccess});

  /// Called after the new password is saved (the dialog host closes itself).
  final VoidCallback? onSuccess;

  static const String intro =
      'คุณเข้าสู่ระบบด้วยรหัสผ่านชั่วคราว กรุณาตั้งรหัสผ่านของคุณเองก่อนใช้งาน';
  static const String newLabel = 'รหัสผ่านใหม่';
  static const String confirmLabel = 'ยืนยันรหัสผ่านใหม่';
  static const String hint =
      'อย่างน้อย 12 ตัวอักษร เว้นวรรคหรือพิมพ์ภาษาไทยได้';
  static const String submit = 'บันทึกรหัสผ่าน';
  static const String cancel = 'ยกเลิก';

  @override
  State<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends State<ChangePasswordForm> {
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool get _rulesMet =>
      passwordRulesMet(_newController.text, confirm: _confirmController.text);

  @override
  void initState() {
    super.initState();
    _newController.addListener(_rebuild);
    _confirmController.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_rulesMet) return;
    final ok = await context.read<AuthCubit>().changePassword(
      _newController.text,
    );
    // Have the browser save the NEW password, not the temporary one it may
    // have captured at the login just before. Before the mounted check: a
    // success redirects away and unmounts the form.
    if (ok) TextInput.finishAutofillContext();
    if (ok && mounted) widget.onSuccess?.call();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthCubit>().state;
    final busy = state is AuthPasswordChangeRequired && state.submitting;
    final error = state is AuthPasswordChangeRequired
        ? state.errorMessage
        : null;

    // Only a successful save commits to the browser (_submit); leaving the
    // form any other way (cancel, expired token) saves nothing.
    return AutofillGroup(
      onDisposeAction: AutofillContextAction.cancel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(ChangePasswordForm.intro),
          const SizedBox(height: 16),
          PasswordField(
            key: const Key('change-password-new'),
            controller: _newController,
            enabled: !busy,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(
              labelText: ChangePasswordForm.newLabel,
              helperText: ChangePasswordForm.hint,
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 12),
          PasswordField(
            key: const Key('change-password-confirm'),
            controller: _confirmController,
            enabled: !busy,
            autofillHints: const [AutofillHints.newPassword],
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: ChangePasswordForm.confirmLabel,
              prefixIcon: Icon(Icons.lock_reset),
            ),
          ),
          const SizedBox(height: 12),
          PasswordRequirements(
            password: _newController.text,
            confirm: _confirmController.text,
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error, style: const TextStyle(color: AppColors.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy || !_rulesMet ? null : _submit,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(ChangePasswordForm.submit),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () => context.read<AuthCubit>().cancelPasswordChange(),
            child: const Text(ChangePasswordForm.cancel),
          ),
        ],
      ),
    );
  }
}
