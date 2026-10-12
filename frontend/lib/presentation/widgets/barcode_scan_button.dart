// BarcodeScanButton — a camera icon button that opens a scanner dialog and
// hands the first detected code to [onScanned] (owner request 2026-10-12).
//
// One shared widget for Products, Checkout and PO search. It only *returns a
// string*; each screen feeds it into the lookup it already has, so a camera
// scan follows the same rule as typed / USB-scanner input.
//
// The camera cannot run in tests, so the scanner is a seam: [barcodeScanner]
// (tests replace it) or the per-button [BarcodeScanButton.scanner].
//
// Web: forced to the browser's native BarcodeDetector so nothing is fetched
// from a CDN at runtime (mobile_scanner's default `auto` falls back to
// zxing-wasm/jsDelivr). Browsers without BarcodeDetector (e.g. desktop
// Firefox) show the "no camera / not supported" message instead.
//
// All Thai strings here are `agent ร่าง` (owner to ratify).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/app_colors.dart';

/// Opens a scanner and resolves with the scanned text, or null if cancelled.
typedef BarcodeScanner = Future<String?> Function(BuildContext context);

/// The scanner every [BarcodeScanButton] uses unless given its own.
/// Tests assign a fake here (and restore it in tearDown).
@visibleForTesting
BarcodeScanner barcodeScanner = showBarcodeScannerDialog;

class BarcodeScanButton extends StatelessWidget {
  /// Receives the trimmed, non-empty scanned value.
  final ValueChanged<String> onScanned;
  final BarcodeScanner? scanner;
  final bool enabled;

  const BarcodeScanButton({
    super.key,
    required this.onScanned,
    this.scanner,
    this.enabled = true,
  });

  Future<void> _scan(BuildContext context) async {
    final value = await (scanner ?? barcodeScanner)(context);
    final v = value?.trim();
    if (v != null && v.isNotEmpty) onScanned(v);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      // agent ร่าง
      tooltip: 'สแกนบาร์โค้ดด้วยกล้อง',
      icon: const Icon(Icons.photo_camera_outlined, size: 22),
      color: AppColors.orange,
      onPressed: enabled ? () => _scan(context) : null,
    );
  }
}

/// The real camera scanner: a dialog that closes itself on the first code.
Future<String?> showBarcodeScannerDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _ScannerDialog(),
  );
}

class _ScannerDialog extends StatefulWidget {
  const _ScannerDialog();

  @override
  State<_ScannerDialog> createState() => _ScannerDialogState();
}

class _ScannerDialogState extends State<_ScannerDialog> {
  late final MobileScannerController _controller;
  bool _done = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      // No runtime CDN fetch (see file header).
      MobileScannerPlatform.instance.setWebBarcodeReader(
        WebBarcodeReader.barcodeDetector,
      );
    }
    _controller = MobileScannerController(
      facing: CameraFacing.back,
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.code128,
        BarcodeFormat.code39,
        BarcodeFormat.code93,
        BarcodeFormat.itf14,
        BarcodeFormat.codabar,
        BarcodeFormat.qrCode,
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return; // first detection only — no double-fire
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  // agent ร่าง
  static String _errorText(MobileScannerException e) => switch (e.errorCode) {
    MobileScannerErrorCode.permissionDenied => 'ไม่ได้รับอนุญาตให้ใช้กล้อง',
    MobileScannerErrorCode.unsupported => 'ไม่พบกล้อง',
    _ => 'เปิดกล้องไม่ได้',
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.navyDeep,
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      // agent ร่าง
                      'สแกนบาร์โค้ดด้วยกล้อง',
                      style: TextStyle(
                        color: AppColors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    // agent ร่าง
                    tooltip: 'เปิด/ปิดไฟฉาย',
                    color: _torchOn ? AppColors.orangeLight : AppColors.gray300,
                    icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                    onPressed: () async {
                      try {
                        await _controller.toggleTorch();
                        if (mounted) setState(() => _torchOn = !_torchOn);
                      } catch (_) {
                        // No torch on this device — the button is a no-op.
                      }
                    },
                  ),
                  IconButton(
                    // agent ร่าง
                    tooltip: 'ปิด',
                    color: AppColors.white,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (context, error) => Center(
                      child: Padding(
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
                              _errorText(error),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.white,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Aiming frame — decorative only.
                  IgnorePointer(
                    child: Center(
                      child: FractionallySizedBox(
                        widthFactor: 0.7,
                        heightFactor: 0.4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: AppColors.orange,
                              width: 3,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                // agent ร่าง
                'เล็งบาร์โค้ดให้อยู่ในกรอบ',
                style: TextStyle(color: AppColors.gray300, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
