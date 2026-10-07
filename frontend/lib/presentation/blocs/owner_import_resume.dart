// When to finish an owner import this device did not finish refreshing for:
// app open and login, the same two moments as the settings pull
// (`settings_pull.dart`). See `OwnerImportRepository.resumePendingImport`.

import 'dart:async';

import '../../data/repositories/owner_import_repository.dart';
import 'auth_cubit.dart';

/// Fired and not awaited: [OwnerImportRepository.resumePendingImport] never
/// throws, and a device with no unfinished import does one app_meta read.
StreamSubscription<AuthState> resumeImportOnSignIn(
  AuthCubit auth,
  OwnerImportRepository imports,
) {
  return auth.stream.listen((state) {
    if (state is Authenticated) unawaited(imports.resumePendingImport());
  });
}
