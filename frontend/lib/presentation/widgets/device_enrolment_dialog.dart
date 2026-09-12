// DeviceEnrolmentDialog — Dialog to bind a hardware terminal using an enrolment code (ADR-0004).

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/auth_cubit.dart';
import 'app_button.dart';
import 'app_text_field.dart';

class DeviceEnrolmentDialog extends StatefulWidget {
  const DeviceEnrolmentDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DeviceEnrolmentDialog(),
    );
  }

  @override
  State<DeviceEnrolmentDialog> createState() => _DeviceEnrolmentDialogState();
}

class _DeviceEnrolmentDialogState extends State<DeviceEnrolmentDialog> {
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'กรุณากรอกรหัสผูกเครื่อง';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    final cubit = context.read<AuthCubit>();
    final success = await cubit.enrolDevice(code);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ผูกเครื่องสำเร็จ! เครื่องนี้ได้รับการตั้งค่าเป็น POS Terminal แล้ว'),
          backgroundColor: AppColors.success,
        ),
      );
    } else {
      setState(() {
        _busy = false;
        _errorMessage = 'รหัสผูกเครื่องไม่ถูกต้อง หรือหมดอายุแล้ว';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.devices, color: AppColors.orange),
          SizedBox(width: 8),
          Text('ผูกเครื่องขาย (POS Terminal)'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'กรอกรหัสผูกเครื่องที่เจ้าของร้านออกให้จากระบบ เพื่อเปิดสิทธิ์การขายและบันทึกเงินสดหน้าร้าน (ADR-0004)',
              style: TextStyle(fontSize: 13, color: AppColors.steelBlue),
            ),
            const SizedBox(height: 16),
            AppTextField(
              label: 'รหัสผูกเครื่อง (Enrolment Code)',
              hint: 'เช่น POS-ABCD หรือรหัส 6 หลัก',
              controller: _codeController,
              autofocus: true,
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
          label: 'ยืนยันผูกเครื่อง',
          onPressed: _busy ? null : _submit,
          busy: _busy,
        ),
      ],
    );
  }
}
