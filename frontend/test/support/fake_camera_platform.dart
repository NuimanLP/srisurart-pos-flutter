// A fake `camera` platform for widget tests of the in-app sale-photo camera:
// set `CameraPlatform.instance = FakeCameraPlatform()`. It records every camera
// opened and released, and can fail the camera list or the open.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/widgets.dart';

/// A real 1x1 PNG, returned as every "photo".
final fakeCameraPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const fakeFrontCamera = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 0,
);
const fakeBackCamera = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 0,
);

class FakeCameraPlatform extends CameraPlatform {
  List<CameraDescription> cameras = const [fakeFrontCamera, fakeBackCamera];
  Object? availableError;
  Object? initError;

  /// When set, every initialize waits for it (to test a close mid-open).
  Completer<void>? initGate;
  final created = <CameraDescription>[];
  final settings = <MediaSettings>[];
  final disposed = <int>[];
  int shots = 0;
  int _nextId = 0;
  final _initialized = StreamController<CameraInitializedEvent>.broadcast();
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  /// Cameras opened and not yet released.
  int get open => created.length - disposed.length;

  @override
  Future<List<CameraDescription>> availableCameras() async {
    if (availableError != null) throw availableError!;
    return cameras;
  }

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async {
    created.add(cameraDescription);
    settings.add(mediaSettings!);
    return ++_nextId;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream.where((e) => e.cameraId == cameraId);

  // Never emits, never closes: CameraController waits on `.first`.
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    if (initGate != null) await initGate!.future;
    if (initError != null) throw initError!;
    _initialized.add(
      CameraInitializedEvent(
        cameraId,
        1920,
        1080,
        ExposureMode.auto,
        true,
        FocusMode.auto,
        true,
      ),
    );
  }

  @override
  Widget buildPreview(int cameraId) =>
      SizedBox.expand(key: Key('fake-preview-$cameraId'));

  @override
  Future<XFile> takePicture(int cameraId) async {
    shots++;
    return XFile.fromData(
      Uint8List.fromList(fakeCameraPng),
      name: 'shot$shots.jpg',
    );
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposed.add(cameraId);
  }
}
