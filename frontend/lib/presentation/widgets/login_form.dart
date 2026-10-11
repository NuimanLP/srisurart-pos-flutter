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
import 'change_password_form.dart';
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
    // Tell the browser the sign-in worked, so its password manager saves this
    // password (and not, say, a temporary one it captured earlier). Before the
    // mounted check: a success redirects away and unmounts the form.
    if (success) TextInput.finishAutofillContext();

    // On the login route a success redirects away and unmounts this form.
    if (!mounted) return;

    if (success) {
      widget.onSuccess?.call();
    } else {
      final state = cubit.state;
      setState(() {
        _busy = false;
        // #443 PR3: a temporary password is not a refusal — build() swaps to
        // the change-password form, with no error line.
        if (state is AuthPasswordChangeRequired) return;
        _errorMessage = (state is Unauthenticated)
            ? state.errorMessage ?? 'เข้าสู่ระบบไม่สำเร็จ'
            : 'เข้าสู่ระบบไม่สำเร็จ';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthCubit>().state;
    if (authState is AuthPasswordChangeRequired) {
      return ChangePasswordForm(onSuccess: widget.onSuccess);
    }
    // #465c: `isPos` only ever becomes true from an access token's `drole`
    // claim (Authenticated) or the role recorded at a PAST online login
    // (Unauthenticated's fallback) — `POST /auth/device` (enrol) never learns
    // the device's role at all; only an actual `POST /auth/token` login does
    // (server resolves `did`/`drole` there). So right after a fresh enrol,
    // `isPos` is still whatever it was from the LAST session (often false, or
    // some other device's role) even though this browser just stored a brand
    // new device token. The old banner used `isPos` alone and so kept saying
    // "ยังไม่ได้ผูกเครื่อง POS" (POS not bound yet) for an already-enrolled
    // device until the next login.
    // AuthLoading (a login in flight) carries the device as it was when the
    // login started. Reading it as "not pos" flipped an enrolled till's chip to
    // `โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)` for the length of every login.
    final isPos = switch (authState) {
      Authenticated() => authState.isPos,
      Unauthenticated() => authState.isPos,
      AuthLoading() => authState.isPos,
      _ => false,
    };
    // The stale-banner gap only exists between a successful enrol and the
    // NEXT login: `Unauthenticated.hasDeviceEnrolled` is derived from the
    // stored device token (set the moment `AuthCubit.enrolDevice` succeeds),
    // so `!isPos` there is genuinely "role not confirmed yet", not "not pos".
    // Once actually `Authenticated`, `isPos` already came from THIS session's
    // own login-confirmed `drole` — there is no gap to bridge, so this must
    // never touch the Authenticated branch (a confirmed, logged-in backoffice
    // device must keep the plain "not pos" wording, not an "unconfirmed" one).
    final hasUnconfirmedEnrolment = !isPos &&
        switch (authState) {
          Unauthenticated() => authState.hasDeviceEnrolled,
          AuthLoading() => authState.hasDeviceEnrolled,
          _ => false,
        };
    final pinRepo = context.read<OfflinePinRepository>();

    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        _Notice(
          tone: isPos ? _NoticeTone.success : _NoticeTone.neutral,
          icon: isPos ? Icons.point_of_sale : Icons.computer,
          text: isPos
              ? 'เครื่อง POS (มีสิทธิ์ขายและบันทึกเงินสด)'
              : hasUnconfirmedEnrolment
                  // #465c เจ้าของโปรเจกต์รับรอง 2026-10-07 — เครื่องผูกกับ
                  // ร้านแล้วจริง แต่ role (pos/backoffice) ยังไม่ทราบจนกว่าจะ
                  // เข้าสู่ระบบสำเร็จครั้งแรก จึงเลี่ยงข้อความเดิมที่อ้างว่า
                  // "ยังไม่ได้ผูกเครื่อง POS" ซึ่งไม่จริงอีกต่อไป
                  ? 'ผูกเครื่องกับร้านแล้ว รอเข้าสู่ระบบเพื่อยืนยันสิทธิ์การใช้งาน'
                  : 'โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)',
        ),
        const SizedBox(height: 16),

        // If online: standard username/password only (08 §13: ออนไลน์ → ไม่มีตัวเลือก PIN)
        if (!isDegraded) ...[
          _buildOnlineForm(),
        ] else ...[
          // Degraded mode: check offline PIN eligibility (08 §13, F5, C5)
          FutureBuilder<_PinFormEligibility>(
            future: _checkEligibility(pinRepo, isPos),
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
                    const _Notice(
                      tone: _NoticeTone.warning,
                      icon: Icons.timer_off,
                      text:
                          'ไม่สามารถใช้ PIN ออฟไลน์ได้เนื่องจากเกินกำหนด 3 วัน กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบใหม่',
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
                    const _Notice(
                      tone: _NoticeTone.danger,
                      icon: Icons.lock,
                      text:
                          'รหัส PIN ถูกล็อกเนื่องจากใส่ผิดครบ 5 ครั้ง กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบด้วยรหัสผ่านหลัก',
                    ),
                    const SizedBox(height: 16),
                    _buildOnlineForm(),
                  ],
                );
              }

              // Degraded + not configured
              if (!eligibility.isConfigured || !isPos) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Notice(
                      tone: _NoticeTone.neutral,
                      icon: Icons.info_outline,
                      text:
                          'เครื่องนี้ยังไม่ได้ตั้งค่า PIN ออฟไลน์ กรุณาเชื่อมต่ออินเทอร์เน็ตเพื่อเข้าสู่ระบบ',
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

  /// The submit button, alone and full width on the login route; right-aligned
  /// after ยกเลิก in the dialog (Wrap: the pair stacks when zoom leaves no room).
  Widget _actions(Widget submit) {
    if (widget.onCancel == null) return submit;
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: _busy ? null : widget.onCancel,
          child: const Text('ยกเลิก'),
        ),
        submit,
      ],
    );
  }

  Widget _buildPinForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Notice(
          tone: _NoticeTone.accent,
          icon: Icons.offline_bolt,
          text:
              'โหมดออฟไลน์: เข้าสู่ระบบหน้าร้านด้วย PIN 4-6 หลัก เพื่อขายของและบันทึกรายการ',
        ),
        const SizedBox(height: 16),
        AppTextField(
          label: 'รหัส PIN ออฟไลน์ (4-6 หลัก)',
          hint: 'กรอกรหัส PIN',
          controller: _pinController,
          obscureText: true,
          isPin: true,
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
        _actions(
          AppButton(
            label: 'เข้าสู่ระบบ (PIN ออฟไลน์)',
            icon: Icons.login,
            onPressed: _busy ? null : _submitPin,
            busy: _busy,
            fullWidth: widget.onCancel == null,
          ),
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
    // Disposed without a success (a refusal, or a temporary password swapping
    // in the change form) must not save anything — only _submit commits.
    return AutofillGroup(
      onDisposeAction: AutofillContextAction.cancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            label: 'ชื่อผู้ใช้ (Username)',
            hint: 'กรอกชื่อผู้ใช้',
            controller: _usernameController,
            autofocus: true,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: 12),
          AppTextField(
            label: 'รหัสผ่าน (Password)',
            hint: 'กรอกรหัสผ่าน',
            controller: _passwordController,
            obscureText: true,
            enabled: !_busy,
            autofillHints: const [AutofillHints.password],
            errorText: _errorMessage,
            textInputAction: TextInputAction.done,
            onSubmitted: _submit,
          ),
          const SizedBox(height: 20),
          _actions(
            AppButton(
              label: 'เข้าสู่ระบบ',
              icon: Icons.login,
              onPressed: _busy ? null : _submit,
              busy: _busy,
              fullWidth: widget.onCancel == null,
            ),
          ),
        ],
      ),
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

enum _NoticeTone { success, neutral, warning, danger, accent }

/// One status line above the login fields (device role, PIN expired / locked /
/// not set up, offline mode). Colours come from the theme tokens and switch
/// with brightness — the old hard-coded greys/brown were dark-on-dark and
/// unreadable in the dark theme.
class _Notice extends StatelessWidget {
  const _Notice({required this.tone, required this.icon, required this.text});

  final _NoticeTone tone;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final (Color base, Color fg) = switch (tone) {
      _NoticeTone.success => (
        AppColors.success,
        dark ? AppColors.successLight : AppColors.forestGreen,
      ),
      _NoticeTone.neutral => (
        AppColors.steelBlue,
        theme.colorScheme.onSurfaceVariant,
      ),
      _NoticeTone.warning => (
        AppColors.warning,
        dark ? AppColors.warningTextOnDark : AppColors.warningText,
      ),
      _NoticeTone.danger => (
        AppColors.error,
        dark ? AppColors.errorTextOnDark : AppColors.error,
      ),
      _NoticeTone.accent => (AppColors.orange, theme.colorScheme.onSurface),
    };
    final iconColor = tone == _NoticeTone.accent ? AppColors.orange : fg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: base.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
