// A signed-in AuthRepository with a given role and no storage, for widget
// tests of the owner-only product picture (product_image_editor_*_test,
// product_add_image_test).

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class NoTokenStorage implements TokenStorage {
  @override
  Future<void> clearAll() async {}
  @override
  Future<void> clearAuthTokens() async {}
  @override
  Future<String?> getAccessToken() async => null;
  @override
  Future<String?> getDeviceToken() async => null;
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<AuthUser?> getUser() async => null;
  @override
  Future<void> setAccessToken(String? token) async {}
  @override
  Future<void> setDeviceToken(String? token) async {}
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> setUser(AuthUser? user) async {}
}

class SignedInAs extends AuthRepository {
  SignedInAs(this.role)
      : super(
          apiClient: ApiClient(tokenStorage: NoTokenStorage()),
          tokenStorage: NoTokenStorage(),
        );
  final String role;
  @override
  Future<String?> sessionDeviceRole() async => 'pos';
  @override
  Future<String?> getDeviceRole() async => 'pos';
  @override
  Future<String?> getDeviceToken() async => null;
  @override
  Future<String?> sessionDeviceId() async => null;
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<AuthUser?> getCurrentUser() async =>
      AuthUser(id: 'u-1', username: 'u', role: role);
}
