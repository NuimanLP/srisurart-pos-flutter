// LoginForm — the username/password form shared by LoginDialog (Settings, on
// the Drift build) and LoginScreen (#143, the API build's signed-out route).
//
// Every string here was already in LoginDialog before #143; none is new. A
// refusal shows `Unauthenticated.errorMessage`, which AuthCubit.login builds
// from ServerErrorResolver — the form never words a server error itself.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/offline_pin_repository.dart';
import '../../domain/models/auth_models.dart';
import '../blocs/auth_cubit.dart';
import 'app_button.dart';
import 'app_text_field.dart';
import 'sync_status_builder.dart';

class LoginForm extends StatefulWidget {
  const LoginForm({super.key, this.onSuccess, this.onCancel});

  /// Called after a successful login while the form is still mounted. The
  /// login route passes nothing: its redirect leaves the route by itself.
  final VoidCallback? onSuccess;

  /// Shows a cancel button when given (the dialog); the login route has none.
  final VoidCallback? onCancel;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _pinController = TextEditingController();
  bool _busy = false;
  String? _errorMessage;
  bool _usePin = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() {
        _errorMessage = 'กรุณากรอกรหัส PIN';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    final cubit = context.read<AuthCubit>();
    final result = await cubit.loginWithOfflinePin(pin);

    if (!mounted) return;

    if (result is PinVerifySuccess) {
      widget.onSuccess?.call();
    } else {
      final state = cubit.state;
      setState(() {
        _busy = false;
        _errorMessage = (state is Unauthenticated)
            ? state.errorMessage ?? 'รหัส PIN ไม่ถูกต้อง'
            : 'รหัส PIN ไม่ถูกต้อง';
      });
    }
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

    // On the login route a success redirects away and unmounts this form.
    if (!mounted) return;

    if (success) {
      widget.onSuccess?.call();
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
    final pinRepo = context.read<OfflinePinRepository>();

    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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

        // If online: standard username/password only (08 §13: ออนไลน์ → ไม่มีตัวเลือก PIN)
        if (!isDegraded) ...[
          _buildOnlineForm(),
        ] else ...[
          // Degraded mode: check offline PIN eligibility (08 §13, F5, C5)
          FutureBuilder<_PinFormEligibility>(
            future: _checkEligibility(pinRepo, isPosDevice),
            builder: (context, snapshot) {
              final eligibility = snapshot.data;
              if (eligibility == null) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              // Degraded + > 3 days: NO PIN option (08 §13: refresh ไม่นับ → ไม่มีตัวเลือก)
              if (eligibility.isExpired) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.timer_off, color: Colors.orange, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'ไม่สามารถใช้ PIN ออฟไลน์ได้เนื่องจากเกินกำหนด 3 วัน กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบใหม่',
                              style: TextStyle(fontSize: 12, color: Colors.brown),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildOnlineForm(),
                  ],
                );
              }

              // Degraded + locked
              if (eligibility.isLocked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.lock, color: AppColors.error, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'รหัส PIN ถูกล็อกเนื่องจากใส่ผิดครบ 5 ครั้ง กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบด้วยรหัสผ่านหลัก',
                              style: TextStyle(fontSize: 12, color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildOnlineForm(),
                  ],
                );
              }

              // Degraded + not configured
              if (!eligibility.isConfigured || !isPosDevice) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.grey.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.grey, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'เครื่องนี้ยังไม่ได้ตั้งค่า PIN ออฟไลน์ กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบ',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildOnlineForm(),
                  ],
                );
              }

              // Degraded + valid PIN: offer PIN login mode
              if (_usePin) {
                return _buildPinForm();
              } else {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildOnlineForm(),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton.icon(
                        onPressed: () => setState(() => _usePin = true),
                        icon: const Icon(Icons.pin),
                        label: const Text('เข้าสู่ระบบด้วย PIN ออฟไลน์'),
                      ),
                    ),
                  ],
                );
              }
            },
          ),
        ],
      ],
    );
      },
    );
  }

  Widget _buildPinForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: AppColors.orange.withValues(alpha: 0.3),
            ),
          ),
          child: const Row(
            children: [
              Icon(Icons.offline_bolt, color: AppColors.orange, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'โหมดออฟไลน์: เข้าสู่ระบบหน้าร้านด้วย PIN 4-6 หลัก เพื่อขายของและบันทึกรายการ',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppTextField(
          label: 'รหัส PIN ออฟไลน์ (4-6 หลัก)',
          hint: 'กรอกรหัส PIN',
          controller: _pinController,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          autofocus: true,
          enabled: !_busy,
          errorText: _errorMessage,
          textInputAction: TextInputAction.done,
          onSubmitted: _submitPin,
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.onCancel != null) ...[
              TextButton(
                onPressed: _busy ? null : widget.onCancel,
                child: const Text('ยกเลิก'),
              ),
              const SizedBox(width: 8),
            ],
            AppButton(
              label: 'เข้าสู่ระบบ (PIN ออฟไลน์)',
              icon: Icons.login,
              onPressed: _busy ? null : _submitPin,
              busy: _busy,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _usePin = false),
            child: const Text(
              'เข้าสู่ระบบด้วยชื่อผู้ใช้และรหัสผ่าน',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOnlineForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.onCancel != null) ...[
              TextButton(
                onPressed: _busy ? null : widget.onCancel,
                child: const Text('ยกเลิก'),
              ),
              const SizedBox(width: 8),
            ],
            AppButton(
              label: 'เข้าสู่ระบบ',
              onPressed: _busy ? null : _submit,
              busy: _busy,
            ),
          ],
        ),
      ],
    );
  }

  Future<_PinFormEligibility> _checkEligibility(
    OfflinePinRepository repo,
    bool isPos,
  ) async {
    final configured = await repo.isPinConfigured();
    final locked = await repo.isLocked();
    final expired = await repo.isExpired();
    final available = await repo.isPinAvailable(
      deviceRole: isPos ? 'pos' : null,
    );
    return _PinFormEligibility(
      isConfigured: configured,
      isLocked: locked,
      isExpired: expired,
      isAvailable: available,
    );
  }
}

class _PinFormEligibility {
  const _PinFormEligibility({
    required this.isConfigured,
    required this.isLocked,
    required this.isExpired,
    required this.isAvailable,
  });

  final bool isConfigured;
  final bool isLocked;
  final bool isExpired;
  final bool isAvailable;
}
