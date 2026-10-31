// InstantKeyboardInset — wrap an AlertDialog that holds text fields.
//
// iPad report (2026-10-31): the keyboard hid the field being typed in. A
// Dialog lifts itself above the keyboard by AnimatedPadding (100 ms), but the
// focused field is scrolled into view one frame after the keyboard appears —
// while the dialog is still full height — so once it has shrunk the field
// sits below the visible part. This applies the keyboard inset in the same
// frame and hides it from the dialog. A plain Dialog does the same with
// `insetAnimationDuration: Duration.zero`; AlertDialog has no such parameter.
// Test: test/keyboard_safe_dialogs_test.dart.

import 'package:flutter/widgets.dart';

class InstantKeyboardInset extends StatelessWidget {
  final Widget child;
  const InstantKeyboardInset({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: MediaQuery.viewInsetsOf(context),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeLeft: true,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
        child: child,
      ),
    );
  }
}
