import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/sync/sync_facade.dart';
import '../../data/sync/sync_service.dart';

/// Helper widget to expose [SyncStatus] and `isDegraded` to presentation widgets.
/// Used to disable online-only UI buttons when in Degraded mode per 08_PHASE2_SPEC.md §6.2.
class SyncStatusBuilder extends StatelessWidget {
  final Widget Function(
    BuildContext context,
    SyncStatus status,
    bool isDegraded,
  ) builder;

  const SyncStatusBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    SyncFacade? syncFacade;
    try {
      syncFacade = context.read<SyncFacade>();
    } catch (_) {
      syncFacade = null;
    }

    if (syncFacade == null) {
      return builder(context, SyncStatus.online, false);
    }

    final initial = syncFacade is SyncService
        ? syncFacade.currentStatus
        : SyncStatus.online;

    return StreamBuilder<SyncStatus>(
      stream: syncFacade.status,
      initialData: initial,
      builder: (context, snapshot) {
        final status = snapshot.data ?? initial;
        return builder(context, status, status == SyncStatus.degraded);
      },
    );
  }
}

extension SyncStatusContext on BuildContext {
  bool get isDegraded {
    try {
      final facade = read<SyncFacade>();
      if (facade is SyncService) {
        return facade.currentStatus == SyncStatus.degraded;
      }
    } catch (_) {}
    return false;
  }
}
