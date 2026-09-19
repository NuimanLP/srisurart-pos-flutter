// Test fake for SyncFacade contract.
// Used by Lane C for testing the "waiting for owner" screen and review tabs
// without requiring real outbox_ops or network connectivity.

import 'dart:async';
import 'package:srisurart_pos/data/sync/sync_facade.dart';

class FakeSyncFacade implements SyncFacade {
  final _statusController = StreamController<SyncStatus>.broadcast();
  final _needsOwnerController = StreamController<List<OutboxOpView>>.broadcast();
  final _outboxRemainingController = StreamController<int>.broadcast();

  SyncStatus _currentStatus = SyncStatus.online;
  List<OutboxOpView> _currentNeedsOwner = const [];
  int _currentOutboxRemaining = 0;

  final List<String> resendCalls = [];
  final List<({String opId, String note})> discardCalls = [];

  DiscardResult nextDiscardResult = const DiscardResult(serverHasRow: false);
  Object? nextResendError;
  Object? nextDiscardError;

  FakeSyncFacade({
    SyncStatus initialStatus = SyncStatus.online,
    List<OutboxOpView> initialNeedsOwner = const [],
    int initialOutboxRemaining = 0,
  })  : _currentStatus = initialStatus,
        _currentNeedsOwner = initialNeedsOwner,
        _currentOutboxRemaining = initialOutboxRemaining;

  @override
  SyncStatus get currentStatus => _currentStatus;
  List<OutboxOpView> get currentNeedsOwner => _currentNeedsOwner;
  int get currentOutboxRemaining => _currentOutboxRemaining;

  void emitStatus(SyncStatus status) {
    _currentStatus = status;
    _statusController.add(status);
  }

  void emitNeedsOwner(List<OutboxOpView> ops) {
    _currentNeedsOwner = List.unmodifiable(ops);
    _needsOwnerController.add(_currentNeedsOwner);
  }

  void emitOutboxRemaining(int count) {
    _currentOutboxRemaining = count;
    _outboxRemainingController.add(count);
  }

  late final Stream<SyncStatus> _statusStream =
      Stream<SyncStatus>.multi((controller) {
    controller.add(_currentStatus);
    final sub = _statusController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  late final Stream<List<OutboxOpView>> _needsOwnerStream =
      Stream<List<OutboxOpView>>.multi((controller) {
    controller.add(_currentNeedsOwner);
    final sub = _needsOwnerController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  late final Stream<int> _outboxRemainingStream =
      Stream<int>.multi((controller) {
    controller.add(_currentOutboxRemaining);
    final sub = _outboxRemainingController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  @override
  Stream<SyncStatus> get status => _statusStream;

  @override
  Stream<List<OutboxOpView>> get needsOwner => _needsOwnerStream;

  @override
  Stream<int> get outboxRemaining => _outboxRemainingStream;

  @override
  Future<void> resend(String opId) async {
    resendCalls.add(opId);
    if (nextResendError != null) {
      throw nextResendError!;
    }
  }

  @override
  Future<DiscardResult> discard(String opId, String note) async {
    discardCalls.add((opId: opId, note: note));
    if (nextDiscardError != null) {
      throw nextDiscardError!;
    }
    return nextDiscardResult;
  }

  void dispose() {
    _statusController.close();
    _needsOwnerController.close();
    _outboxRemainingController.close();
  }
}
