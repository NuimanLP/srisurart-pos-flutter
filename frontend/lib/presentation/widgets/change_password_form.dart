// ChangePasswordForm — the forced first change of a temporary owner password
// (#443 PR3). Shown in place of LoginForm while AuthCubit is in
// AuthPasswordChangeRequired, so it works on the /login route and inside the
// Settings LoginDialog alike, with no route of its own: the router already keeps
// every non-signed-in state on /login, and a successful change is an ordinary
// sign-in that the redirect takes onward.
//
// The server enforces the rules (12..128, blocklist, ≠ temporary password) and
// says why in WEAK_PASSWORD's `details.reason`; the only local checks are the
// two that need no server — both boxes filled and equal — plus the length
// floor, so a too-short password is not a round trip.
//
// Strings: agent ร่าง (#443 PR3, 02_API_SCREENS.md §8.1) — not yet ratified.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/auth_cubit.dart';

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
  static const String mismatch = 'รหัสผ่านทั้งสองช่องไม่ตรงกัน';
  static const String tooShort =
      'รหัสผ่านไม่ผ่านเกณฑ์ ต้องมีอย่างน้อย 12 ตัวอักษร';
  static const String submit = 'บันทึกรหัสผ่าน';
  static const String cancel = 'ยกเลิก';

  @override
  State<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends State<ChangePasswordForm> {
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _newController.text;
    if (pw.length < 12) {
      setState(() {
        _localError = ChangePasswordForm.tooShort;
      });
      return;
    }
    if (pw != _confirmController.text) {
      setState(() {
        _localError = ChangePasswordForm.mismatch;
      });
      return;
    }
    setState(() {
      _localError = null;
    });
    final ok = await context.read<AuthCubit>().changePassword(pw);
    if (ok && mounted) widget.onSuccess?.call();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthCubit>().state;
    final busy = state is AuthPasswordChangeRequired && state.submitting;
    final error =
        _localError ??
        (state is AuthPasswordChangeRequired ? state.errorMessage : null);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(ChangePasswordForm.intro),
        const SizedBox(height: 16),
        TextField(
          key: const Key('change-password-new'),
          controller: _newController,
          obscureText: true,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: ChangePasswordForm.newLabel,
            helperText: ChangePasswordForm.hint,
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('change-password-confirm'),
          controller: _confirmController,
          obscureText: true,
          enabled: !busy,
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: ChangePasswordForm.confirmLabel,
            prefixIcon: Icon(Icons.lock_reset),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error, style: const TextStyle(color: AppColors.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : _submit,
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
    );
  }
}
