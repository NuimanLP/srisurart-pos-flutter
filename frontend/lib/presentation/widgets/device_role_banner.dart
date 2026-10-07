// NotPosDeviceBanner — #476: says up front that this session cannot sell or
// open a shift, and where to fix it.
//
// Only a session signed for a `pos` device may ring a sale or open a shift
// (ADR-0004, `RequireDeviceRole('pos')` → 403 DEVICE_ROLE_FORBIDDEN). A
// browser whose site data was cleared signs in again as a plain session with
// no device, and used to learn that only from a failed press — first as
// "กรุณาเปิดกะก่อนขาย" (no shift could ever be opened), then as
// "เครื่องนี้ขายของไม่ได้" with no next step. The banner, the pre-check
// [isNotPosSession] and the refusal dialog all send the counter to `/devices`,
// where "ผูกเครื่องนี้" enrols the browser.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/pos_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../blocs/auth_cubit.dart';

/// Ratified by the owner 2026-10-03 (#476, PR #567, 02_API_SCREENS.md §8.1.1).
const String notPosDeviceMessage =
    'เครื่องนี้ยังไม่ได้ลงทะเบียนเป็นเครื่องขาย (POS) — ลงทะเบียนเครื่องที่หน้าจัดการเครื่อง';

/// Ratified by the owner 2026-10-03 (#476, PR #567, 02_API_SCREENS.md §8.1.1).
const String goToDevicesLabel = 'ไปหน้าจัดการเครื่อง';

/// The [AuthCubit] above [context], or null where none is provided (the
/// Drift-only build's tests, and screen tests that never sign in).
AuthCubit? _authCubitOf(BuildContext context) {
  try {
    return BlocProvider.of<AuthCubit>(context, listen: false);
  } catch (_) {
    return null;
  }
}

bool _isNotPos(AuthState s) => s is Authenticated && !s.isPosSession;

/// True when someone is signed in with a session the server will refuse a
/// sale or a shift for. False when nobody is signed in — the Drift-only build
/// never signs in and sells locally.
bool isNotPosSession(BuildContext context) {
  final cubit = _authCubitOf(context);
  return cubit != null && _isNotPos(cubit.state);
}

/// The server's own device-role refusal, as a repository rethrows it.
bool isDeviceRoleRefusal(Object e) =>
    e is PosException && e.code == 'DEVICE_ROLE_FORBIDDEN';

/// [notPosDeviceMessage] in a dialog with a button to `/devices`.
Future<void> showNotPosDeviceDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: const Text(notPosDeviceMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('ตกลง'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            context.go(AppRoutes.devices);
          },
          child: const Text(goToDevicesLabel),
        ),
      ],
    ),
  );
}

/// A persistent strip shown while [isNotPosSession] holds; nothing otherwise.
class NotPosDeviceBanner extends StatelessWidget {
  const NotPosDeviceBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = _authCubitOf(context);
    if (cubit == null) return const SizedBox.shrink();
    return BlocBuilder<AuthCubit, AuthState>(
      bloc: cubit,
      builder: (context, state) {
        if (!_isNotPos(state)) return const SizedBox.shrink();
        return Material(
          color: AppColors.error.withValues(alpha: 0.08),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.error.withValues(alpha: 0.3),
                ),
              ),
            ),
            // Wrap: the button drops under the sentence at phone width.
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.point_of_sale, color: AppColors.error, size: 20),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        notPosDeviceMessage,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: () => context.go(AppRoutes.devices),
                  icon: const Icon(Icons.devices, size: 18),
                  label: const Text(goToDevicesLabel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
