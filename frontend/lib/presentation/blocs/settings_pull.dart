// #460 — when to pull the tenant's settings: app open and login.
//
// Same two moments as the #188 doc-counter seed (`doc_counter_seeding.dart`):
// `AuthCubit.init()` emits [Authenticated] for a session that survived a
// restart, `login()` after the form. Unlike the seed, every device role pulls —
// `GET /settings` is open to any signed-in device and a backoffice screen
// prints the shop name too.
//
// Not the only pull: a build with a `SyncService` also pulls settings from
// `triggerEntityPull` (`repository_providers.dart`, #474) on reconnect, so a
// session that survived an offline app-open doesn't wait for the next login
// here. This file stays as-is because a backoffice build has no
// `SyncService` and still needs this one.

import 'dart:async';

import '../../data/repositories/api_payment_accounts_repository.dart';
import '../../data/repositories/api_settings_repository.dart';
import 'auth_cubit.dart';

/// Fired and not awaited: [ApiSettingsRepository.pullFromServer] never throws,
/// and a slow link must not hold up the first screen. An offline-PIN sign-in
/// also emits [Authenticated]; its pull simply fails and the cache stays.
StreamSubscription<AuthState> pullSettingsOnSignIn(
  AuthCubit auth,
  ApiSettingsRepository settings,
) {
  return auth.stream.listen((state) {
    if (state is Authenticated) unawaited(settings.pullFromServer());
  });
}

/// The QR payment accounts ride the same two moments (owner 2026-10-10):
/// checkout reads them from the cache, so a fresh sign-in must fill it.
/// [ApiPaymentAccountsRepository.pullFromServer] never throws either.
StreamSubscription<AuthState> pullPaymentAccountsOnSignIn(
  AuthCubit auth,
  ApiPaymentAccountsRepository accounts,
) {
  return auth.stream.listen((state) {
    if (state is Authenticated) unawaited(accounts.pullFromServer());
  });
}
