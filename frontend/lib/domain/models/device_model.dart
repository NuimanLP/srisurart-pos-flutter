import 'package:flutter/foundation.dart';

/// Device model representing a terminal registered under a tenant (ADR-0004, Slice 21).
@immutable
class DeviceModel {
  final String id;
  final String label;
  final int deviceNo;
  final String role; // 'pos' | 'backoffice'
  final DateTime? retiredAt;
  final bool enrolled;
  final DateTime? enrolExpiresAt;
  final DateTime? lastSeenAt;
  final int unsyncedOps;
  final DateTime? unsyncedReportedAt;

  const DeviceModel({
    required this.id,
    required this.label,
    required this.deviceNo,
    required this.role,
    this.retiredAt,
    this.enrolled = false,
    this.enrolExpiresAt,
    this.lastSeenAt,
    this.unsyncedOps = 0,
    this.unsyncedReportedAt,
  });

  bool get isRetired => retiredAt != null;
  bool get isPos => role == 'pos';
  bool get isBackoffice => role == 'backoffice';
  bool get isEnrolCodeActive =>
      !enrolled &&
      enrolExpiresAt != null &&
      enrolExpiresAt!.isAfter(DateTime.now());

  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String && v.isNotEmpty) {
        return DateTime.tryParse(v);
      }
      return null;
    }

    return DeviceModel(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      deviceNo: (json['deviceNo'] as num?)?.toInt() ?? 0,
      role: json['role'] as String? ?? 'backoffice',
      retiredAt: parseDate(json['retiredAt']),
      enrolled: json['enrolled'] as bool? ?? false,
      enrolExpiresAt: parseDate(json['enrolExpiresAt']),
      lastSeenAt: parseDate(json['lastSeenAt']),
      unsyncedOps: (json['unsyncedOps'] as num?)?.toInt() ?? 0,
      unsyncedReportedAt: parseDate(json['unsyncedReportedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'deviceNo': deviceNo,
        'role': role,
        'retiredAt': retiredAt?.toIso8601String(),
        'enrolled': enrolled,
        'enrolExpiresAt': enrolExpiresAt?.toIso8601String(),
        'lastSeenAt': lastSeenAt?.toIso8601String(),
        'unsyncedOps': unsyncedOps,
        'unsyncedReportedAt': unsyncedReportedAt?.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceModel &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          label == other.label &&
          deviceNo == other.deviceNo &&
          role == other.role &&
          retiredAt == other.retiredAt &&
          enrolled == other.enrolled &&
          enrolExpiresAt == other.enrolExpiresAt &&
          lastSeenAt == other.lastSeenAt &&
          unsyncedOps == other.unsyncedOps &&
          unsyncedReportedAt == other.unsyncedReportedAt;

  @override
  int get hashCode =>
      id.hashCode ^
      label.hashCode ^
      deviceNo.hashCode ^
      role.hashCode ^
      retiredAt.hashCode ^
      enrolled.hashCode ^
      enrolExpiresAt.hashCode ^
      lastSeenAt.hashCode ^
      unsyncedOps.hashCode ^
      unsyncedReportedAt.hashCode;
}
