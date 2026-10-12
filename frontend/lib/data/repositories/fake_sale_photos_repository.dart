// FakeSalePhotosRepository — an in-memory server that follows
// 10_SALE_PHOTO_EVIDENCE.md §4.3/§4.4 for the tests of the photo sheet and strip
// (the real server is built in parallel). Not wired anywhere in the app.
//
// Rules it mirrors: a replay of a photoId with the same bytes answers the stored
// row (200); the same photoId with other bytes is 409 CLIENT_ID_REUSED; a sixth
// photo is 409 SALE_PHOTO_LIMIT; sortOrder outside 0–4 is 400 BAD_REQUEST.
// [failures] scripts errors: each upload first takes the next entry (null = let
// this call through), so a test can say "5xx once, then succeed".

import 'dart:typed_data';

import 'sale_photos_repository.dart';

class FakeUploadCall {
  const FakeUploadCall(this.saleId, this.photoId, this.key, this.sortOrder);
  final String saleId;
  final String photoId;
  final String key;
  final int sortOrder;
}

class FakeSalePhotosRepository implements SalePhotosRepository {
  FakeSalePhotosRepository({this.pendingSaleCreate = false});

  /// What [hasPendingSaleCreate] answers.
  bool pendingSaleCreate;

  /// Scripted outcomes for the next uploads, front first (null = succeed).
  final List<SalePhotoException?> failures = [];

  /// Scripted outcome for [list] / [bytes] while non-null.
  SalePhotoException? readFailure;

  /// Every upload attempt, in order, including failed ones.
  final List<FakeUploadCall> calls = [];

  final Map<String, List<(SalePhoto, Uint8List)>> _store = {};

  /// A server-side 5xx / lost reply.
  static const serverDown = SalePhotoException(
    'INTERNAL_ERROR',
    'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์',
    retryable: true,
  );

  /// A 4xx verdict such as SALE_PHOTO_LIMIT.
  static const limit = SalePhotoException(
    'SALE_PHOTO_LIMIT',
    'บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว',
    retryable: false,
  );

  /// Puts a photo on the "server" without going through [upload].
  void seed(String saleId, SalePhoto photo, Uint8List bytes) =>
      (_store[saleId] ??= []).add((photo, bytes));

  List<SalePhoto> stored(String saleId) => [
    for (final e in _store[saleId] ?? const []) e.$1,
  ];

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
    calls.add(FakeUploadCall(saleId, photoId, idempotencyKey, sortOrder));
    if (failures.isNotEmpty) {
      final f = failures.removeAt(0);
      if (f != null) throw f;
    }
    if (sortOrder < 0 || sortOrder > 4) {
      throw const SalePhotoException(
        'BAD_REQUEST',
        'ข้อมูลไม่ถูกต้อง',
        retryable: false,
      );
    }
    final rows = _store[saleId] ??= [];
    for (final (p, b) in rows) {
      if (p.id != photoId) continue;
      if (_same(b, bytes)) return p;
      throw const SalePhotoException(
        'CLIENT_ID_REUSED',
        'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
        retryable: false,
      );
    }
    if (rows.length >= 5) throw limit;
    final photo = SalePhoto(
      id: photoId,
      saleId: saleId,
      sortOrder: sortOrder,
      width: 1600,
      height: 1200,
      takenAt: takenAt,
      createdAt: DateTime.now(),
    );
    rows.add((photo, bytes));
    return photo;
  }

  @override
  Future<List<SalePhoto>> list(String saleId) async {
    final f = readFailure;
    if (f != null) throw f;
    final out = stored(saleId)
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
    return out;
  }

  @override
  Future<Uint8List> bytes(
    String saleId,
    String photoId,
    SalePhotoVariant variant,
  ) async {
    final f = readFailure;
    if (f != null) throw f;
    for (final (p, b) in _store[saleId] ?? const <(SalePhoto, Uint8List)>[]) {
      if (p.id == photoId) return b;
    }
    throw const SalePhotoException(
      'NOT_FOUND',
      'ไม่พบข้อมูล',
      retryable: false,
    );
  }

  @override
  Future<bool> hasPendingSaleCreate(String saleId) async => pendingSaleCreate;

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
