// AuthCubit — Reactive state management for authentication and device enrolment.

import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;

import '../../core/network/api_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/offline_pin_repository.dart';
import '../../data/storage/token_storage.dart' show TokenStoreUnavailableException;
import '../../domain/models/auth_models.dart';

abstract class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading({this.deviceToken, this.deviceRole});

  /// The device as it was when the login started, so the login form's device
  /// chip does not flip to "not POS" for the length of the request.
  final String? deviceToken;
  final String? deviceRole;

  bool get hasDeviceEnrolled => deviceToken != null && deviceToken!.isNotEmpty;
  bool get isPos => deviceRole == 'pos';

  @override
  List<Object?> get props => [deviceToken, deviceRole];
}

class Authenticated extends AuthState {
  const Authenticated({
    required this.user,
    this.deviceToken,
    this.deviceRole,
    this.passwordChangedAt,
    this.sessionDeviceRole,
  });

  final AuthUser user;
  final String? deviceToken;

  /// The browser/till's enrolled role as the login form shows it — may fall
  /// back to a role remembered from an earlier login. Not what the server
  /// checks; see [sessionDeviceRole].
  final String? deviceRole;

  /// #476: the device role THIS session was signed for (the refresh token's
  /// `drole`, `AuthRepository.sessionDeviceRole`) — what the server's
  /// `RequireDeviceRole('pos')` checks on a sale or a shift. Null for a
  /// session made without a device token. An offline-PIN login is `'pos'`
  /// (the PIN refuses anything else).
  final String? sessionDeviceRole;

  /// Whether this session may sell and open a shift (ADR-0004).
  bool get isPosSession => sessionDeviceRole == 'pos';

  /// From the login response (#443 PR3): when the password last changed, for
  /// the "รหัสผ่านถูกเปลี่ยนเมื่อ …" banner. Null when unknown or never.
  final DateTime? passwordChangedAt;

  bool get isPos => deviceRole == 'pos';

  @override
  List<Object?> get props =>
      [user, deviceToken, deviceRole, passwordChangedAt, sessionDeviceRole];
}

/// #443 PR3: the owner signed in with a temporary password and must set their
/// own before anything else. The restricted token stays inside [AuthCubit]
/// (memory only) — it is not part of the state.
class AuthPasswordChangeRequired extends AuthState {
  const AuthPasswordChangeRequired({
    required this.user,
    this.deviceToken,
    this.deviceRole,
    this.errorMessage,
    this.submitting = false,
  });

  final AuthUser user;
  final String? deviceToken;
  final String? deviceRole;
  final String? errorMessage;
  final bool submitting;

  @override
  List<Object?> get props =>
      [user, deviceToken, deviceRole, errorMessage, submitting];
}

class Unauthenticated extends AuthState {
  const Unauthenticated({
    this.deviceToken,
    this.deviceRole,
    this.errorMessage,
    this.signedOut = false,
  });

  final String? deviceToken;
  final String? deviceRole;
  final String? errorMessage;

  /// True only right after a deliberate [AuthCubit.logout] (owner decision
  /// 2026-10-01): the next login starts at checkout, not the last screen, and
  /// the app clears the cart and pending quote. A session expiry is false —
  /// the same counter signs back in and carries on where it was.
  final bool signedOut;

  bool get hasDeviceEnrolled => deviceToken != null && deviceToken!.isNotEmpty;
  bool get isPos => deviceRole == 'pos';

  @override
  List<Object?> get props =>
      [deviceToken, deviceRole, errorMessage, signedOut];
}

class AuthCubit extends Cubit<AuthState> {
  AuthCubit({
    required AuthRepository authRepository,
    OfflinePinRepository? offlinePinRepository,
  })  : _repo = authRepository,
        _pinRepo = offlinePinRepository,
        super(const AuthInitial());

  final AuthRepository _repo;
  final OfflinePinRepository? _pinRepo;

  /// #443 PR3: the `typ:'pwchange'` token, held only while the state is
  /// [AuthPasswordChangeRequired]. Never written to storage (#400).
  String? _passwordChangeToken;

  /// The session's own device role (#476, [Authenticated.sessionDeviceRole]).
  /// A token store that cannot be read right now must not fail the sign-in
  /// itself, nor read as "not a till" and block selling: it falls back to
  /// [fallback], the role the state carried before #476.
  Future<String?> _sessionRole(String? fallback) async {
    try {
      return await _repo.sessionDeviceRole();
    } catch (_) {
      return fallback;
    }
  }

  /// Logs in with offline PIN when in degraded mode on a POS terminal (08 §13).
  Future<PinVerifyResult> loginWithOfflinePin(String pin) async {
    if (_pinRepo == null) {
      return const PinVerifyNotConfigured();
    }

    // The role the login form is showing right now (init/logout already
    // applied the stored-role fallback), so AuthLoading shows the same chip.
    final shown = state;
    // What the form shows if a read below fails before we know better.
    String? prevDeviceToken = shown is Unauthenticated ? shown.deviceToken : null;
    String? prevDeviceRole = shown is Unauthenticated ? shown.deviceRole : null;

    final PinVerifyResult result;
    final AuthUser? storedUser;
    try {
      prevDeviceToken = await _repo.getDeviceToken();
      prevDeviceRole ??= await _repo.getDeviceRole();
      final deviceId = await _repo.getDeviceId();

      emit(AuthLoading(deviceToken: prevDeviceToken, deviceRole: prevDeviceRole));

      result = await _pinRepo.verifyPin(
        pin: pin,
        deviceId: deviceId,
      );
      storedUser = result is PinVerifySuccess ? await _pinRepo.getStoredUser() : null;
    } catch (e) {
      // A token store or PIN store that cannot be read (#400) must not leave
      // the form on AuthLoading with nothing said.
      final message = loginRefusalMessage(e);
      emit(Unauthenticated(
        deviceToken: prevDeviceToken,
        deviceRole: prevDeviceRole,
        errorMessage: message,
      ));
      return PinVerifyError(message);
    }

    if (result is PinVerifySuccess) {
      final user = storedUser ??
          const AuthUser(
            id: 'offline_pos',
            username: 'shop',
            role: 'owner',
            displayName: 'พนักงานหน้าร้าน (โหมดออฟไลน์)',
          );

      emit(Authenticated(
        user: user,
        deviceToken: prevDeviceToken,
        deviceRole: prevDeviceRole ?? 'pos',
        sessionDeviceRole: 'pos',
      ));
    } else {
      String errorMessage;
      switch (result) {
        case PinVerifyInvalid(:final remainingAttempts):
          errorMessage =
              'รหัส PIN ไม่ถูกต้อง (เหลือโอกาสอีก $remainingAttempts ครั้ง)';
        case PinVerifyLocked():
          errorMessage =
              'รหัส PIN ถูกล็อกเนื่องจากใส่ผิดครบ 5 ครั้ง กรุณาล็อกอินออนไลน์ด้วยรหัสผ่านหลัก';
        case PinVerifyExpired():
          errorMessage = 'รหัส PIN หมดอายุแล้ว (เกิน 3 วัน) กรุณาล็อกอินออนไลน์';
        case PinVerifyNotConfigured():
          errorMessage = 'ยังไม่ได้ตั้งค่า PIN ออฟไลน์บนเครื่องนี้';
        case PinVerifyNotPos():
          errorMessage =
              'เครื่องนี้ไม่ใช่เครื่อง POS ไม่สามารถใช้ PIN ออฟไลน์ได้';
        case PinVerifyError(:final message):
          errorMessage = message;
        case PinVerifySuccess():
          errorMessage = '';
      }

      emit(Unauthenticated(
        deviceToken: prevDeviceToken,
        deviceRole: prevDeviceRole,
        errorMessage: errorMessage,
      ));
    }

    return result;
  }

  /// Initializes authentication state from local storage.
  Future<void> init() async {
    final String? deviceToken;
    try {
      deviceToken = await _repo.getDeviceToken();
    } on TokenStoreUnavailableException catch (e) {
      // #400: the device token is in a web token store we cannot open this
      // run. Say so, instead of an unhandled error on a blank start screen.
      emit(Unauthenticated(errorMessage: e.toString()));
      return;
    }
    var deviceRole = await _repo.getDeviceRole();
    // Not a duplicate of AuthRepository.getDeviceRole's #400 fallback, which
    // only fires when there is NO access token. This one (and the similar
    // `_pinRepo` fallback in logout/sessionExpired) also fires when a token IS
    // present but carries no `drole` claim — the server omits it for a login
    // made without a device token — and then returns the role stored at an
    // earlier login where the repository returns null. Removing it changes
    // behaviour.
    deviceRole ??= await _pinRepo?.getDeviceRole();
    final isAuth = await _repo.isAuthenticated();
    final user = await _repo.getCurrentUser();

    // #558: the session was signed for a device (`did`) but this browser no
    // longer holds a device token (one IndexedDB entry cleared or evicted).
    // Carrying on would sell as a till that can no longer push its outbox or
    // log in as itself, so end the session: logout keeps the local DB and
    // its outbox untouched, and the login that follows is a plain
    // (backoffice) one until the browser is enrolled again.
    if (isAuth &&
        (deviceToken == null || deviceToken.isEmpty) &&
        await _repo.sessionDeviceId() != null) {
      await _repo.logout();
      emit(const Unauthenticated());
      return;
    }

    if (isAuth && user != null) {
      emit(Authenticated(
        user: user,
        deviceToken: deviceToken,
        deviceRole: deviceRole,
        sessionDeviceRole: await _sessionRole(deviceRole),
      ));
    } else {
      emit(Unauthenticated(
        deviceToken: deviceToken,
        deviceRole: deviceRole,
      ));
    }
  }

  /// Logs in with username and password.
  Future<bool> login({
    required String username,
    required String password,
  }) async {
    // The role the login form is showing right now (init/logout already
    // applied the stored-role fallback), so AuthLoading shows the same chip.
    final shown = state;
    final String? prevDeviceToken;
    final String? prevDeviceRole;
    try {
      prevDeviceToken = await _repo.getDeviceToken();
      prevDeviceRole = (shown is Unauthenticated ? shown.deviceRole : null) ??
          await _repo.getDeviceRole();
    } catch (e) {
      // A token store that cannot be read (#400) must reach the form, not
      // escape the login button's handler with nothing on screen.
      emit(Unauthenticated(
        deviceToken: shown is Unauthenticated ? shown.deviceToken : null,
        deviceRole: shown is Unauthenticated ? shown.deviceRole : null,
        errorMessage: loginRefusalMessage(e),
      ));
      return false;
    }

    emit(AuthLoading(deviceToken: prevDeviceToken, deviceRole: prevDeviceRole));

    try {
      final result = await _repo.login(username: username, password: password);
      switch (result) {
        case LoginPasswordChangeRequired(:final user, :final passwordChangeToken):
          _passwordChangeToken = passwordChangeToken;
          emit(AuthPasswordChangeRequired(
            user: user,
            deviceToken: prevDeviceToken,
            deviceRole: prevDeviceRole,
          ));
          return false;
        case LoginSucceeded(:final user, :final passwordChangedAt):
          final role = await _repo.getDeviceRole() ?? prevDeviceRole;
          emit(Authenticated(
            user: user,
            deviceToken: prevDeviceToken,
            deviceRole: role,
            passwordChangedAt: passwordChangedAt,
            sessionDeviceRole: await _sessionRole(role),
          ));
          return true;
      }
    } catch (e) {
      // #609: AuthRepository.login has already forgotten a dead device token
      // (and its PIN record); show the browser as not enrolled, so the login
      // form says backoffice and the enrol link comes back.
      if (e is ApiException &&
          e.statusCode == 401 &&
          AuthRepository.deadDeviceTokenCodes.contains(e.code)) {
        emit(const Unauthenticated(errorMessage: deviceEnrolmentGone));
        return false;
      }
      emit(Unauthenticated(
        deviceToken: prevDeviceToken,
        deviceRole: prevDeviceRole,
        errorMessage: loginRefusalMessage(e),
      ));
      return false;
    }
  }

  /// #443 PR3: sets the owner's own password with the restricted token from
  /// [login], then continues as a normal signed-in session.
  Future<bool> changePassword(String newPassword) async {
    final current = state;
    final token = _passwordChangeToken;
    if (current is! AuthPasswordChangeRequired || token == null) return false;

    emit(AuthPasswordChangeRequired(
      user: current.user,
      deviceToken: current.deviceToken,
      deviceRole: current.deviceRole,
      submitting: true,
    ));
    try {
      final user = await _repo.changePassword(
        passwordChangeToken: token,
        newPassword: newPassword,
      );
      _passwordChangeToken = null;
      final role = await _repo.getDeviceRole() ?? current.deviceRole;
      emit(Authenticated(
        user: user,
        deviceToken: current.deviceToken,
        deviceRole: role,
        sessionDeviceRole: await _sessionRole(role),
      ));
      return true;
    } catch (e) {
      // 401: the 10-minute token expired or was already used — only a fresh
      // login with the temporary password can continue.
      if (e is ApiException && e.statusCode == 401) {
        _passwordChangeToken = null;
        emit(Unauthenticated(
          deviceToken: current.deviceToken,
          deviceRole: current.deviceRole,
          errorMessage: passwordChangeSessionExpired,
        ));
        return false;
      }
      emit(AuthPasswordChangeRequired(
        user: current.user,
        deviceToken: current.deviceToken,
        deviceRole: current.deviceRole,
        errorMessage: ServerErrorResolver.resolveCounterError(e),
      ));
      return false;
    }
  }

  /// Leaves the change-password screen without changing anything.
  void cancelPasswordChange() {
    final current = state;
    _passwordChangeToken = null;
    emit(Unauthenticated(
      deviceToken: current is AuthPasswordChangeRequired ? current.deviceToken : null,
      deviceRole: current is AuthPasswordChangeRequired ? current.deviceRole : null,
    ));
  }

  /// agent ร่าง (#609, 02_API_SCREENS.md §8.1.1) — not yet ratified. The
  /// server refused this browser's device token at login: the device was
  /// retired or the token is unknown. The token is gone; the browser is back
  /// to backoffice mode until it is enrolled again.
  static const String deviceEnrolmentGone =
      'เครื่องนี้ถูกปลดจากร้านแล้ว หรือไม่พบในระบบ จึงเปลี่ยนเป็นโหมด Backoffice '
      '— เข้าสู่ระบบอีกครั้งได้ หรือผูกเครื่องใหม่ด้วยรหัสจากเจ้าของร้าน';

  /// agent ร่าง (#443 PR3, 02_API_SCREENS.md §8.1) — not yet ratified.
  static const String passwordChangeSessionExpired =
      'หมดเวลาเปลี่ยนรหัสผ่าน กรุณาเข้าสู่ระบบใหม่ด้วยรหัสผ่านชั่วคราว';

  /// The sentence the login form shows for a failed `POST /auth/token` (#143).
  ///
  /// Every string comes from [ServerErrorResolver] or was already the login
  /// form's own — none is new:
  /// - **401** — the server's login refusals (wrong password, unknown, inactive
  ///   or ambiguous user, bad device token) are all English Nest messages with
  ///   no code, so the resolver would print `Invalid credentials` at the
  ///   counter. They get the form's generic `เข้าสู่ระบบไม่สำเร็จ`, which also
  ///   says nothing about *which* part was wrong.
  /// - **5xx** — a proxy's 502 body is HTML; the connection sentence instead.
  /// - **other 4xx / 429** — coded verdicts (`TENANT_SUSPENDED`,
  ///   `RATE_LIMITED`) resolve to their mapped Thai.
  /// - **transport failure** — the connection sentence. The raw exception text
  ///   used to be appended here, which put `ClientException: …` on screen.
  @visibleForTesting
  static String loginRefusalMessage(Object error) {
    // A client-side refusal already in Thai — `TENANT_SWITCH_UNSENT_WORK`
    // (TenantCacheGuard) is the one a login can meet.
    if (error is PosException) return error.message;
    // #400's ratified sentence: the browser's token store cannot be opened.
    if (error is TokenStoreUnavailableException) return error.toString();
    if (error is ApiException) {
      // #443 PR3: the one 401 that must NOT read as "wrong password" — the
      // password was right, the temporary one simply expired.
      if (error.code == 'TEMP_PASSWORD_EXPIRED') return error.thaiMessage;
      if (error.statusCode == 401) return 'เข้าสู่ระบบไม่สำเร็จ';
      if (error.statusCode >= 500) return ServerErrorResolver.resolve(null);
      return error.thaiMessage;
    }
    if (error is http.ClientException || error is TimeoutException) {
      return ServerErrorResolver.resolve(null);
    }
    return 'เข้าสู่ระบบไม่สำเร็จ';
  }

  /// Enrols the device using the code from the shop owner (ADR-0004).
  ///
  /// A [PosException] (the till still holds local work,
  /// `TenantCacheGuard.checkEnrolment`) is rethrown so the dialog can show
  /// its Thai sentence instead of "wrong code"; anything else is `false`.
  ///
  /// #558: enrolling while signed in ends the session. Its tokens were signed
  /// without this device (`POST /auth/token` is the only place a device token
  /// becomes `did`/`drole`, and `/auth/refresh` keeps whatever the login
  /// had), so the session would stay device-less — `GET /devices` 403, no
  /// sales — until the next login. The login form's post-enrol banner asks
  /// for that login; it re-admits the tenant through the device token and
  /// records the offline-PIN window with the new `did`. Logout keeps the
  /// local DB, and `checkEnrolment` already refused any enrolment while
  /// local work is unsent.
  Future<bool> enrolDevice(String code) async {
    try {
      final deviceToken = await _repo.enrolDevice(code);

      if (state is Authenticated) {
        _loggingOut = true;
        try {
          await _repo.logout();
        } catch (_) {
          // The enrolment itself succeeded and its token is stored; a token
          // store that could not be cleared must not read as "wrong code".
        } finally {
          _loggingOut = false;
        }
        // Role null: unknown until that login — the banner says so.
        emit(Unauthenticated(deviceToken: deviceToken));
      } else {
        final role = await _repo.getDeviceRole();
        emit(Unauthenticated(
          deviceToken: deviceToken,
          deviceRole: role,
        ));
      }
      return true;
    } on PosException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  /// Logs out the current user while preserving the device token and device role (ADR-0004).
  Future<void> logout() async {
    _loggingOut = true;
    try {
      await _logout();
    } finally {
      _loggingOut = false;
    }
  }

  /// True while [logout] runs: a session expiry racing it is the same sign-out
  /// and must not replace it (that would keep `?from=` and the cart).
  bool _loggingOut = false;

  Future<void> _logout() async {
    final currentDeviceRole = (state is Authenticated)
        ? (state as Authenticated).deviceRole
        : await _repo.getDeviceRole();
    await _repo.logout();
    final deviceToken = await _repo.getDeviceToken();
    final effectiveRole = currentDeviceRole ?? await _pinRepo?.getDeviceRole();
    emit(Unauthenticated(
      deviceToken: deviceToken,
      deviceRole: effectiveRole,
      signedOut: true,
    ));
  }

  /// The refresh token is gone or the server refused it: the session is over.
  ///
  /// 🔴 `errorMessage` stays **null** on purpose. This fires when the shift that
  /// started before midnight is still on screen at 04:00, and what the counter
  /// needs then is the login form, not a dialog explaining a token lifetime
  /// (#54 AC3). The device token survives — the machine is still enrolled, only
  /// the person is signed out (ADR-0004), which is exactly [logout]'s shape.
  ///
  /// Driven by `ApiClient.onSessionExpired`, wired in `repositoryProviders`.
  Future<void> sessionExpired() async {
    // No live session to end: signed out (on purpose, or with a login error
    // on screen), signing out right now, or a login in flight. A late refusal
    // must not replace the spinner, the error, or the logout.
    final current = state;
    if (_loggingOut || current is Unauthenticated || current is AuthLoading) {
      return;
    }
    final currentDeviceRole = (state is Authenticated)
        ? (state as Authenticated).deviceRole
        : await _repo.getDeviceRole();
    final deviceToken = await _repo.getDeviceToken();
    // #558: `ApiClient` also ends a session whose device token went missing.
    // With no token there is no enrolment, so no role to show — a remembered
    // 'pos' would put "เครื่อง POS" on a login that will be backoffice.
    final effectiveRole = deviceToken == null || deviceToken.isEmpty
        ? null
        : currentDeviceRole ?? await _pinRepo?.getDeviceRole();
    emit(Unauthenticated(deviceToken: deviceToken, deviceRole: effectiveRole));
  }

  /// Removes the device token, clears offline PIN, and unbinds the hardware.
  Future<void> clearDeviceEnrolment() async {
    await _repo.clearDeviceEnrolment();
    await _pinRepo?.clearPin();
    emit(const Unauthenticated());
  }
}
