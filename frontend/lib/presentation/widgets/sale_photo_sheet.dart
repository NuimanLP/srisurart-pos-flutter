// SalePhotoSheet — capture the photo evidence of a sale, after payment
// (10_SALE_PHOTO_EVIDENCE.md §2.2/§3.1). Opened from the receipt dialog. Optional,
// 1–5 photos, online only. Bytes live in this sheet's memory only: they are
// shrunk the moment they arrive ([shrinkProductPhoto]), given a photoId and an
// Idempotency-Key right then, and sent one at a time on บันทึก. A failed photo
// keeps the sheet open; ลองอีกครั้ง sends the SAME photoId + key. A 4xx verdict
// can only be removed. Closing with unsent photos asks first.
//
// The sources (camera, file picker, shrink) are injectable so a widget test
// drives the sheet with no platform channels.

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/backup_pick_options.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/product_photo.dart';
import '../../data/repositories/sale_photos_repository.dart';
import 'app_button.dart';
import 'confirm_dialog.dart';

// agent ร่าง — every sentence below is awaiting owner ratification (§2.7).
// 'ถ่ายรูปหลักฐานสินค้า' (the receipt button) is the owner's own wording.
const _title = 'รูปหลักฐานสินค้า';
const _hint1 = 'ถ่ายให้เห็นสภาพสินค้าก่อนส่งมอบ';
const _hint2 = 'ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ';
const _cameraLabel = 'ถ่ายรูป';
const _filesLabel = 'เลือกรูป';
const _addLabel = 'เพิ่มรูป';
const _skipLabel = 'ข้าม';
const _closeLabel = 'ปิด';
const _retryLabel = 'ลองอีกครั้ง';
const _fullNote = 'ครบ 5 รูปแล้ว';
const _cameraFailed = 'เปิดกล้องไม่ได้ ลองใช้ปุ่ม เลือกรูป แทน';
const _confirmTitle = 'ปิดโดยไม่บันทึกรูปที่เหลือ?';
String _saveLabel(int n) => 'บันทึก $n รูป';
String _counter(int n) => '$n / 5 รูป';
String _confirmBody(int n) => 'รูปที่ยังไม่ได้บันทึก $n รูปจะหายไป';

const maxSalePhotos = 5;

/// Where a photo comes from. [camera] is null where there is no camera to open
/// (web, desktop): the button is then not shown.
class SalePhotoSources {
  const SalePhotoSources({
    this.camera,
    required this.files,
    this.shrink = shrinkProductPhoto,
  });

  final Future<Uint8List?> Function()? camera;
  final Future<Uint8List?> Function() files;
  final Future<Uint8List> Function(Uint8List) shrink;

  /// image_picker on Android/iOS, file_picker everywhere.
  factory SalePhotoSources.platform() {
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return SalePhotoSources(
      camera: mobile
          ? () async {
              final x = await ImagePicker().pickImage(
                source: ImageSource.camera,
                maxWidth: 1600,
                imageQuality: 85,
              );
              return x?.readAsBytes();
            }
          : null,
      files: () async {
        final f = await FilePicker.pickFile(
          type: FileType.image,
          webOptions: backupPickWebOptions,
        );
        return f?.readAsBytes();
      },
    );
  }
}

/// Opens the sheet (a dialog from 600 logical px up, full-screen below).
/// Resolves to true when at least one photo was saved.
Future<bool> showSalePhotoSheet(
  BuildContext context, {
  required SalePhotosRepository repo,
  required String saleId,
  required String receiptNo,
  SalePhotoSources? sources,
}) async {
  final src = sources ?? SalePhotoSources.platform();
  final wide = MediaQuery.of(context).size.width >= 600;
  final sheet = _SalePhotoSheet(
    repo: repo,
    saleId: saleId,
    receiptNo: receiptNo,
    sources: src,
  );
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => wide
        ? Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: sheet,
            ),
          )
        : Dialog.fullscreen(child: sheet),
  );
  return saved ?? false;
}

enum _St { processing, captured, uploading, saved, retryable, rejected }

class _Shot {
  _Shot(this.takenAt, this.sortOrder) : id = newUuid(), st = _St.processing {
    // §4.3 specifies this key shape; the repository never mints its own.
    key = 'salephoto-$id';
  }

  final String id;
  late final String key;

  /// Fixed when the photo is captured (0–4); the server keeps it on replay, so
  /// it must not change between a first attempt and a retry.
  final int sortOrder;
  final DateTime takenAt;
  Uint8List? bytes;
  _St st;
  String? error;
}

class _SalePhotoSheet extends StatefulWidget {
  const _SalePhotoSheet({
    required this.repo,
    required this.saleId,
    required this.receiptNo,
    required this.sources,
  });

  final SalePhotosRepository repo;
  final String saleId;
  final String receiptNo;
  final SalePhotoSources sources;

  @override
  State<_SalePhotoSheet> createState() => _SalePhotoSheetState();
}

class _SalePhotoSheetState extends State<_SalePhotoSheet> {
  final List<_Shot> _shots = [];
  bool _busy = false;
  String? _notice;

  int get _savedCount => _shots.where((s) => s.st == _St.saved).length;
  int get _unsent => _shots.where((s) => s.st != _St.saved).length;
  int get _toSend => _shots.where((s) => s.st == _St.captured).length;
  bool get _anyRetryable => _shots.any((s) => s.st == _St.retryable);
  bool get _anyFailed =>
      _shots.any((s) => s.st == _St.retryable || s.st == _St.rejected);
  bool get _full => _shots.length >= maxSalePhotos;

  Future<void> _add(
    Future<Uint8List?> Function() source, {
    bool camera = false,
  }) async {
    if (_busy || _full) return;
    setState(() {
      _notice = null;
    });
    // The picker is the first await: on the web it must open inside the tap.
    final Uint8List? raw;
    try {
      raw = await source();
    } catch (e) {
      if (mounted) {
        setState(() {
          _notice = camera
              ? _cameraFailed
              : ServerErrorResolver.resolveCounterError(e);
        });
      }
      return;
    }
    if (raw == null || !mounted || _full) return;
    final used = {for (final s in _shots) s.sortOrder};
    final shot = _Shot(
      DateTime.now(),
      [
        for (var i = 0; i < maxSalePhotos; i++) i,
      ].firstWhere((i) => !used.contains(i)),
    );
    setState(() {
      _shots
        ..add(shot)
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    });
    try {
      final small = await widget.sources.shrink(raw);
      if (!mounted) return;
      setState(() {
        shot.bytes = small;
        shot.st = _St.captured;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shots.remove(shot);
        _notice = ServerErrorResolver.resolveCounterError(e);
      });
    }
  }

  void _remove(_Shot s) {
    setState(() {
      _shots.remove(s);
    });
  }

  Future<void> _saveAll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    var failed = false;
    for (final s in List.of(_shots)) {
      if (s.st != _St.captured && s.st != _St.retryable) continue;
      setState(() {
        s.st = _St.uploading;
        s.error = null;
      });
      try {
        await widget.repo.upload(
          saleId: widget.saleId,
          photoId: s.id,
          idempotencyKey: s.key,
          bytes: s.bytes!,
          takenAt: s.takenAt,
          sortOrder: s.sortOrder,
        );
        if (!mounted) return;
        setState(() {
          s.st = _St.saved;
        });
      } on SalePhotoException catch (e) {
        if (!mounted) return;
        setState(() {
          s.st = e.retryable ? _St.retryable : _St.rejected;
          s.error = e.message;
        });
        failed = true;
        break;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          s.st = _St.retryable;
          s.error = ServerErrorResolver.resolveCounterError(e);
        });
        failed = true;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
    });
    if (!failed && _unsent == 0) Navigator.of(context).pop(true);
  }

  Future<void> _close() async {
    if (_busy) return;
    final n = _unsent;
    if (n > 0) {
      final ok = await showConfirm(
        context,
        _confirmTitle,
        _confirmBody(n),
        danger: true,
        confirmLabel: _closeLabel,
      );
      if (!ok || !mounted) return;
    }
    Navigator.of(context).pop(_savedCount > 0);
  }

  void _view(_Shot s) {
    final bytes = s.bytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              maxScale: 5,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.close),
                  tooltip: _closeLabel,
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final camera = widget.sources.camera;
    final failedShots = [
      for (var i = 0; i < _shots.length; i++)
        if (_shots[i].error != null) (i, _shots[i]),
    ];
    final primaryLabel = _anyRetryable ? _retryLabel : _saveLabel(_toSend);
    final canSave = !_busy && (_anyRetryable || _toSend > 0);

    final pickButtons = LayoutBuilder(
      builder: (context, c) {
        final enabled = !_busy && !_full;
        final cameraBtn = camera == null
            ? null
            : AppButton.secondary(
                key: const Key('sale-photo-camera'),
                label: _cameraLabel,
                icon: Icons.photo_camera_outlined,
                fullWidth: true,
                onPressed: enabled ? () => _add(camera, camera: true) : null,
              );
        final filesBtn = AppButton.secondary(
          key: const Key('sale-photo-files'),
          label: _filesLabel,
          icon: Icons.photo_library_outlined,
          fullWidth: true,
          onPressed: enabled ? () => _add(widget.sources.files) : null,
        );
        if (cameraBtn == null) return filesBtn;
        if (c.maxWidth < 360) {
          return Column(
            children: [cameraBtn, const SizedBox(height: 8), filesBtn],
          );
        }
        return Row(
          children: [
            Expanded(child: cameraBtn),
            const SizedBox(width: 8),
            Expanded(child: filesBtn),
          ],
        );
      },
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  key: const Key('sale-photo-back'),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: _closeLabel,
                  onPressed: _busy ? null : _close,
                ),
                Expanded(
                  child: Text(
                    _title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    widget.receiptNo,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.orange,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_hint1, style: theme.textTheme.bodyMedium),
                  Text(
                    _hint2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in _shots)
                        _Tile(
                          key: Key('sale-photo-tile-${s.id}'),
                          shot: s,
                          enabled: !_busy,
                          onView: () => _view(s),
                          onRemove: () => _remove(s),
                          onRetry: _saveAll,
                        ),
                      if (!_full && !_busy)
                        _AddTile(
                          onTap: () => camera != null
                              ? _add(camera, camera: true)
                              : _add(widget.sources.files),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _full ? _fullNote : _counter(_shots.length),
                    key: const Key('sale-photo-counter'),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                  for (final (i, s) in failedShots)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'รูป ${i + 1}: ${s.error}', // agent ร่าง
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _notice!,
                        key: const Key('sale-photo-notice'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  pickButtons,
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: AppButton.secondary(
                    key: const Key('sale-photo-skip'),
                    label: _anyFailed ? _closeLabel : _skipLabel,
                    onPressed: _busy ? null : _close,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppButton(
                    key: const Key('sale-photo-save'),
                    label: primaryLabel,
                    busy: _busy,
                    onPressed: canSave ? _saveAll : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const _tileSize = 96.0;

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.shot,
    required this.enabled,
    required this.onView,
    required this.onRemove,
    required this.onRetry,
  });

  final _Shot shot;
  final bool enabled;
  final VoidCallback onView;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = shot;
    // Not a retryable tile: its upload may have reached the server, so the
    // photo is not ours to throw away until ลองอีกครั้ง gets an answer.
    final removable = enabled && (s.st == _St.captured || s.st == _St.rejected);
    final scrim = Colors.black.withValues(alpha: 0.5);
    return SizedBox(
      width: _tileSize,
      height: _tileSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (s.bytes != null)
              GestureDetector(
                onTap: onView,
                child: Image.memory(
                  s.bytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: AppColors.gray200,
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
              )
            else
              const ColoredBox(color: AppColors.gray200),
            if (s.st == _St.processing || s.st == _St.uploading)
              ColoredBox(
                color: scrim,
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            if (s.st == _St.saved)
              const Positioned(
                left: 4,
                bottom: 4,
                child: Icon(
                  Icons.check_circle,
                  color: AppColors.successLight,
                  size: 24,
                ),
              ),
            if (s.st == _St.retryable || s.st == _St.rejected)
              ColoredBox(
                color: scrim,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppColors.warning,
                      size: 28,
                    ),
                    if (s.st == _St.retryable)
                      TextButton(
                        key: Key('sale-photo-retry-${s.id}'),
                        onPressed: enabled ? onRetry : null,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: const Text(
                          _retryLabel,
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            if (removable)
              Positioned(
                top: 0,
                right: 0,
                child: InkWell(
                  key: Key('sale-photo-remove-${s.id}'),
                  onTap: onRemove,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.topRight,
                    padding: const EdgeInsets.all(4),
                    child: const CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.black54,
                      child: Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.secondary;
    return SizedBox(
      width: _tileSize,
      height: _tileSize,
      child: InkWell(
        key: const Key('sale-photo-add-tile'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_a_photo_outlined, color: color),
              const SizedBox(height: 4),
              Text(_addLabel, style: TextStyle(color: color, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
