// ApiSalePhotosRepository — the HTTP side of SalePhotosRepository
// (docs/Backend_design/10_SALE_PHOTO_EVIDENCE.md §4). The interface, the model
// and SalePhotoException live in sale_photos_repository.dart.
//
// Every failure leaves here as a SalePhotoException; an ApiException never
// reaches a screen. Only a 4xx is a verdict (401 included: ApiClient has already
// refreshed once, so a retry cannot succeed); a 5xx, 429, 503 IN_FLIGHT and a
// lost or timed-out reply are "retry with the same id + key".

import 'dart:typed_data';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/network/transport_failure.dart';
import '../db/database.dart';
import '../sync/outbox_ledger_refs.dart';
import 'api/api_wire.dart';
import 'sale_photos_repository.dart';

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
    return rows.any(
      (r) => outboxAggregatesInclude(r.aggregates, 'sale:$saleId'),
    );
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
      final retryable = !isVerdict(e);
      final message = e.code == 'SALE_NOT_FOUND'
          ? saleNotFoundMessage
          // The existing session message: a 401 here means the session ended.
          : e.statusCode == 401
          ? ServerErrorResolver.resolve('UNAUTHENTICATED')
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
