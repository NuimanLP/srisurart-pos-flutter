// The sale-photo capture sheet and the read-only strip
// (10_SALE_PHOTO_EVIDENCE.md §2.2–§2.5), driven against FakeSalePhotosRepository
// with injected photo sources (no platform channels).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
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
  late int cameraShots;
  late List<int> cameraOpens;

  setUp(() {
    repo = FakeSalePhotosRepository();
    picks = 0;
    lastResult = null;
    cameraShots = 1;
    cameraOpens = [];
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(800, 1000),
    SyncStatus status = SyncStatus.online,
    Future<Uint8List> Function(Uint8List)? shrink,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final sources = SalePhotoSources(
      // The fake camera takes [cameraShots] photos per open (capped by the
      // room left, as the real one closes itself when the sheet is full).
      camera:
          (context, {required count, required limit, required onShot}) async {
            cameraOpens.add(count);
            for (var i = 0; i < cameraShots && count + i < limit; i++) {
              await onShot(Uint8List.fromList([..._png, picks++]));
            }
          },
      files: () async => Uint8List.fromList([..._png, picks++]),
      shrink: shrink ?? (b) async => b,
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
    expect(button(tester, 'sale-photo-camera').onPressed, isNull);
    expect(picks, 6, reason: 'a sixth pick is never even started');
  });

  testWidgets('exactly two actions: ถ่ายรูป and เลือกรูปจากเครื่อง', (
    tester,
  ) async {
    await open(tester);
    expect(button(tester, 'sale-photo-camera').label, 'ถ่ายรูป');
    expect(button(tester, 'sale-photo-files').label, 'เลือกรูปจากเครื่อง');
    expect(find.text('เพิ่มรูป'), findsNothing, reason: 'no duplicate tile');
    expect(find.text('เลือกรูป'), findsNothing);
    expect(tiles(), findsNothing);
  });

  testWidgets('both actions add tiles; one camera session adds several', (
    tester,
  ) async {
    await open(tester);
    await addFile(tester);
    expect(tiles(), findsOneWidget);

    cameraShots = 3;
    await tester.tap(find.byKey(const Key('sale-photo-camera')));
    await _settle(tester);
    expect(cameraOpens, [1], reason: 'the camera knows what is already in');
    expect(tiles(), findsNWidgets(4));

    // The camera stops at the limit even when more shots are asked for.
    await tester.tap(find.byKey(const Key('sale-photo-camera')));
    await _settle(tester);
    expect(tiles(), findsNWidgets(5));
    expect(find.text('ครบ 5 รูปแล้ว'), findsOneWidget);
    expect(button(tester, 'sale-photo-camera').onPressed, isNull);
  });

  testWidgets('the two actions stack on a narrow sheet', (tester) async {
    await open(tester, size: const Size(360, 640));
    final cam = tester.getTopLeft(find.byKey(const Key('sale-photo-camera')));
    final files = tester.getTopLeft(find.byKey(const Key('sale-photo-files')));
    expect(files.dy, greaterThan(cam.dy));
    expect(files.dx, cam.dx);
  });

  testWidgets('บันทึก uploads in order, then closes with true', (tester) async {
    await open(tester);
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
      findsNothing,
      reason: 'a retryable upload may already be on the server: no ✕',
    );
  });

  group('order', () {
    List<String> ids(WidgetTester t) => [
      for (final e in tiles().evaluate())
        (e.widget.key as ValueKey<String>).value.replaceFirst(
          'sale-photo-tile-',
          '',
        ),
    ];

    Future<void> save(WidgetTester t) async {
      await t.tap(find.byKey(const Key('sale-photo-save')));
      await _settle(t);
      await _settle(t);
    }

    Finder draggables() =>
        find.byWidgetPredicate((w) => w is LongPressDraggable);

    Map<String, int> sentOrder() => {
      for (final c in repo.calls) c.photoId: c.sortOrder,
    };

    testWidgets('◀ ▶ reorder before บันทึก changes the sent sortOrders', (
      tester,
    ) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await addFile(tester);
      }
      final [a, b, c] = ids(tester);
      expect(find.byKey(const Key('sale-photo-reorder-hint')), findsOneWidget);
      expect(find.byKey(Key('sale-photo-left-$a')), findsNothing);
      expect(find.byKey(Key('sale-photo-right-$c')), findsNothing);

      await tester.tap(find.byKey(Key('sale-photo-left-$c')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('sale-photo-left-$c')));
      await _settle(tester);
      expect(ids(tester), [c, a, b]);

      await save(tester);
      expect(sentOrder(), {c: 0, a: 1, b: 2});
      expect(repo.calls.map((x) => x.photoId), [c, a, b]);
    });

    testWidgets('long-press drag onto another tile moves it there', (
      tester,
    ) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await addFile(tester);
      }
      final [a, b, c] = ids(tester);
      final from = tester.getCenter(find.byKey(Key('sale-photo-tile-$a')));
      final to = tester.getCenter(find.byKey(Key('sale-photo-tile-$c')));
      final g = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await _settle(tester);
      expect(ids(tester), [b, c, a]);

      await save(tester);
      expect(sentOrder(), {b: 0, c: 1, a: 2});
    });

    testWidgets('reorder is locked once บันทึก has been pressed', (
      tester,
    ) async {
      repo.failures.addAll([null, FakeSalePhotosRepository.serverDown]);
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await addFile(tester);
      }
      final [_, _, c] = ids(tester);
      expect(find.byKey(Key('sale-photo-left-$c')), findsOneWidget);
      expect(draggables(), findsNWidgets(3));
      await save(tester);
      expect(find.byKey(const Key('sale-photo-reorder-hint')), findsNothing);
      for (final id in ids(tester)) {
        expect(find.byKey(Key('sale-photo-left-$id')), findsNothing);
        expect(find.byKey(Key('sale-photo-right-$id')), findsNothing);
      }
      expect(draggables(), findsNothing);
    });

    testWidgets('a retry after a reorder resends the frozen sortOrder', (
      tester,
    ) async {
      repo.failures.add(FakeSalePhotosRepository.serverDown);
      await open(tester);
      await addFile(tester);
      await addFile(tester);
      final [a, b] = ids(tester);
      await tester.tap(find.byKey(Key('sale-photo-left-$b')));
      await _settle(tester);
      await save(tester); // b (0) fails
      expect(repo.calls.single.photoId, b);
      expect(repo.calls.single.sortOrder, 0);

      await save(tester); // ลองอีกครั้ง
      expect(repo.calls, hasLength(3));
      expect(repo.calls[1].photoId, b);
      expect(repo.calls[1].sortOrder, 0, reason: 'frozen at first attempt');
      expect(repo.calls[1].key, repo.calls[0].key);
      expect(sentOrder(), {b: 0, a: 1});
    });

    testWidgets('a photo added after a partial save takes the next sortOrder', (
      tester,
    ) async {
      repo.failures.addAll([null, FakeSalePhotosRepository.serverDown]);
      await open(tester);
      await addFile(tester);
      await addFile(tester);
      await save(tester); // first saved (0), second retryable (1)
      await addFile(tester);
      final [a, b, c] = ids(tester);
      expect(
        find.byKey(Key('sale-photo-left-$c')),
        findsNothing,
        reason: 'still locked',
      );
      await save(tester);
      expect(sentOrder(), {a: 0, b: 1, c: 2});
      expect(repo.stored(_sale).map((p) => p.sortOrder).toSet(), {0, 1, 2});
    });

    testWidgets('a removed 4xx photo frees its sortOrder for the next one', (
      tester,
    ) async {
      repo.failures.addAll([
        null,
        null,
        null,
        null,
        FakeSalePhotosRepository.limit,
      ]);
      await open(tester);
      for (var i = 0; i < 5; i++) {
        await addFile(tester);
      }
      await save(tester); // 0–3 saved, 4 refused for good
      final last = ids(tester).last;
      await tester.tap(find.byKey(Key('sale-photo-remove-$last')));
      await _settle(tester);
      await addFile(tester);
      final added = ids(tester).last;
      await save(tester);
      expect(sentOrder()[added], 4);
    });

    testWidgets('a refused FIRST photo: later sortOrders never reach 5', (
      tester,
    ) async {
      repo.failures.add(FakeSalePhotosRepository.limit); // A refused
      await open(tester);
      for (var i = 0; i < 5; i++) {
        await addFile(tester);
      }
      final [a, b, c, d, e] = ids(tester);
      await save(tester); // A (0) refused; the send stops there
      await save(tester); // B–E
      await tester.tap(find.byKey(Key('sale-photo-remove-$a')));
      await _settle(tester);
      await addFile(tester);
      final f = ids(tester).last;
      await save(tester);

      final sent = sentOrder();
      expect(sent.values, everyElement(inInclusiveRange(0, 4)));
      expect(
        {
          for (final id in [b, c, d, e, f]) sent[id],
        },
        {0, 1, 2, 3, 4},
      );
      expect(repo.stored(_sale), hasLength(5));
      expect(find.text('รูปหลักฐานสินค้า'), findsNothing, reason: 'all saved');
    });
  });

  group('a photo still being shrunk', () {
    testWidgets('can be removed, and its late result is dropped', (
      tester,
    ) async {
      final gate = Completer<Uint8List>();
      await open(tester, shrink: (_) => gate.future);
      await addFile(tester);
      final tile = tester.widget<Widget>(tiles().first).key as ValueKey<String>;
      final id = tile.value.replaceFirst('sale-photo-tile-', '');
      expect(
        tester
            .widget<AppButton>(find.byKey(const Key('sale-photo-save')))
            .onPressed,
        isNull,
        reason: 'บันทึก waits for the shrink',
      );
      await tester.tap(find.byKey(Key('sale-photo-remove-$id')));
      await _settle(tester);
      expect(tiles(), findsNothing);

      gate.complete(Uint8List.fromList(_png));
      await _settle(tester);
      expect(tiles(), findsNothing, reason: 'the removed photo stays gone');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a shrink failure is shown and the photo is not kept', (
      tester,
    ) async {
      await open(
        tester,
        shrink: (_) async => throw Exception('shrink exploded'),
      );
      await addFile(tester);
      expect(tiles(), findsNothing);
      expect(find.text('shrink exploded'), findsOneWidget);
    });
  });

  testWidgets('a failing file picker is shown, not swallowed', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showSalePhotoSheet(
              context,
              repo: repo,
              saleId: _sale,
              receiptNo: 'RC',
              sources: SalePhotoSources(
                files: () async => throw Exception('picker exploded'),
                shrink: (b) async => b,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    await addFile(tester);
    expect(find.byKey(const Key('sale-photo-notice')), findsOneWidget);
    expect(find.text('picker exploded'), findsOneWidget);
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
      await open(tester, size: const Size(360, 640));
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
        await open(tester, size: size);
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

    testWidgets('shows when the first photo was taken', (tester) async {
      seed(2);
      await pumpStrip(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-photo-strip-taken')))
            .data,
        startsWith('ถ่ายเมื่อ'),
      );
    });

    testWidgets('going Degraded keeps the loaded thumbnails on screen', (
      tester,
    ) async {
      seed(2);
      final facade = FakeSyncFacade();
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SalePhotosRepository?>.value(value: repo),
            RepositoryProvider<SyncFacade>.value(value: facade),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SalePhotoStrip(saleId: _sale)),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const Key('sale-photo-thumb-p1')), findsOneWidget);
      facade.emitStatus(SyncStatus.degraded);
      await _settle(tester);
      expect(find.byKey(const Key('sale-photo-thumb-p1')), findsOneWidget);
      expect(find.byKey(const Key('sale-photo-strip-taken')), findsOneWidget);
      expect(
        find.text('ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้'),
        findsNothing,
        reason: 'every thumbnail was already loaded',
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
