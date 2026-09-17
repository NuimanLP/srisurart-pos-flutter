// #188 — the counter is seeded on app open and on login, for a pos device only,
// and a failing seed never blocks either.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/services/doc_counter_seeder.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/doc_counter_seeding.dart';

class _Auth extends AuthRepository {
  _Auth({required this.role, this.signedIn = false})
    : super(
        apiClient: ApiClient(httpClient: MockClient((_) async => http.Response('', 500))),
        // Every method AuthCubit reaches is overridden below; storage is never read.
        tokenStorage: SharedPrefsTokenStorage(),
      );

  final String? role;
  bool signedIn;

  @override
  Future<AuthUser> login({required String username, required String password}) async {
    signedIn = true;
    return AuthUser(id: 'u1', username: username, role: 'cashier');
  }

  @override
  Future<String?> getDeviceToken() async => 'dt';
  @override
  Future<String?> getDeviceRole() async => role;
  @override
  Future<bool> isAuthenticated() async => signedIn;
  @override
  Future<AuthUser?> getCurrentUser() async =>
      signedIn ? const AuthUser(id: 'u1', username: 'x', role: 'cashier') : null;
}

class _CountingSeeder extends DocCounterSeeder {
  _CountingSeeder(AppDatabase db, {this.hang = false})
    : super(db: db, apiClient: ApiClient(httpClient: MockClient((_) async => http.Response('', 500))));

  final bool hang;
  int calls = 0;

  @override
  Future<bool> seed() {
    calls++;
    // A seed that never finishes must still not hold up sign-in.
    return hang ? Completer<bool>().future : Future.value(false);
  }
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('app open with a surviving pos session seeds', () async {
    final cubit = AuthCubit(authRepository: _Auth(role: 'pos', signedIn: true));
    final seeder = _CountingSeeder(db);
    seedDocCountersOnSignIn(cubit, seeder);

    await cubit.init();
    await settle();

    expect(cubit.state, isA<Authenticated>());
    expect(seeder.calls, 1);
    await cubit.close();
  });

  test('login on a pos device seeds, even when the seed never finishes', () async {
    final cubit = AuthCubit(authRepository: _Auth(role: 'pos'));
    final seeder = _CountingSeeder(db, hang: true);
    seedDocCountersOnSignIn(cubit, seeder);

    await cubit.init();
    await settle();
    expect(seeder.calls, 0); // signed out: nothing to seed

    expect(await cubit.login(username: 'a', password: 'b'), isTrue);
    await settle();

    expect(cubit.state, isA<Authenticated>());
    expect(seeder.calls, 1);
    await cubit.close();
  });

  test('a backoffice device is never seeded', () async {
    final cubit = AuthCubit(authRepository: _Auth(role: 'backoffice', signedIn: true));
    final seeder = _CountingSeeder(db);
    seedDocCountersOnSignIn(cubit, seeder);

    await cubit.init();
    await cubit.login(username: 'a', password: 'b');
    await settle();

    expect(seeder.calls, 0);
    await cubit.close();
  });
}
