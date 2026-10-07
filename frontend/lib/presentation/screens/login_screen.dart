// LoginScreen — the signed-out route (#143), registered only on the API build
// (`USE_API_WRITES`). The router's redirect brings every signed-out request
// here and takes a successful login back to the route that was asked for, so
// this screen navigates nowhere itself.
//
// 🔴 No dialog, no banner, on arrival. A refused refresh at 04:00 lands here via
// AuthCubit.sessionExpired with a null errorMessage (#54 AC3): the counter needs
// the form, not an explanation of token lifetimes. The only error this screen
// ever shows is the one from its own login attempt, inside the form.
//
// Strings: every one was already in LoginDialog / DeviceEnrolmentDialog /
// SrisurartApp before this screen existed — none is new.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/auth_cubit.dart';
import '../widgets/device_enrolment_dialog.dart';
import '../widgets/login_form.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthCubit>().state;
    // Only the boot read of the stored session gets a spinner. AuthLoading
    // (a login in flight) must keep the form mounted, or the attempt's own
    // refusal would have no widget left to show it in.
    final booting = authState is AuthInitial;
    // Unknown while a login is in flight (AuthLoading): offer nothing then.
    final offerEnrolment =
        authState is Unauthenticated && !authState.hasDeviceEnrolled;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: booting
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.lock_outline,
                                  color: AppColors.orange,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  // #443 PR3: LoginForm has swapped to the
                                  // change-password form (owner-ratified 2026-10-07).
                                  authState is AuthPasswordChangeRequired
                                      ? 'ตั้งรหัสผ่านใหม่'
                                      : 'เข้าสู่ระบบ',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Srisurart POS',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.steelBlue,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const LoginForm(),
                            // ADR-0004: a fresh machine has no device token,
                            // and enrolment must be reachable before anyone is
                            // signed in. An enrolled machine does not offer it
                            // again — rebinding is Settings' job, after login.
                            if (offerEnrolment) ...[
                              const Divider(height: 32),
                              TextButton.icon(
                                onPressed: () =>
                                    DeviceEnrolmentDialog.show(context),
                                icon: const Icon(Icons.devices),
                                label: const Text(
                                  'ผูกเครื่องขาย (POS Terminal)',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
