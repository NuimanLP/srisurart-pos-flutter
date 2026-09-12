// AuthCubit — Reactive state management for authentication and device enrolment.

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/api_exception.dart';
import '../../data/repositories/auth_repository.dart';
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
  const AuthLoading();
}

class Authenticated extends AuthState {
  const Authenticated({
    required this.user,
    this.deviceToken,
    this.deviceRole,
  });

  final AuthUser user;
  final String? deviceToken;
  final String? deviceRole;

  bool get isPos => deviceRole == 'pos';

  @override
  List<Object?> get props => [user, deviceToken, deviceRole];
}

class Unauthenticated extends AuthState {
  const Unauthenticated({
    this.deviceToken,
    this.deviceRole,
    this.errorMessage,
  });

  final String? deviceToken;
  final String? deviceRole;
  final String? errorMessage;

  bool get hasDeviceEnrolled => deviceToken != null && deviceToken!.isNotEmpty;
  bool get isPos => deviceRole == 'pos';

  @override
  List<Object?> get props => [deviceToken, deviceRole, errorMessage];
}

class AuthCubit extends Cubit<AuthState> {
  AuthCubit({required AuthRepository authRepository})
      : _repo = authRepository,
        super(const AuthInitial());

  final AuthRepository _repo;

  /// Initializes authentication state from local storage.
  Future<void> init() async {
    final deviceToken = await _repo.getDeviceToken();
    final deviceRole = await _repo.getDeviceRole();
    final isAuth = await _repo.isAuthenticated();
    final user = await _repo.getCurrentUser();

    if (isAuth && user != null) {
      emit(Authenticated(
        user: user,
        deviceToken: deviceToken,
        deviceRole: deviceRole,
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
    final prevDeviceToken = await _repo.getDeviceToken();
    final prevDeviceRole = await _repo.getDeviceRole();

    emit(const AuthLoading());

    try {
      final user = await _repo.login(username: username, password: password);
      final role = await _repo.getDeviceRole() ?? prevDeviceRole;
      emit(Authenticated(
        user: user,
        deviceToken: prevDeviceToken,
        deviceRole: role,
      ));
      return true;
    } on ApiException catch (e) {
      emit(Unauthenticated(
        deviceToken: prevDeviceToken,
        deviceRole: prevDeviceRole,
        errorMessage: e.thaiMessage,
      ));
      return false;
    } catch (e) {
      emit(Unauthenticated(
        deviceToken: prevDeviceToken,
        deviceRole: prevDeviceRole,
        errorMessage: 'เข้าสู่ระบบไม่สำเร็จ: ${e.toString()}',
      ));
      return false;
    }
  }

  /// Enrols the device using the code from the shop owner (ADR-0004).
  Future<bool> enrolDevice(String code) async {
    try {
      final deviceToken = await _repo.enrolDevice(code);
      final role = await _repo.getDeviceRole();

      final current = state;
      if (current is Authenticated) {
        emit(Authenticated(
          user: current.user,
          deviceToken: deviceToken,
          deviceRole: role ?? current.deviceRole,
        ));
      } else {
        emit(Unauthenticated(
          deviceToken: deviceToken,
          deviceRole: role,
        ));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Logs out the current user while preserving the device token (ADR-0004).
  Future<void> logout() async {
    await _repo.logout();
    final deviceToken = await _repo.getDeviceToken();
    final deviceRole = await _repo.getDeviceRole();
    emit(Unauthenticated(
      deviceToken: deviceToken,
      deviceRole: deviceRole,
    ));
  }

  /// Removes the device token and unbinds the hardware.
  Future<void> clearDeviceEnrolment() async {
    await _repo.clearDeviceEnrolment();
    emit(const Unauthenticated());
  }
}
