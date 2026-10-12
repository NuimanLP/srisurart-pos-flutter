// SalePhotosRepository — the photo evidence of a sale (docs/Backend_design/
// 10_SALE_PHOTO_EVIDENCE.md §4). API build only, online only: the bytes live on
// the server, nothing about them is written to Drift.
//
//  • upload — `PUT /sales/:saleId/photos/:photoId` with the raw JPEG. The CALLER
//    mints [photoId] and the Idempotency-Key once per photo and passes the same
//    pair on every retry; this class never creates a key (§3.1).
//  • list / bytes — `GET /sales/:saleId/photos` and `…/:photoId/(t|p)`.
//
// Every failure leaves this file as a [SalePhotoException] (a Thai sentence plus
// whether pressing ลองอีกครั้ง can help) — an ApiException never reaches a
// screen. Only a 4xx is a verdict; a 5xx, 429, 503 IN_FLIGHT, a lost or timed-out
// reply is "retry with the same id + key" (§3.1). 401 is retryable too: ApiClient
// has already refreshed once, so it means the session ended.

import 'dart:typed_data';

import '../../core/errors/pos_exception.dart';

/// The two stored sizes: thumbnail 256 px, preview 1600 px (`t` / `p`).
enum SalePhotoVariant {
  thumb('t'),
  preview('p');

  const SalePhotoVariant(this.wire);
  final String wire;
}

/// One stored photo (§4.2).
class SalePhoto {
  const SalePhoto({
    required this.id,
    required this.saleId,
    required this.sortOrder,
    required this.width,
    required this.height,
    required this.takenAt,
    required this.createdAt,
  });

  final String id;
  final String saleId;
  final int sortOrder;
  final int width;
  final int height;

  /// The device clock when the photo was taken (reference only).
  final DateTime takenAt;

  /// When the server first received it.
  final DateTime createdAt;

  factory SalePhoto.fromJson(Map<dynamic, dynamic> j) => SalePhoto(
    id: j['id'] as String,
    saleId: j['saleId'] as String,
    sortOrder: (j['sortOrder'] as num).toInt(),
    width: (j['width'] as num).toInt(),
    height: (j['height'] as num).toInt(),
    takenAt: DateTime.parse(j['takenAt'] as String).toLocal(),
    createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
  );
}

/// A refusal in the Thai sentence the counter reads. [retryable] is false for a
/// 4xx verdict (pressing again gives the same answer; only ✕ helps).
class SalePhotoException extends PosException {
  const SalePhotoException(
    super.code,
    super.message, {
    required this.retryable,
  });

  final bool retryable;
}

abstract class SalePhotosRepository {
  /// Sends one photo. [photoId] and [idempotencyKey] are the caller's: reuse the
  /// same pair when retrying the same photo.
  Future<SalePhoto> upload({
    required String saleId,
    required String photoId,
    required String idempotencyKey,
    required Uint8List bytes,
    required DateTime takenAt,
    required int sortOrder,
    String contentType = 'image/jpeg',
  });

  Future<List<SalePhoto>> list(String saleId);

  Future<Uint8List> bytes(
    String saleId,
    String photoId,
    SalePhotoVariant variant,
  );

  /// True while the sale's `sale.create` is still in the outbox — the server
  /// does not have the bill yet, so a photo cannot be attached (§2.1).
  Future<bool> hasPendingSaleCreate(String saleId);
}
