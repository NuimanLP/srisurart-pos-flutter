// A product's picture (owner request 2026-10-10, contract §5) — the sell-screen
// card thumbnail, the preview dialog and the products-screen editor.
//
// Plain `Image.network`, no disk cache package: on Android/iOS its
// `NetworkImage` fetches through `HttpClient()`, which honours the
// `HttpOverrides.global` that `installPosTrust()` sets in `main()` before any
// image loads — so a picture from mob04 is verified against the bundled
// private CA exactly like every `ApiClient` call (no badCertificateCallback;
// product_image_trust_test.dart). On the web the browser owns TLS and its HTTP
// cache keeps the `immutable` URLs. Decoded pictures stay in Flutter's
// in-memory `ImageCache`.
//
// No URL, still loading, or a failed load all show the same neutral
// placeholder — never an error.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class ProductImage extends StatelessWidget {
  const ProductImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.iconSize = 36,
  });

  /// Null = no picture: the placeholder, and no request at all.
  final String? url;
  final BoxFit fit;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final placeholder = ProductImagePlaceholder(iconSize: iconSize);
    final src = url;
    if (src == null) return placeholder;
    return LayoutBuilder(
      builder: (context, box) {
        // Decode at the displayed size (Android/iOS; the web ignores it).
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
        final cacheWidth = !kIsWeb && box.hasBoundedWidth
            ? (box.maxWidth * dpr).round()
            : null;
        return Image.network(
          src,
          key: ValueKey(src),
          fit: fit,
          width: box.hasBoundedWidth ? box.maxWidth : null,
          height: box.hasBoundedHeight ? box.maxHeight : null,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSyncLoaded) =>
              frame == null && !wasSyncLoaded ? placeholder : child,
          errorBuilder: (context, error, stack) => placeholder,
        );
      },
    );
  }
}

/// A neutral picture icon on a tinted background.
class ProductImagePlaceholder extends StatelessWidget {
  const ProductImagePlaceholder({super.key, this.iconSize = 36});

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      key: const Key('product-image-placeholder'),
      color: isDark
          ? AppColors.navyDeep.withValues(alpha: 0.6)
          : AppColors.gray100,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: iconSize,
          color: AppColors.steelBlue.withValues(alpha: isDark ? 0.5 : 0.6),
        ),
      ),
    );
  }
}
