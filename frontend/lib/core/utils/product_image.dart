// Product image URLs (owner request 2026-10-10, contract §2/§5).
//
// Nginx serves each product's picture straight from the `product-images`
// volume at `/img/<tenantId>/<imageKey>_t.webp` (thumbnail, ≤256 px) and
// `_p.webp` (preview, ≤1024 px): public, unguessable (UUID + 128-bit content
// hash), `immutable`. The client only builds the URL; the bytes are never
// stored in Drift.

final _imageKey = RegExp(r'^[0-9a-f]{32}$');
final _tenantId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Builds image URLs for one shop. [baseUrl] is `ApiClient.baseUrl` — empty
/// on the web build, where the app and `/img/` share one origin and a
/// relative URL is what the browser should fetch.
class ProductImageUrls {
  const ProductImageUrls({required this.baseUrl, required this.tenantId});

  final String baseUrl;
  final String tenantId;

  /// The card thumbnail, or null when there is no (well-formed) key.
  String? thumb(String? imageKey) => productImageUrl(
        baseUrl: baseUrl,
        tenantId: tenantId,
        imageKey: imageKey,
      );

  /// The preview-dialog picture, or null when there is no (well-formed) key.
  String? preview(String? imageKey) => productImageUrl(
        baseUrl: baseUrl,
        tenantId: tenantId,
        imageKey: imageKey,
        preview: true,
      );
}

/// `<baseUrl>/img/<tenantId>/<imageKey>_t.webp` (`_p` when [preview]), or
/// null when either id is missing or not the server's exact shape — a key
/// from the wire is never put into a path unchecked. The tenant id is
/// lowercased first: nginx's `/img/` regex (and the volume) only know the
/// lowercase form.
String? productImageUrl({
  required String baseUrl,
  required String? tenantId,
  required String? imageKey,
  bool preview = false,
}) {
  tenantId = tenantId?.toLowerCase();
  if (tenantId == null || !_tenantId.hasMatch(tenantId)) return null;
  if (imageKey == null || !_imageKey.hasMatch(imageKey)) return null;
  final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/img/$tenantId/${imageKey}_${preview ? 'p' : 't'}.webp';
}
