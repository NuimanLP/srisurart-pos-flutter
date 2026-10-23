// VAT items (owner approved 2026-10-23):
//  • Settings → ทั่วไป: เลขประจำตัวผู้เสียภาษี + สาขา, validated before the
//    save, saved through the real SettingsRepository (Drift build), and
//    refused while Degraded on the API build (no PATCH, no local write).
//  • Settings → ส่งออก CSV → รายงานภาษีขาย: loaded through the real Drift
//    repositories — a manual void, a full return's auto-void whose credit note
//    lands the next month — and laid out at 390 px, 3x on 1920x1080 and 2x on
//    1366x768.

import 'package:drift/drift.dart' show Value;
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
import 'package:srisurart_pos/core/errors/pos_exception.dart';
import 'package:srisurart_pos/core/utils/tax_identity.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api_settings_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/settings_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/settings_screen.dart';
import 'package:srisurart_pos/presentation/widgets/app_text_field.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/sales_tax_report_section.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

import 'support/fake_sync_facade.dart';

/// Last month at [day] [hour]:00 — derived from now, never a hardcoded month.
DateTime _lastMonth(int day, int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month - 1, day, hour);
}

Future<void> _insertSale(
  AppDatabase db,
  String id,
  String receiptNo,
  int qty,
  DateTime date, {
  bool voided = false,
}) async {
  await db.into(db.sales).insert(
    SalesCompanion.insert(
      id: id,
      receiptNo: receiptNo,
      subtotal: 107.0 * qty,
      total: 107.0 * qty,
      paymentMethod: 'เงินสด',
      date: date,
      voided: Value(voided),
      voidReason: Value(voided ? 'ลูกค้ายกเลิก' : null),
      voidedAt: Value(voided ? date.add(const Duration(minutes: 5)) : null),
    ),
  );
  await db.into(db.saleItems).insert(
    SaleItemsCompanion.insert(
      saleId: id,
      productId: 'p1',
      name: 'Oil Filter',
      qty: qty,
      price: 107,
    ),
  );
}

/// Last month: RC01-2569-09-0001 (2 × ฿107), RC01-2569-09-0002 manually voided, RC01-2569-09-0003 fully returned
/// today (auto-void; its credit note is dated this month).
Future<void> _seedMonth(AppDatabase db) async {
  await _insertSale(db, 's-a1', 'RC01-2569-09-0001', 2, _lastMonth(5, 9));
  await _insertSale(db, 's-a2', 'RC01-2569-09-0002', 1, _lastMonth(5, 10), voided: true);
  await _insertSale(db, 's-a3', 'RC01-2569-09-0003', 1, _lastMonth(5, 11));
  await ReturnsRepository(db).createReturn(
    const ReturnInput(
      saleId: 's-a3',
      items: [
        ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 107),
      ],
      refundMethod: 'เงินสด',
      reason: 'ชำรุด',
    ),
  );
}

Finder _field(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(AppTextField)),
  matching: find.byType(TextFormField),
);

Widget _settingsApp(AppDatabase db, {double zoom = 1}) => MultiRepositoryProvider(
  providers: repositoryProviders(db, useApiRepositories: false),
  child: MultiBlocProvider(
    providers: [
      BlocProvider<ThemeModeCubit>(create: (_) => ThemeModeCubit()),
      BlocProvider<FontScaleCubit>(create: (_) => FontScaleCubit()),
      BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
      BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
      BlocProvider<CartCubit>(create: (_) => CartCubit()),
    ],
    child: MaterialApp(
      home: const SettingsScreen(),
      builder: (context, child) => UiZoom(zoom: zoom, child: child!),
    ),
  ),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  void setSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testWidgets('ทั่วไป: tax id + branch are validated, then saved to Drift', (
    tester,
  ) async {
    setSize(tester, const Size(1280, 1600));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await tester.pumpWidget(_settingsApp(db));
      await settle(tester);

      final taxId = _field('เลขประจำตัวผู้เสียภาษี (13 หลัก)');
      final branch = _field('สาขา (00000 = สำนักงานใหญ่)');
      expect(taxId, findsOneWidget);
      expect(branch, findsOneWidget);

      // Invalid: nothing saved, both errors shown.
      await tester.enterText(taxId, '012345678901');
      await tester.enterText(branch, '0');
      await tester.tap(find.text('บันทึกการตั้งค่า'));
      await settle(tester);
      expect(find.text(taxIdInvalidMessage), findsOneWidget);
      expect(find.text(branchNoInvalidMessage), findsOneWidget);
      var s = await SettingsRepository(db).getSettings();
      expect(s.taxId, isNull);
      expect(s.branchNo, isNull);

      // Valid (separators allowed): stored as 13 digits / 5 digits.
      await tester.enterText(taxId, '0-1234-56789-01-2');
      await tester.enterText(branch, '00000');
      await tester.tap(find.text('บันทึกการตั้งค่า'));
      await settle(tester);
      expect(find.text(taxIdInvalidMessage), findsNothing);
      expect(find.text(branchNoInvalidMessage), findsNothing);
      s = await SettingsRepository(db).getSettings();
      expect(s.taxId, '0123456789012');
      expect(s.branchNo, '00000');

      // Emptying clears them.
      await tester.enterText(taxId, '');
      await tester.enterText(branch, '');
      await tester.tap(find.text('บันทึกการตั้งค่า'));
      await settle(tester);
      s = await SettingsRepository(db).getSettings();
      expect(s.taxId, isNull);
      expect(s.branchNo, isNull);
      await db.close();
    });
  });

  testWidgets('ทั่วไป: an untouched legacy tax id does not block saving', (
    tester,
  ) async {
    setSize(tester, const Size(1280, 1600));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await SettingsRepository(db).updateSettings(
        const SettingsRowCompanion(taxId: Value('12345'), branchNo: Value('1')),
      );
      await tester.pumpWidget(_settingsApp(db));
      await settle(tester);
      await tester.enterText(_field('เบอร์โทร'), '077-123456');
      await tester.tap(find.text('บันทึกการตั้งค่า'));
      await settle(tester);
      expect(find.text(taxIdInvalidMessage), findsNothing);
      expect(find.text(branchNoInvalidMessage), findsNothing);
      final s = await SettingsRepository(db).getSettings();
      expect(s.phone, '077-123456');
      expect(s.taxId, '12345'); // left as it was, not sent
      expect(s.branchNo, '1');

      // Once edited, it is validated.
      await tester.enterText(_field('เลขประจำตัวผู้เสียภาษี (13 หลัก)'), '123456');
      await tester.tap(find.text('บันทึกการตั้งค่า'));
      await settle(tester);
      expect(find.text(taxIdInvalidMessage), findsOneWidget);
      await db.close();
    });
  });

  group('API build', () {
    test('Degraded: tax id edit refused, no PATCH, Drift untouched', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      var calls = 0;
      final repo = ApiSettingsRepository(
        db,
        ApiClient(
          httpClient: MockClient((_) async {
            calls++;
            return http.Response('{}', 500);
          }),
        ),
        syncFacade: FakeSyncFacade(initialStatus: SyncStatus.degraded),
      );
      await expectLater(
        repo.updateSettings(
          const SettingsRowCompanion(
            taxId: Value('0123456789012'),
            branchNo: Value('00000'),
          ),
        ),
        throwsA(
          isA<PosException>().having(
            (e) => e.toString(),
            'message',
            contains(settingsOfflineRefusal),
          ),
        ),
      );
      expect(calls, 0);
      final s = await repo.getSettings();
      expect(s.taxId, isNull);
      expect(s.branchNo, isNull);
    });

    test('online: PATCH carries both fields; Drift takes the reply only', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      Object? sent;
      final repo = ApiSettingsRepository(
        db,
        ApiClient(
          httpClient: MockClient((req) async {
            sent = req.body;
            return http.Response(
              '{"status":"success","data":{"shopName":"ร้าน","shopNameEn":"",'
              '"taxRate":7,"quoteValidDays":30,"address":null,"phone":null,'
              '"cashierName":null,"taxId":"0123456789012","branchNo":"00001",'
              '"updatedAt":"2026-10-23T03:00:00.000Z"}}',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
        syncFacade: FakeSyncFacade(),
      );
      await repo.updateSettings(
        const SettingsRowCompanion(
          taxId: Value('0123456789012'),
          branchNo: Value('00000'),
        ),
      );
      expect(sent, contains('"taxId":"0123456789012"'));
      expect(sent, contains('"branchNo":"00000"'));
      final s = await repo.getSettings();
      expect(s.taxId, '0123456789012');
      expect(s.branchNo, '00001'); // the server's reply, not the request
    });
  });

  testWidgets('report: real Drift rows — manual void out, auto-void in, CN next month', (
    tester,
  ) async {
    setSize(tester, const Size(1280, 2000));
    final db = AppDatabase(NativeDatabase.memory());
    List<List<Object?>>? rows;
    String? filename;
    await tester.runAsync(() async {
      await _seedMonth(db);
      await SettingsRepository(db).updateSettings(
        const SettingsRowCompanion(
          taxId: Value('0123456789012'),
          branchNo: Value('00000'),
        ),
      );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SalesTaxReportSection(
                  onDownloadCsv: (r, f) async {
                    rows = r;
                    filename = f;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      // Default month = last month. RC01-2569-09-0002 (manual void) is out of the money
      // and named; RC01-2569-09-0003 (auto-void) stays: 3 × ฿107 = ฿321, VAT ฿21.
      expect(find.textContaining('RC01-2569-09-0001–RC01-2569-09-0003'), findsOneWidget);
      expect(find.textContaining('ยกเลิก (ไม่นับ): RC01-2569-09-0002'), findsOneWidget);
      expect(find.textContaining('อ้างอิง RC01-2569-09-0003'), findsNothing); // CN is next month
      expect(find.text('฿21.00'), findsOneWidget); // ช่อง 5
      expect(find.text('฿300.00'), findsNWidgets(2)); // ช่อง 1 + ช่อง 4
      expect(find.textContaining('0-1234-56789-01-2'), findsOneWidget);
      expect(find.textContaining('สำนักงานใหญ่'), findsWidgets);
      expect(find.text(salesTaxDisclaimer), findsOneWidget);
      expect(find.textContaining('อย่างย่อ'), findsNothing);

      await tester.tap(find.text('⬇ ดาวน์โหลด CSV'));
      await settle(tester);
      final last = _lastMonth(1, 0);
      expect(
        filename,
        'sales-tax-${last.year}-${last.month.toString().padLeft(2, '0')}.csv',
      );
      expect(rows!.last, ['ยอดขายรวม VAT สุทธิ', '321.00']);

      // This month: only RC01-2569-09-0003's credit note, negative.
      await tester.tap(find.byTooltip('เดือนถัดไป'));
      await settle(tester);
      expect(find.textContaining('· อ้างอิง RC01-2569-09-0003'), findsOneWidget);
      expect(find.textContaining('RC01-2569-09-0001'), findsNothing);
      expect(find.text('฿-7.00'), findsWidgets);
      expect(find.text('฿-100.00'), findsWidgets);
      // Cannot go past the current month.
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right_rounded),
      );
      expect(next.onPressed, isNull);
      await db.close();
    });
  });

  for (final (label, size, zoom) in const [
    ('phone 390', Size(390, 844), 1.0),
    ('zoom 3x full HD', Size(1920, 1080), 3.0),
    ('zoom 2x laptop', Size(1366, 768), 2.0),
  ]) {
    testWidgets('settings tax fields + report lay out: $label', (tester) async {
      setSize(tester, size);
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _seedMonth(db);
        await SettingsRepository(db).updateSettings(
          const SettingsRowCompanion(
            taxId: Value('0123456789012'),
            branchNo: Value('00001'),
          ),
        );
        await tester.pumpWidget(_settingsApp(db, zoom: zoom));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'general tab');
        await tester.ensureVisible(_field('สาขา (00000 = สำนักงานใหญ่)'));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'tax fields');

        await tester.ensureVisible(find.text('📤 ส่งออก CSV'));
        await settle(tester);
        await tester.tap(find.text('📤 ส่งออก CSV'));
        await settle(tester);
        await tester.ensureVisible(find.text('⬇ ดาวน์โหลด CSV'));
        await settle(tester);
        expect(find.textContaining('RC01-2569-09-0001–RC01-2569-09-0003'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'last month');

        await tester.ensureVisible(find.byTooltip('เดือนถัดไป'));
        await tester.tap(find.byTooltip('เดือนถัดไป'));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'this month (CN)');
        await db.close();
      });
    });
  }
}
