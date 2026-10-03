// mob04, 2026-10-03: "+ เพิ่มช่าง" → fill the dialog → save → the button spun
// forever. The server answered 400 (`name is required` — the dialog has only a
// Thai-name field), `ApiMechanicsRepository.addMechanic` let the raw
// `ApiException` out, and `_MechanicFormDialogState._save` had no catch, so
// `_busy` never went back to false and nothing was shown.
//
// These run the REAL `ApiMechanicsRepository` against a mocked HTTP client, so
// the whole path — repository conversion + dialog handling — is exercised.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  void setWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// Opens the add dialog, fills it as the owner did on mob04, presses เพิ่ม.
  Future<void> addMechanicThroughDialog(
    WidgetTester tester,
    AppDatabase db,
    http.Client client,
  ) async {
    final repo = ApiMechanicsRepository(db, ApiClient(httpClient: client));
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          ...repositoryProviders(db),
          RepositoryProvider<MechanicsRepository>.value(value: repo),
        ],
        child: const MaterialApp(home: Scaffold(body: MechanicsScreen())),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.tap(find.text('+ เพิ่มช่าง'));
    await tester.pumpAndSettle();
    expect(find.text('เพิ่มช่างใหม่'), findsOneWidget);

    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'ช่างเอก'); // ชื่อ-สกุล
    await tester.enterText(fields.at(1), 'เอก'); // ชื่อเล่น
    await tester.enterText(fields.at(3), 'เอก บางบอย'); // ชื่ออู่
    await tester.enterText(fields.at(4), '20000'); // วงเงินเครดิต
    await tester.pumpAndSettle();

    await tester.tap(find.text('เพิ่ม'));
    await tester.pumpAndSettle();
  }

  void expectDialogOpenAndIdle(WidgetTester tester) {
    expect(find.text('เพิ่มช่างใหม่'), findsOneWidget,
        reason: 'the dialog stays open so the counter can retry');
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
      reason: 'the save button must stop spinning',
    );
    final add = tester.widget<FilledButton>(
      find.ancestor(of: find.text('เพิ่ม'), matching: find.byType(FilledButton)),
    );
    expect(add.onPressed, isNotNull, reason: 'the save button is enabled again');
    final cancel = tester.widget<OutlinedButton>(
      find.ancestor(of: find.text('ยกเลิก'), matching: find.byType(OutlinedButton)),
    );
    expect(cancel.onPressed, isNotNull,
        reason: 'Cancel was disabled forever on mob04 — the dialog must be escapable');
  }

  testWidgets('a 400 from POST /mechanics shows a Thai error and stops spinning',
      (tester) async {
    setWideViewport(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/mechanics') {
        return http.Response(
          jsonEncode({
            'status': 'error',
            'error': {'code': 'BAD_REQUEST', 'message': 'name is required'},
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    await tester.runAsync(() => addMechanicThroughDialog(tester, db, client));

    expect(find.text('ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่'), findsOneWidget);
    expect(find.textContaining('name is required'), findsNothing);
    expect(find.textContaining('ApiException'), findsNothing);
    expectDialogOpenAndIdle(tester);
  });

  testWidgets('a transport failure shows the Thai connection sentence and stops spinning',
      (tester) async {
    setWideViewport(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/mechanics') {
        throw http.ClientException(
          'Failed to fetch',
          Uri.parse('https://172.30.58.20/api/v1/mechanics'),
        );
      }
      return http.Response('{"status":"error"}', 404);
    });

    await tester.runAsync(() => addMechanicThroughDialog(tester, db, client));

    expect(find.text('เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'), findsOneWidget);
    expect(find.textContaining('https://'), findsNothing);
    expect(find.textContaining('ClientException'), findsNothing);
    expectDialogOpenAndIdle(tester);
  });
}
