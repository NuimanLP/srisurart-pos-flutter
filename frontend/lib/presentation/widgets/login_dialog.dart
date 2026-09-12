// LoginDialog — Modal dialog for employee/owner authentication.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/auth_cubit.dart';
import 'app_button.dart';
import 'app_text_field.dart';

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LoginDialog(),
    );
  }

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'กรุณากรอกชื่อผู้ใช้และรหัสผ่าน';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    final cubit = context.read<AuthCubit>();
    final success = await cubit.login(username: username, password: password);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('เข้าสู่ระบบสำเร็จ'),
          backgroundColor: AppColors.success,
        ),
      );
    } else {
      final state = cubit.state;
      setState(() {
        _busy = false;
        _errorMessage = (state is Unauthenticated)
            ? state.errorMessage ?? 'เข้าสู่ระบบไม่สำเร็จ'
            : 'เข้าสู่ระบบไม่สำเร็จ';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthCubit>().state;
    final isPosDevice = authState is Authenticated
        ? authState.isPos
        : (authState is Unauthenticated ? authState.isPos : false);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline, color: AppColors.orange),
          SizedBox(width: 8),
          Text('เข้าสู่ระบบ'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isPosDevice
                    ? AppColors.success.withValues(alpha: 0.1)
                    : Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isPosDevice
                      ? AppColors.success.withValues(alpha: 0.3)
                      : Colors.grey.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isPosDevice ? Icons.point_of_sale : Icons.computer,
                    size: 18,
                    color: isPosDevice ? AppColors.success : Colors.grey[700],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isPosDevice
                          ? 'เครื่อง POS (มีสิทธิ์ขายและบันทึกเงินสด)'
                          : 'โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isPosDevice ? AppColors.success : Colors.grey[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AppTextField(
              label: 'ชื่อผู้ใช้ (Username)',
              hint: 'กรอกชื่อผู้ใช้',
              controller: _usernameController,
              autofocus: true,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            AppTextField(
              label: 'รหัสผ่าน (Password)',
              hint: 'กรอกรหัสผ่าน',
              controller: _passwordController,
              obscureText: true,
              enabled: !_busy,
              errorText: _errorMessage,
              textInputAction: TextInputAction.done,
              onSubmitted: _submit,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('ยกเลิก'),
        ),
        AppButton(
          label: 'เข้าสู่ระบบ',
          onPressed: _busy ? null : _submit,
          busy: _busy,
        ),
      ],
    );
  }
}
