// The sale-photo capture sheet and the read-only strip
// (10_SALE_PHOTO_EVIDENCE.md §2.2–§2.5), driven against FakeSalePhotosRepository
// with injected photo sources (no platform channels).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:srisurart_pos/data/repositories/fake_sale_photos_repository.dart';
import 'package:srisurart_pos/data/repositories/sale_photos_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/widgets/app_button.dart';
import 'package:srisurart_pos/presentation/widgets/sale_photo_sheet.dart';
import 'package:srisurart_pos/presentation/widgets/sale_photo_strip.dart';

import 'support/fake_sync_facade.dart';

const _sale = '0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b';

// A real 1x1 PNG so Image.memory has something to decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('th', null);
  });

  late FakeSalePhotosRepository repo;
  late int picks;
  late bool? lastResult;

  setUp(() {
    repo = FakeSalePhotosRepository();
    picks = 0;
    lastResult = null;
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(800, 1000),
    bool withCamera = false,
    SyncStatus status = SyncStatus.online,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final sources = SalePhotoSources(
      camera: withCamera
          ? () async => Uint8List.fromList([..._png, picks++])
          : null,
      files: () async => Uint8List.fromList([..._png, picks++]),
      shrink: (b) async => b,
    );
    await tester.pumpWidget(
      RepositoryProvider<SyncFacade>.value(
        value: FakeSyncFacade(initialStatus: status),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    lastResult = await showSalePhotoSheet(
                      context,
                      repo: repo,
                      saleId: _sale,
                      receiptNo: 'RC01-2569-10-0042',
                      sources: sources,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
  }

  Future<void> addFile(WidgetTester t) async {
    await t.ensureVisible(find.byKey(const Key('sale-photo-files')));
    await t.pump();
    await t.tap(find.byKey(const Key('sale-photo-files')));
    await _settle(t);
  }

  Finder tiles() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('sale-photo-tile-'),
  );
  AppButton button(WidgetTester t, String key) =>
      t.widget<AppButton>(find.byKey(Key(key)));

  testWidgets('add, remove and the 5-photo limit', (tester) async {
    await open(tester);
    expect(find.text('ข้าม'), findsOneWidget);
    expect(
      button(tester, 'sale-photo-save').onPressed,
      isNull,
      reason: 'nothing to save yet',
    );

    await addFile(tester);
    await addFile(tester);
    expect(tiles(), findsNWidgets(2));
    expect(find.text('2 / 5 รูป'), findsOneWidget);
    expect(find.text('บันทึก 2 รูป'), findsOneWidget);

    // ✕ drops a not-yet-sent photo without asking.
    final first = tester.widget<Widget>(tiles().first).key as ValueKey<String>;
    final id = first.value.replaceFirst('sale-photo-tile-', '');
    await tester.tap(find.byKey(Key('sale-photo-remove-$id')));
    await _settle(tester);
    expect(tiles(), findsOneWidget);

    for (var i = 0; i < 4; i++) {
      await addFile(tester);
    }
    expect(tiles(), findsNWidgets(5));
    expect(find.text('ครบ 5 รูปแล้ว'), findsOneWidget);
    expect(button(tester, 'sale-photo-files').onPressed, isNull);
    expect(find.byKey(const Key('sale-photo-add-tile')), findsNothing);
    expect(picks, 6, reason: 'a sixth pick is never even started');
  });

  testWidgets('the camera button exists only where the platform has a camera', (
    tester,
  ) async {
    await open(tester, withCamera: false);
    expect(find.byKey(const Key('sale-photo-camera')), findsNothing);
    expect(find.byKey(const Key('sale-photo-files')), findsOneWidget);
  });

  testWidgets('บันทึก uploads in order, then closes with true', (tester) async {
    await open(tester, withCamera: true);
    await tester.tap(find.byKey(const Key('sale-photo-camera')));
    await _settle(tester);
    await addFile(tester);
    await tester.tap(find.byKey(const Key('sale-photo-save')));
    await _settle(tester);
    await _settle(tester);
    expect(repo.calls.map((c) => c.sortOrder), [0, 1]);
    expect(
      repo.calls.map((c) => c.key),
      everyElement(startsWith('salephoto-')),
    );
    expect(repo.stored(_sale), hasLength(2));
    expect(lastResult, isTrue);
    expect(find.text('รูปหลักฐานสินค้า'), findsNothing, reason: 'sheet closed');
  });

  testWidgets(
    'a 5xx keeps the sheet open; ลองอีกครั้ง resends the SAME photoId + key',
    (tester) async {
      repo.failures.add(FakeSalePhotosRepository.serverDown);
      await open(tester);
      await addFile(tester);
      await addFile(tester);
      await tester.tap(find.byKey(const Key('sale-photo-save')));
      await _settle(tester);

      expect(repo.calls, hasLength(1), reason: 'stops at the first failure');
      expect(find.text('รูปหลักฐานสินค้า'), findsOneWidget);
      expect(
        find.text('รูป 1: เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'),
        findsOneWidget,
      );
      // Bottom buttons become ลองอีกครั้ง / ปิด.
      expect(find.text('ปิด'), findsWidgets);
      expect(
        find.text('ลองอีกครั้ง'),
        findsNWidgets(2),
        reason: 'the tile and the bottom button',
      );

      await tester.tap(find.byKey(const Key('sale-photo-save')));
      await _settle(tester);
      await _settle(tester);
      expect(repo.calls, hasLength(3));
      expect(repo.calls[1].photoId, repo.calls[0].photoId);
      expect(repo.calls[1].key, repo.calls[0].key);
      expect(repo.stored(_sale), hasLength(2));
      expect(lastResult, isTrue);
    },
  );

  testWidgets('a 4xx verdict has no retry — it can only be removed', (
    tester,
  ) async {
    repo.failures.add(FakeSalePhotosRepository.limit);
    await open(tester);
    await addFile(tester);
    await tester.tap(find.byKey(const Key('sale-photo-save')));
    await _settle(tester);

    expect(find.text('รูป 1: บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว'), findsOneWidget);
    expect(find.text('ลองอีกครั้ง'), findsNothing);
    expect(button(tester, 'sale-photo-save').onPressed, isNull);
    final tile = tester.widget<Widget>(tiles().first).key as ValueKey<String>;
    final id = tile.value.replaceFirst('sale-photo-tile-', '');
    await tester.tap(find.byKey(Key('sale-photo-remove-$id')));
    await _settle(tester);
    expect(tiles(), findsNothing);
  });

  testWidgets('a saved photo has no ✕', (tester) async {
    repo.failures.addAll([null, FakeSalePhotosRepository.serverDown]);
    await open(tester);
    await addFile(tester);
    await addFile(tester);
    await tester.tap(find.byKey(const Key('sale-photo-save')));
    await _settle(tester);
    final ids = [
      for (final e in tiles().evaluate())
        (e.widget.key as ValueKey<String>).value.replaceFirst(
          'sale-photo-tile-',
          '',
        ),
    ];
    expect(
      find.byKey(Key('sale-photo-remove-${ids[0]}')),
      findsNothing,
      reason: 'saved',
    );
    expect(
      find.byKey(Key('sale-photo-remove-${ids[1]}')),
      findsOneWidget,
      reason: 'failed, not yet saved',
    );
  });

  testWidgets('closing with unsent photos asks first; ยกเลิก keeps the sheet', (
    tester,
  ) async {
    await open(tester);
    await addFile(tester);
    await addFile(tester);
    await tester.tap(find.byKey(const Key('sale-photo-skip')));
    await _settle(tester);
    expect(find.text('ปิดโดยไม่บันทึกรูปที่เหลือ?'), findsOneWidget);
    expect(find.text('รูปที่ยังไม่ได้บันทึก 2 รูปจะหายไป'), findsOneWidget);
    await tester.tap(find.text('ยกเลิก'));
    await _settle(tester);
    expect(find.text('รูปหลักฐานสินค้า'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sale-photo-skip')));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'ปิด'));
    await _settle(tester);
    expect(find.text('รูปหลักฐานสินค้า'), findsNothing);
    expect(lastResult, isFalse);
    expect(repo.calls, isEmpty);
  });

  testWidgets('ข้าม with nothing captured closes straight away', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('sale-photo-skip')));
    await _settle(tester);
    expect(find.text('รูปหลักฐานสินค้า'), findsNothing);
    expect(lastResult, isFalse);
  });

  testWidgets(
    'works at 360 px (full-screen, the logical width of 3x zoom on 1080)',
    (tester) async {
      await open(tester, size: const Size(360, 640), withCamera: true);
      for (var i = 0; i < 4; i++) {
        await addFile(tester);
      }
      expect(tiles(), findsNWidgets(4));
      expect(tester.takeException(), isNull);
      // Full-screen below 600: the sheet fills the width.
      expect(
        tester.getSize(find.byKey(const Key('sale-photo-save'))).width,
        lessThan(360),
      );
    },
  );

  for (final size in const [Size(640, 360), Size(683, 384)]) {
    testWidgets(
      'five photos and a failure lay out at the logical size of 3x/2x zoom $size',
      (tester) async {
        repo.failures.add(FakeSalePhotosRepository.serverDown);
        await open(tester, size: size, withCamera: true);
        for (var i = 0; i < 5; i++) {
          await addFile(tester);
        }
        await tester.tap(find.byKey(const Key('sale-photo-save')));
        await _settle(tester);
        expect(find.byKey(const Key('sale-photo-save')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the Reports bill sheet lays out at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      repo.seed(
        _sale,
        SalePhoto(
          id: 'p0',
          saleId: _sale,
          sortOrder: 0,
          width: 1,
          height: 1,
          takenAt: DateTime(2026, 10, 12, 14, 5),
          createdAt: DateTime(2026, 10, 12, 14, 5),
        ),
        _png,
      );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SalePhotosRepository?>.value(value: repo),
            RepositoryProvider<SyncFacade>.value(value: FakeSyncFacade()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showSaleBillSheet(
                    context,
                    saleId: _sale,
                    receiptNo: 'RC01-2569-10-0042',
                    date: DateTime(2026, 10, 12, 14, 5),
                    paymentMethod: 'เครดิตช่าง',
                    totalText: '฿123,456.00',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.text('RC01-2569-10-0042'), findsOneWidget);
      expect(find.byKey(const Key('sale-photo-thumb-p0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  group('SalePhotoStrip', () {
    Future<void> pumpStrip(
      WidgetTester tester, {
      SyncStatus status = SyncStatus.online,
      SalePhotosRepository? provided,
    }) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SalePhotosRepository?>.value(
              value: provided ?? repo,
            ),
            RepositoryProvider<SyncFacade>.value(
              value: FakeSyncFacade(initialStatus: status),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SalePhotoStrip(saleId: _sale)),
          ),
        ),
      );
      await _settle(tester);
    }

    void seed(int n) {
      for (var i = 0; i < n; i++) {
        repo.seed(
          _sale,
          SalePhoto(
            id: 'p$i',
            saleId: _sale,
            sortOrder: i,
            width: 1,
            height: 1,
            takenAt: DateTime(2026, 10, 12, 14, 5),
            createdAt: DateTime(2026, 10, 12, 14, 5),
          ),
          _png,
        );
      }
    }

    testWidgets('shows the thumbnails with a count; a tap opens the viewer', (
      tester,
    ) async {
      seed(3);
      await pumpStrip(tester);
      expect(find.text('รูปหลักฐานตอนขาย (3)'), findsOneWidget);
      expect(find.byKey(const Key('sale-photo-thumb-p1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sale-photo-thumb-p1')));
      await _settle(tester);
      expect(find.byKey(const Key('sale-photo-viewer-title')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-photo-viewer-title')))
            .data,
        startsWith('รูป 2/3 · ถ่ายเมื่อ'),
      );
    });

    testWidgets('empty bill', (tester) async {
      await pumpStrip(tester);
      expect(find.text('บิลนี้ไม่มีรูปหลักฐาน'), findsOneWidget);
    });

    testWidgets('Degraded: says so and asks the server nothing', (
      tester,
    ) async {
      seed(1);
      await pumpStrip(tester, status: SyncStatus.degraded);
      expect(
        find.text('ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sale-photo-thumb-p0')), findsNothing);
    });

    testWidgets(
      'a failed load shows โหลดรูปไม่สำเร็จ and ลองอีกครั้ง reloads',
      (tester) async {
        seed(1);
        repo.readFailure = FakeSalePhotosRepository.serverDown;
        await pumpStrip(tester);
        expect(find.text('โหลดรูปไม่สำเร็จ'), findsOneWidget);
        repo.readFailure = null;
        await tester.tap(find.byKey(const Key('sale-photo-strip-retry')));
        await _settle(tester);
        expect(find.byKey(const Key('sale-photo-thumb-p0')), findsOneWidget);
      },
    );

    testWidgets('no repository (Drift build): nothing at all', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SalePhotosRepository?>.value(value: null),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SalePhotoStrip(saleId: _sale)),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });
  });
}
