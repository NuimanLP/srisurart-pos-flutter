// PasswordChangedBanner — "รหัสผ่านถูกเปลี่ยนเมื่อ …" (#443 PR3, v2 condition 7).
//
// A platform admin can reset an owner's password (a forgotten one, or one
// suspected leaked). That must never go unnoticed: every device that signs in
// afterwards shows when the password last changed, so a reset nobody at the
// shop asked for is visible. The time comes from the login response's
// `passwordChangedAt`; the banner shows while it is within [window] and until
// the person dismisses it for this session.
//
// Strings: agent ร่าง (02_API_SCREENS.md §8.1) — not yet ratified.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/auth_cubit.dart';
import 'thai_format.dart';

class PasswordChangedBanner extends StatefulWidget {
  const PasswordChangedBanner({super.key, this.now});

  /// How recent a change still gets the banner. Agent's choice (7 days) —
  /// an open owner question.
  static const Duration window = Duration(days: 7);

  static String message(DateTime changedAt) =>
      'รหัสผ่านถูกเปลี่ยนเมื่อ ${thaiDateTime(changedAt)} ถ้าไม่ใช่คุณ กรุณาติดต่อทีมงานทันที';
  static const String dismiss = 'รับทราบ';

  /// Clock seam for tests.
  final DateTime Function()? now;

  @override
  State<PasswordChangedBanner> createState() => _PasswordChangedBannerState();
}

class _PasswordChangedBannerState extends State<PasswordChangedBanner> {
  DateTime? _dismissedFor;

  @override
  Widget build(BuildContext context) {
    AuthCubit? cubit;
    try {
      cubit = context.read<AuthCubit>();
    } catch (_) {
      cubit = null;
    }
    if (cubit == null) return const SizedBox.shrink();

    return BlocBuilder<AuthCubit, AuthState>(
      bloc: cubit,
      builder: (context, state) {
        final changedAt =
            state is Authenticated ? state.passwordChangedAt : null;
        final now = (widget.now ?? DateTime.now)();
        if (changedAt == null ||
            changedAt == _dismissedFor ||
            now.difference(changedAt) > PasswordChangedBanner.window) {
          return const SizedBox.shrink();
        }
        return MaterialBanner(
          leading: const Icon(Icons.warning_amber_rounded),
          content: Text(PasswordChangedBanner.message(changedAt)),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _dismissedFor = changedAt;
                });
              },
              child: const Text(PasswordChangedBanner.dismiss),
            ),
          ],
        );
      },
    );
  }
}
