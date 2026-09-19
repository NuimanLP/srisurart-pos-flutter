// OfflinePinSetupDialog — Dialog to configure or change the offline POS PIN (08 §13, C4).
//
// Invariants:
// - Online only: disabled/not reachable in degraded mode.
// - Compares PIN != password in memory and rejects immediately if equal.
// - Verifies password online via POST /auth/token, then clears password from memory.
// - Derives slow salted hash bound to deviceId and saves to Drift AppMeta.
// - PIN or PIN hash is NEVER sent to server.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/offline_pin_repository.dart';
import '../blocs/auth_cubit.dart';
import 'app_button.dart';
import 'app_text_field.dart';

class OfflinePinSetupDialog extends StatefulWidget {
  const OfflinePinSetupDialog({super.key, this.onSuccess});

  final VoidCallback? onSuccess;

  static Future<void> show(BuildContext context, {VoidCallback? onSuccess}) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => OfflinePinSetupDialog(onSuccess: onSuccess),
    );
  }

  @override
  State<OfflinePinSetupDialog> createState() => _OfflinePinSetupDialogState();
}

class _OfflinePinSetupDialogState extends State<OfflinePinSetupDialog> {
  final _passwordController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  bool _busy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    final pin = _pinController.text.trim();
    final confirmPin = _confirmPinController.text.trim();

    if (password.isEmpty || pin.isEmpty || confirmPin.isEmpty) {
      setState(() {
        _errorMessage = 'กรุณากรอกข้อมูลให้ครบถ้วนทุกช่อง';
      });
      return;
    }

    // Invariant C4: Compare in memory before any network request.
    if (pin == password) {
      setState(() {
        _errorMessage = 'รหัส PIN ต้องไม่ตรงกับรหัสผ่านของบัญชี';
      });
      return;
    }

    if (pin.length < 4 || pin.length > 6) {
      setState(() {
        _errorMessage = 'รหัส PIN ต้องเป็นตัวเลข 4-6 หลัก';
      });
      return;
    }

    if (pin != confirmPin) {
      setState(() {
        _errorMessage = 'รหัส PIN และการยืนยันไม่ตรงกัน';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final authState = context.read<AuthCubit>().state;
      final authRepo = context.read<AuthRepository>();
      final offlinePinRepo = context.read<OfflinePinRepository>();

      final user = authState is Authenticated ? authState.user : null;
      if (user == null) {
        throw StateError('ต้องเข้าสู่ระบบก่อนจึงจะสามารถตั้งค่า PIN ได้');
      }

      final deviceToken = await authRepo.getDeviceToken();
      final deviceId = await authRepo.getDeviceId();

      if (deviceId == null || deviceId.isEmpty) {
        throw StateError('ไม่พบรหัสประจำเครื่อง POS กรุณาผูกเครื่องก่อน');
      }

      await offlinePinRepo.setPin(
        password: password,
        newPin: pin,
        username: user.username,
        deviceId: deviceId,
        deviceToken: deviceToken,
        user: user,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSuccess?.call();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('บันทึกรหัส PIN ออฟไลน์เรียบร้อยแล้ว'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e is ApiException && e.statusCode == 401) {
          _errorMessage = 'รหัสผ่านบัญชีไม่ถูกต้อง';
        } else if (e is ArgumentError) {
          _errorMessage = e.message?.toString() ?? 'ข้อมูลไม่ถูกต้อง';
        } else {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.pin, color: AppColors.orange),
          SizedBox(width: 8),
          Text(
            'ตั้งค่ารหัส PIN ออฟไลน์',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.navy.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppColors.navy.withValues(alpha: 0.2),
                  ),
                ),
                child: const Text(
                  'PIN ออฟไลน์ช่วยให้แคชเชียร์ขายของหน้าร้านได้ต่อเนื่องเมื่ออินเทอร์เน็ตหลุด โดยมีอายุ 3 วันนับจากที่ล็อกอินออนไลน์ครั้งล่าสุด และต้องไม่ตรงกับรหัสผ่านหลักของร้าน',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
              const SizedBox(height: 16),
              AppTextField(
                label: 'รหัสผ่านบัญชีร้านปัจจุบัน (Password)',
                hint: 'กรอกรหัสผ่านเพื่อยืนยันตัวตน',
                controller: _passwordController,
                obscureText: true,
                enabled: !_busy,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              AppTextField(
                label: 'รหัส PIN ออฟไลน์ใหม่ (4-6 หลัก)',
                hint: 'ตัวเลข 4-6 หลัก (ห้ามซ้ำกับรหัสผ่าน)',
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                enabled: !_busy,
              ),
              const SizedBox(height: 12),
              AppTextField(
                label: 'ยืนยันรหัส PIN ออฟไลน์ใหม่อีกครั้ง',
                hint: 'กรอกรหัส PIN เดิมซ้ำ',
                controller: _confirmPinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                enabled: !_busy,
                errorText: _errorMessage,
                onSubmitted: _submit,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('ยกเลิก'),
        ),
        AppButton(
          label: 'บันทึก PIN',
          icon: Icons.check,
          onPressed: _busy ? null : _submit,
          busy: _busy,
        ),
      ],
    );
  }
}
