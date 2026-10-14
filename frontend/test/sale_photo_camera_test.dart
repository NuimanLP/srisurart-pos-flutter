// The in-app sale-photo camera (10_SALE_PHOTO_EVIDENCE.md §2.2), driven
// against a fake CameraPlatform: the camera choice, the multi-shot session,
// every failure state, and that the camera is always released.

import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/presentation/widgets/sale_photo_camera.dart';

import 'support/fake_camera_platform.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late FakeCameraPlatform fake;
  late List<Uint8List> got;
  late bool closed;
  String? dropReason; // what the fake sheet answers for each shot
  late CameraPlatform original;

  setUpAll(() {
    original = CameraPlatform.instance;
  });

  setUp(() {
    fake = FakeCameraPlatform();
    CameraPlatform.instance = fake;
    got = [];
    closed = false;
    dropReason = null;
  });

  tearDown(() {
    CameraPlatform.instance = original;
  });

  Future<void> open(
    WidgetTester tester, {
    int count = 0,
    Size size = const Size(800, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                await showSalePhotoCamera(
                  context,
                  count: count,
                  limit: 5,
                  onShot: (b) async {
                    got.add(b);
                    return dropReason;
                  },
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
  }

  Finder shutter() => find.byKey(const Key('sale-camera-shutter'));
  bool shutterEnabled(WidgetTester t) =>
      t.widget<InkResponse>(shutter()).onTap != null;

  testWidgets('opens the back camera, without audio, with a live preview', (
    tester,
  ) async {
    await open(tester);
    expect(fake.created, [fakeBackCamera]);
    expect(fake.settings.single.enableAudio, isFalse);
    expect(find.byKey(const Key('fake-preview-1')), findsOneWidget);
    expect(find.byKey(const Key('sale-camera-switch')), findsOneWidget);
    expect(shutterEnabled(tester), isTrue);
    expect(find.text('0 / 5 รูป'), findsOneWidget);
  });

  testWidgets('several shots in one session; closes itself when full', (
    tester,
  ) async {
    await open(tester, count: 3);
    expect(find.text('3 / 5 รูป'), findsOneWidget);
    await tester.tap(shutter());
    await _settle(tester);
    expect(got, hasLength(1), reason: 'handed over at once, no confirm step');
    expect(find.text('4 / 5 รูป'), findsOneWidget);
    expect(find.byKey(const Key('sale-camera-last')), findsOneWidget);
    expect(closed, isFalse);

    await tester.tap(shutter());
    await _settle(tester);
    expect(got, hasLength(2));
    expect(closed, isTrue, reason: 'the sheet is full');
    expect(fake.open, 0, reason: 'camera released on close');
  });

  testWidgets('a shot the sheet drops is not counted, and says why', (
    tester,
  ) async {
    await open(tester, count: 4);
    dropReason = 'อ่านรูปไม่ได้';
    await tester.tap(shutter());
    await _settle(tester);
    expect(got, hasLength(1));
    expect(find.text('4 / 5 รูป'), findsOneWidget, reason: 'not counted');
    expect(find.text('อ่านรูปไม่ได้'), findsOneWidget);
    expect(closed, isFalse, reason: 'no auto-close on a dropped shot');

    dropReason = null;
    await tester.tap(shutter());
    await _settle(tester);
    expect(closed, isTrue, reason: 'the fifth kept photo fills the sheet');
  });

  testWidgets('✕ while the camera is still opening releases it, no error', (
    tester,
  ) async {
    fake.initGate = Completer<void>();
    await open(tester);
    expect(find.text('กำลังเปิดกล้อง…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sale-camera-close')));
    await _settle(tester);
    expect(closed, isTrue);
    fake.initGate!.complete();
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(fake.created, hasLength(1));
    expect(fake.open, 0, reason: 'the late open was released');
  });

  testWidgets('✕ closes and releases the camera', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('sale-camera-close')));
    await _settle(tester);
    expect(closed, isTrue);
    expect(got, isEmpty);
    expect(fake.open, 0);
  });

  testWidgets('switch opens the other camera and releases the first', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('sale-camera-switch')));
    await _settle(tester);
    expect(fake.created, [fakeBackCamera, fakeFrontCamera]);
    expect(fake.disposed, [1]);
    expect(find.byKey(const Key('fake-preview-2')), findsOneWidget);
  });

  testWidgets('one camera: no switch button', (tester) async {
    fake.cameras = const [fakeFrontCamera];
    await open(tester);
    expect(fake.created, [
      fakeFrontCamera,
    ], reason: 'no back camera: take what exists');
    expect(find.byKey(const Key('sale-camera-switch')), findsNothing);
  });

  testWidgets('no camera: says so, shutter disabled, nothing opened', (
    tester,
  ) async {
    fake.cameras = const [];
    await open(tester);
    expect(find.byKey(const Key('sale-camera-error')), findsOneWidget);
    expect(find.text('ไม่พบกล้อง'), findsOneWidget);
    expect(find.byKey(const Key('sale-camera-retry')), findsNothing);
    expect(shutterEnabled(tester), isFalse);
    expect(fake.created, isEmpty);
  });

  testWidgets('permission denied (native): message, camera released, retry', (
    tester,
  ) async {
    fake.initError = PlatformException(code: 'CameraAccessDenied');
    await open(tester);
    expect(find.text('ไม่ได้รับอนุญาตให้ใช้กล้อง'), findsOneWidget);
    expect(shutterEnabled(tester), isFalse);
    expect(fake.open, 0, reason: 'a failed open is released too');

    fake.initError = null;
    await tester.tap(find.byKey(const Key('sale-camera-retry')));
    await _settle(tester);
    expect(find.byKey(const Key('sale-camera-error')), findsNothing);
    expect(shutterEnabled(tester), isTrue);
  });

  testWidgets('permission denied (browser): the same message', (tester) async {
    fake.availableError = CameraException('NotAllowedError', 'denied');
    await open(tester);
    expect(find.text('ไม่ได้รับอนุญาตให้ใช้กล้อง'), findsOneWidget);
    expect(fake.created, isEmpty);
  });

  testWidgets('a platform with no camera plugin: a message, not a crash', (
    tester,
  ) async {
    fake.availableError = MissingPluginException('no camera on desktop');
    await open(tester);
    expect(find.text('เปิดกล้องไม่ได้'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the camera is released while the app is hidden', (tester) async {
    await open(tester);
    expect(fake.open, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await _settle(tester);
    expect(fake.open, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(fake.open, 1);
    expect(fake.created, hasLength(2));
    expect(shutterEnabled(tester), isTrue);
  });

  for (final size in const [Size(360, 640), Size(640, 360), Size(569, 320)]) {
    testWidgets('lays out at the zoomed logical size $size', (tester) async {
      await open(tester, size: size);
      await tester.tap(shutter());
      await _settle(tester);
      expect(tester.takeException(), isNull);
      fake.cameras = const [];
      await tester.tap(find.byKey(const Key('sale-camera-close')));
      await _settle(tester);
    });
  }
}
