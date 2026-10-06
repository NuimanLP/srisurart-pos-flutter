// DevicesRepository — Client repository for managing shop devices/terminals (ADR-0004, Slice 21).
// Defined in docs/Backend_design/09_PHASE2_LANES.md §3, §88 and 08_PHASE2_SPEC.md §16.

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/device_model.dart';

class DevicesRepository {
  final ApiClient _apiClient;

  DevicesRepository(this._apiClient);

  /// Lists all registered devices for the current tenant.
  ///
  /// A server refusal (4xx) arrives as a [PosException] carrying its code —
  /// the screen tells `DEVICE_ROLE_FORBIDDEN` (no enrolled device in this
  /// session, #558) apart from the rest without touching an [ApiException].
  Future<List<DeviceModel>> listDevices() async {
    final dynamic res;
    try {
      res = await _apiClient.get('/api/v1/devices');
    } on ApiException catch (e) {
      if (e.statusCode < 500) rethrowServerRefusal(e);
      rethrow;
    }
    final List<dynamic> list;
    if (res is List) {
      list = res;
    } else if (res is Map<String, dynamic> && res['data'] is List) {
      list = res['data'] as List;
    } else if (res is Map<String, dynamic> && res['devices'] is List) {
      list = res['devices'] as List;
    } else {
      list = const [];
    }

    return list
        .map((e) => DeviceModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Creates a new device enrolment request and returns the device info + 8-character
  /// (hex) enrolment code (#462 — was documented as 6-digit; server issues 8 upper-case
  /// hex chars, see devices.service.ts createIn).
  Future<({DeviceModel device, String enrolCode})> createDevice({
    required String label,
    required String role,
  }) async {
    final res = await _apiClient.post(
      '/api/v1/devices',
      headers: {
        'Idempotency-Key': newIdempotencyKey('idem_dev_'),
      },
      body: {
        'label': label.trim(),
        'role': role,
      },
    );

    final map = res as Map<String, dynamic>;
    final deviceMap = map['device'] as Map<String, dynamic>;
    final enrolCode = map['enrolCode'] as String? ?? '';
    return (device: DeviceModel.fromJson(deviceMap), enrolCode: enrolCode);
  }

  /// Retires a device terminal.
  ///
  /// If the POS device has an open drawer, [physicalCash] (Baht) is required.
  /// If the device has unsynced operations, [force] must be true and [note] is required.
  Future<void> retireDevice({
    required String deviceId,
    double? physicalCash,
    bool? force,
    String? note,
  }) async {
    final body = <String, dynamic>{};
    if (physicalCash != null) {
      body['physicalCash'] = physicalCash.toStringAsFixed(2);
    }
    if (force == true) {
      body['force'] = true;
      if (note != null && note.trim().isNotEmpty) {
        body['note'] = note.trim();
      }
    }

    await _apiClient.post(
      '/api/v1/devices/$deviceId/retire',
      headers: {
        'Idempotency-Key': newIdempotencyKey('idem_ret_'),
      },
      body: body.isNotEmpty ? body : null,
    );
  }
}
