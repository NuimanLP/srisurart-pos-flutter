// #474: settings must be re-pulled when the network returns, not only on the
// next login. `ApiSettingsRepository.pullFromServer()` was only wired to
// `pullSettingsOnSignIn` (settings_pull.dart); a session that survived a
// restart while offline never got a second chance until the owner logged in
// again. This proves `repositoryProviders`' `triggerEntityPull` — the
// `onPull` callback `SyncService` fires after every push while online,
// including right after a reconnect — pulls settings too.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
    'SyncService.onPull (triggerEntityPull) pulls settings from the server',
    (tester) async {
      var settingsRequested = false;

      final client = ApiClient(
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/settings') {
            settingsRequested = true;
            return http.Response(
              jsonEncode({
                'shopName': 'ร้านศรีใหม่',
                'shopNameEn': 'New Sri Shop',
                'taxRate': 7,
                'quoteValidDays': 30,
                'updatedAt': '2026-09-28T00:00:00.000Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          // products/customers/mechanics pull pages — an empty page is
          // enough, they are not what this test is about.
          return http.Response(
            jsonEncode({
              'data': [],
              'meta': {'total': 0, 'page': 1, 'limit': 100, 'totalPages': 1},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      SyncFacade? syncFacade;
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, apiClient: client, useApi: true),
          child: Builder(
            builder: (context) {
              syncFacade = context.read<SyncFacade>();
              return const SizedBox();
            },
          ),
        ),
      );

      expect(syncFacade, isA<SyncService>());
      final sync = syncFacade! as SyncService;

      try {
        // What SyncService.push()'s finally block does on reconnect (08 §15):
        // status is online with nothing left to push, so it calls pull(),
        // which fires onPull == triggerEntityPull.
        await sync.pull();

        expect(
          settingsRequested,
          isTrue,
          reason: 'GET /api/v1/settings was never requested by the pull hook',
        );

        final row = await db.select(db.settingsRow).getSingle();
        expect(row.shopName, 'ร้านศรีใหม่');
        expect(row.shopNameEN, 'New Sri Shop');
      } finally {
        sync.dispose();
        // `dispose()` cancels the outbox `watch()` subscription, which
        // schedules a zero-duration Timer (drift's `markAsClosed`) — flush
        // it against `testWidgets`'s FakeAsync clock so it isn't reported
        // as "still pending" when the test ends.
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}
