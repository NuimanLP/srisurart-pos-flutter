// SalePhotoCamera — the in-app camera of the sale-photo sheet
// (10_SALE_PHOTO_EVIDENCE.md §2.2). A live viewfinder on Android, iOS and the
// web (the shop PC's webcam), via the `camera` plugin; no microphone.
//
// One open = a session: every shutter press hands the raw bytes to [onShot]
// straight away (the sheet shrinks them and gives each its photoId + key at
// once) and the view stays open for the next shot, closing itself when the
// sheet is full. No per-shot "use this photo?" step: the sheet's tiles already
// show every shot with ✕ and a full-screen view, so a confirm would only add a
// tap per photo.
//
// Every failure (no camera, permission refused, not HTTPS, camera busy, a
// platform with no camera plugin) is a Thai message inside the view, never a
// crash. The camera is released on close, on error, on a camera switch and
// while the app is hidden/paused (re-opened on resume).
//
// Tests fake the camera through `CameraPlatform.instance`.
//
// All Thai strings here are `agent ร่าง` (owner to ratify).

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'camera_access.dart'
    if (dart.library.js_interop) 'camera_access_web.dart';

const _title = 'ถ่ายรูป';
const _closeTip = 'ปิดกล้อง';
const _shutterTip = 'ถ่าย';
const _switchTip = 'สลับกล้อง';
const _starting = 'กำลังเปิดกล้อง…';
const _denied = 'ไม่ได้รับอนุญาตให้ใช้กล้อง';
const _deniedHint = 'อนุญาตให้แอปหรือเบราว์เซอร์ใช้กล้อง แล้วกด ลองอีกครั้ง';
const _noCamera = 'ไม่พบกล้อง';
const _inUse = 'กล้องถูกใช้อยู่ในโปรแกรมอื่น';
const _failed = 'เปิดกล้องไม่ได้';
const _fallbackHint = 'หรือปิดหน้านี้ แล้วใช้ปุ่ม เลือกรูปจากเครื่อง';
const _retry = 'ลองอีกครั้ง';
const _shotFailed = 'ถ่ายไม่สำเร็จ ลองกดอีกครั้ง';
String _hint(int limit) => 'ถ่ายต่อได้จนครบ $limit รูป กด ✕ เมื่อเสร็จ';

/// Opens the camera; resolves when it is closed. [count] photos are already in
/// the sheet, at most [limit]; each shot goes to [onShot] immediately.
typedef SalePhotoCamera =
    Future<void> Function(
      BuildContext context, {
      required int count,
      required int limit,
      required ValueChanged<Uint8List> onShot,
    });

Future<void> showSalePhotoCamera(
  BuildContext context, {
  required int count,
  required int limit,
  required ValueChanged<Uint8List> onShot,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog.fullscreen(
      backgroundColor: AppColors.navyDeep,
      child: SalePhotoCameraView(count: count, limit: limit, onShot: onShot),
    ),
  );
}

class SalePhotoCameraView extends StatefulWidget {
  const SalePhotoCameraView({
    super.key,
    required this.count,
    required this.limit,
    required this.onShot,
  });

  final int count;
  final int limit;
  final ValueChanged<Uint8List> onShot;

  @override
  State<SalePhotoCameraView> createState() => _SalePhotoCameraViewState();
}

class _SalePhotoCameraViewState extends State<SalePhotoCameraView>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  int _index = 0;
  CameraController? _controller;

  /// Bumped whenever a camera is released, so a late initialize that finishes
  /// after a close/switch/pause disposes itself instead of coming back.
  int _gen = 0;
  bool _ready = false;
  bool _pausedByLifecycle = false;
  bool _shooting = false;
  String? _error;
  bool _deniedError = false;
  String? _shotError;
  int _taken = 0;
  Uint8List? _last;

  int get _count => widget.count + _taken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gen++;
    unawaited(_release());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Not `inactive`: on the web that is any window blur — the permission
    // prompt itself — and releasing there would loop.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // Also while still opening: the late initialize then disposes itself.
      if (!_pausedByLifecycle && _error == null) {
        _pausedByLifecycle = true;
        _gen++;
        unawaited(_release());
        setState(() {
          _ready = false;
        });
      }
    } else if (state == AppLifecycleState.resumed && _pausedByLifecycle) {
      _pausedByLifecycle = false;
      _start();
    }
  }

  Future<void> _start() async {
    final gen = ++_gen;
    setState(() {
      _error = null;
      _deniedError = false;
      _ready = false;
    });
    final blocked = cameraBlockedReason();
    if (blocked != null) {
      setState(() {
        _error = blocked;
      });
      return;
    }
    try {
      if (_cameras.isEmpty) {
        final all = await availableCameras();
        final back = all.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
        _cameras = all;
        _index = back < 0 ? 0 : back;
      }
      if (!mounted || gen != _gen) return;
      if (_cameras.isEmpty) {
        setState(() {
          _error = _noCamera;
        });
        return;
      }
      await _open(gen);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = _errorText(e);
        _deniedError = _error == _denied;
      });
    }
  }

  /// Throws when the camera does not open; the failed controller is released.
  Future<void> _open(int gen) async {
    await _release();
    final c = CameraController(
      _cameras[_index],
      ResolutionPreset.veryHigh, // 1080p; the sheet shrinks to 1600 px anyway
      enableAudio: false,
    );
    _controller = c;
    try {
      await c.initialize();
    } catch (_) {
      if (_controller == c) _controller = null;
      unawaited(_disposeQuietly(c));
      rethrow;
    }
    if (!mounted || gen != _gen || _controller != c) {
      unawaited(_disposeQuietly(c));
      return;
    }
    setState(() {
      _ready = true;
    });
  }

  Future<void> _release() async {
    final c = _controller;
    _controller = null;
    if (c != null) await _disposeQuietly(c);
  }

  static Future<void> _disposeQuietly(CameraController c) async {
    try {
      await c.dispose();
    } catch (_) {}
  }

  static String _errorText(Object e) {
    final code = e is CameraException ? e.code : '';
    return switch (code) {
      'CameraAccessDenied' ||
      'CameraAccessDeniedWithoutPrompt' ||
      'CameraAccessRestricted' ||
      'NotAllowedError' => _denied,
      'cameraNotFound' || 'NotFoundError' || 'cameraNotSupported' => _noCamera,
      'cameraNotReadable' || 'NotReadableError' => _inUse,
      _ => _failed,
    };
  }

  Future<void> _switch() async {
    if (_cameras.length < 2 || _shooting) return;
    _index = (_index + 1) % _cameras.length;
    final gen = ++_gen;
    setState(() {
      _ready = false;
    });
    try {
      await _open(gen);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = _errorText(e);
        _deniedError = _error == _denied;
      });
    }
  }

  Future<void> _shoot() async {
    final c = _controller;
    if (c == null || !_ready || _shooting || _count >= widget.limit) return;
    setState(() {
      _shooting = true;
      _shotError = null;
    });
    try {
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      widget.onShot(bytes);
      setState(() {
        _taken++;
        _last = bytes;
      });
      if (_count >= widget.limit) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _shotError = _shotFailed;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _shooting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final Widget body;
    if (_error != null) {
      body = _Message(
        key: const Key('sale-camera-error'),
        text: _error!,
        hint: _deniedError ? '$_deniedHint\n$_fallbackHint' : _fallbackHint,
        onRetry: _error == _noCamera ? null : _start,
      );
    } else if (_ready && c != null) {
      body = Center(child: CameraPreview(c));
    } else {
      body = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.white),
            SizedBox(height: 12),
            Text(_starting, style: TextStyle(color: AppColors.gray300)),
          ],
        ),
      );
    }

    return SafeArea(
      child: Column(
        children: [
          // Top bar: close · title · counter.
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
            child: Row(
              children: [
                IconButton(
                  key: const Key('sale-camera-close'),
                  tooltip: _closeTip,
                  color: AppColors.white,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    _title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  '$_count / ${widget.limit} รูป',
                  key: const Key('sale-camera-counter'),
                  style: const TextStyle(
                    color: AppColors.orangeLight,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ClipRect(
              child: ColoredBox(color: AppColors.black, child: body),
            ),
          ),
          if (_shotError != null || _ready)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _shotError ?? _hint(widget.limit),
                key: const Key('sale-camera-hint'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _shotError != null
                      ? AppColors.errorTextOnDark
                      : AppColors.gray300,
                  fontSize: 13,
                ),
              ),
            ),
          // Bottom bar: last shot · shutter · switch.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: _last == null
                      ? null
                      : ClipRRect(
                          key: const Key('sale-camera-last'),
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            _last!,
                            fit: BoxFit.cover,
                            cacheWidth: 112,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) =>
                                const ColoredBox(color: AppColors.gray600),
                          ),
                        ),
                ),
                const Spacer(),
                _Shutter(
                  busy: _shooting,
                  onPressed: _ready && !_shooting && _count < widget.limit
                      ? _shoot
                      : null,
                ),
                const Spacer(),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: _cameras.length > 1 && _error == null
                      ? IconButton(
                          key: const Key('sale-camera-switch'),
                          tooltip: _switchTip,
                          color: AppColors.white,
                          iconSize: 28,
                          icon: const Icon(Icons.cameraswitch_outlined),
                          onPressed: _ready && !_shooting ? _switch : null,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      label: _shutterTip,
      child: Tooltip(
        message: _shutterTip,
        child: InkResponse(
          key: const Key('sale-camera-shutter'),
          onTap: onPressed,
          radius: 40,
          child: Container(
            width: 76,
            height: 76,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: enabled ? AppColors.white : AppColors.gray500,
                width: 4,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? AppColors.orange : AppColors.gray600,
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppColors.white,
                      ),
                    )
                  : const Icon(
                      Icons.photo_camera,
                      color: AppColors.white,
                      size: 28,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.text,
    required this.hint,
    required this.onRetry,
  });

  final String text;
  final String hint;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: AppColors.gray300,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.gray300, fontSize: 13),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('sale-camera-retry'),
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.white,
                  side: const BorderSide(color: AppColors.gray300),
                  minimumSize: const Size(64, 48),
                ),
                child: const Text(_retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
