// #188 — when to seed the document-number counter: app open and login.
//
// Both reach the same place: `AuthCubit.init()` emits [Authenticated] when a
// session survives a restart, and `login()` emits it after the form. Only a
// `pos` device is seeded — `GET /doc-counters` is pos-only (ADR-0007), and only
// that device will issue numbers itself in phase 2.

import 'dart:async';

import '../../data/services/doc_counter_seeder.dart';
import 'auth_cubit.dart';

/// The seed is fired and not awaited: it must never hold up the login form or
/// the first screen, and [DocCounterSeeder.seed] never throws.
StreamSubscription<AuthState> seedDocCountersOnSignIn(
  AuthCubit auth,
  DocCounterSeeder seeder,
) {
  return auth.stream.listen((state) {
    if (state is Authenticated && state.isPos) unawaited(seeder.seed());
  });
}
