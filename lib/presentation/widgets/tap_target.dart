// TapTarget — guarantees a comfortable (≥44dp) touch area around a compact
// visual control without changing how big that control looks.
//
// Material's recommended minimum touch target is 44–48dp. Several POS controls
// (cart qty +/-, return step buttons, price-reset, icon chips) are visually
// small — fine on a mouse, fiddly with gloves on a workshop tablet/phone. Wrap
// the small visual in a TapTarget so the hit region meets the minimum while the
// child keeps its size, centered inside the larger gesture box.

import 'package:flutter/material.dart';

class TapTarget extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double minSize;
  final BorderRadius? borderRadius;

  const TapTarget({
    super.key,
    required this.child,
    required this.onTap,
    this.minSize = 44,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: borderRadius ?? BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
      ),
    );
  }
}
