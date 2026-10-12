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

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../db/database.dart';
import 'api/api_wire.dart';

/// The two stored sizes: thumbnail 256 px, preview 1024 px (`t` / `p`).
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

class ApiSalePhotosRepository implements SalePhotosRepository {
  ApiSalePhotosRepository(this.db, this.apiClient);

  final AppDatabase db;
  final ApiClient apiClient;

  /// `SALE_NOT_FOUND` on these routes means the server has no such bill.
  static const saleNotFoundMessage = 'ไม่พบบิลนี้บนเซิร์ฟเวอร์'; // agent ร่าง

  static String _base(String saleId) => '/api/v1/sales/$saleId/photos';

  @override
  Future<SalePhoto> upload({
    required String saleId,
    required String photoId,
    required String idempotencyKey,
    required Uint8List bytes,
    required DateTime takenAt,
    required int sortOrder,
    String contentType = 'image/jpeg',
  }) async {
    final res = await _call(
      () => apiClient.sendBytes(
        'PUT',
        '${_base(saleId)}/$photoId',
        bytes,
        contentType: contentType,
        headers: {'Idempotency-Key': idempotencyKey},
        queryParameters: {
          'takenAt': DateTime.fromMillisecondsSinceEpoch(
            takenAt.millisecondsSinceEpoch,
            isUtc: true,
          ).toIso8601String(),
          'sortOrder': '$sortOrder',
        },
      ),
    );
    return _parse(() => SalePhoto.fromJson(res as Map));
  }

  @override
  Future<List<SalePhoto>> list(String saleId) async {
    final res = await _call(() => apiClient.get(_base(saleId)));
    return _parse(
      () => [for (final j in res as List) SalePhoto.fromJson(j as Map)],
    );
  }

  @override
  Future<Uint8List> bytes(
    String saleId,
    String photoId,
    SalePhotoVariant variant,
  ) => _call(
    () => apiClient.getBytes('${_base(saleId)}/$photoId/${variant.wire}'),
  );

  @override
  Future<bool> hasPendingSaleCreate(String saleId) async {
    final rows = await (db.select(
      db.outboxOps,
    )..where((t) => t.type.equals('sale.create'))).get();
    return rows.any((r) => r.aggregates.contains('"sale:$saleId"'));
  }

  /// A 2xx whose body is not the documented shape: the server answered, so
  /// retrying with the same id + key is safe (replay).
  T _parse<T>(T Function() read) {
    try {
      return read();
    } catch (_) {
      final u = unreadableResponse();
      throw SalePhotoException(u.code, u.message, retryable: true);
    }
  }

  Future<T> _call<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on ApiException catch (e) {
      final retryable = !isVerdict(e) || e.statusCode == 401;
      final message = e.code == 'SALE_NOT_FOUND'
          ? saleNotFoundMessage
          : posExceptionFromApi(e).message;
      throw SalePhotoException(e.code, message, retryable: retryable);
    } catch (e) {
      if (isTransportFailure(e)) {
        throw SalePhotoException(
          'NETWORK_ERROR',
          ServerErrorResolver.resolve(null),
          retryable: true,
        );
      }
      rethrow;
    }
  }
}
