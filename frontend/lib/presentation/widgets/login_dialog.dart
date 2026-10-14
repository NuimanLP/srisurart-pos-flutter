// LoginDialog — Modal dialog for employee/owner authentication.
//
// The form itself is LoginForm, shared with the #143 LoginScreen.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'login_form.dart';

class LoginDialog extends StatelessWidget {
  const LoginDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LoginDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Scrolls instead of overflowing on a short screen / under 2x–3x zoom.
      scrollable: true,
      title: const Row(
        children: [
          Icon(Icons.lock_outline, color: AppColors.orange),
          SizedBox(width: 8),
          Flexible(child: Text('เข้าสู่ระบบ')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: LoginForm(
          onCancel: () => Navigator.of(context).pop(false),
          onSuccess: () {
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(context).pop(true);
            messenger.showSnackBar(
              const SnackBar(
                content: Text('เข้าสู่ระบบสำเร็จ'),
                backgroundColor: AppColors.success,
              ),
            );
          },
        ),
      ),
    );
  }
}
