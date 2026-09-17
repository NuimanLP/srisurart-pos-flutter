// Contract interface for background sync operations.
// Defined in docs/Backend_design/09_PHASE2_LANES.md §4.2 and 08_PHASE2_SPEC.md §14.
// Lane A (team/1) owns this interface seam; Lane B implements it with SyncService;
// Lane C consumes it for the "waiting for owner" screen without touching outbox_ops.

import 'dart:async';

enum SyncStatus {
  online,
  degraded,
  syncing,
}

enum OutboxOpStatus {
  pending,
  stuck,
  rejected,
}

class OutboxOpView {
  final String opId;
  final String type; // e.g. 'sale.create', 'return.create'
  final OutboxOpStatus status;
  final int attempts;
  final String? lastCode; // e.g. 'INSUFFICIENT_STOCK'
  final String? lastMessage; // Thai error message resolved via ServerErrorResolver
  final Map<String, dynamic>? lastDetails;
  final Map<String, dynamic> payload; // 08 §14 requires rejected tab to show payload
  final String? docNo; // Printed document number if assigned
  final DateTime createdAt;

  const OutboxOpView({
    required this.opId,
    required this.type,
    required this.status,
    required this.attempts,
    this.lastCode,
    this.lastMessage,
    this.lastDetails,
    required this.payload,
    this.docNo,
    required this.createdAt,
  });

  @override
  String toString() =>
      'OutboxOpView(opId: $opId, type: $type, status: $status, attempts: $attempts, docNo: $docNo)';
}

class DiscardResult {
  /// true = client does not delete local row, pulls latest state from server to overwrite (C15).
  final bool serverHasRow;

  const DiscardResult({required this.serverHasRow});
}

/// Abstract contract for sync operations exposed to the presentation layer.
abstract class SyncFacade {
  Stream<SyncStatus> get status;
  Stream<List<OutboxOpView>> get needsOwner; // rejected + stuck
  Stream<int> get outboxRemaining;
  Future<void> resend(String opId); // attempts = 0, same key, never change docNo
  Future<DiscardResult> discard(String opId, String note);
}

/// Runtime null implementation used when real sync engine is not wired.
///
/// Ensures the app boots cleanly and Lane C screens can open without crashing
/// prior to Lane B's 8-c implementation landing.
class NullSyncFacade implements SyncFacade {
  const NullSyncFacade();

  static final Stream<SyncStatus> _statusStream =
      Stream<SyncStatus>.multi((controller) {
    controller.add(SyncStatus.online);
  });

  static final Stream<List<OutboxOpView>> _needsOwnerStream =
      Stream<List<OutboxOpView>>.multi((controller) {
    controller.add(const <OutboxOpView>[]);
  });

  static final Stream<int> _outboxRemainingStream =
      Stream<int>.multi((controller) {
    controller.add(0);
  });

  @override
  Stream<SyncStatus> get status => _statusStream;

  @override
  Stream<List<OutboxOpView>> get needsOwner => _needsOwnerStream;

  @override
  Stream<int> get outboxRemaining => _outboxRemainingStream;

  @override
  Future<void> resend(String opId) async {
    throw UnsupportedError('ระบบซิงค์ยังไม่พร้อมใช้งาน');
  }

  @override
  Future<DiscardResult> discard(String opId, String note) async {
    throw UnsupportedError('ระบบซิงค์ยังไม่พร้อมใช้งาน');
  }
}
