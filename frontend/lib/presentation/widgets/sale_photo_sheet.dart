// SalePhotoSheet — capture the photo evidence of a sale, after payment
// (10_SALE_PHOTO_EVIDENCE.md §2.2/§3.1). Opened from the receipt dialog. Optional,
// 1–5 photos, online only. Bytes live in this sheet's memory only: they are
// shrunk the moment they arrive ([shrinkProductPhoto]), given a photoId and an
// Idempotency-Key right then, and sent one at a time on บันทึก. A failed photo
// keeps the sheet open; ลองอีกครั้ง sends the SAME photoId + key. A 4xx verdict
// can only be removed. Closing with unsent photos asks first.
//
// Two ways in, side by side: ถ่ายรูป (the in-app camera, sale_photo_camera.dart,
// on every platform incl. the shop PC webcam) and เลือกรูปจากเครื่อง (file_picker).
//
// Order: the tiles can be rearranged (long-press drag, or ◀ ▶) until บันทึก is
// first pressed. On screen order = upload order = sortOrder. A photo's
// sortOrder is frozen at its FIRST send attempt, not at capture: the server has
// no update route and keeps the query outside the fingerprint, so a retry must
// resend the same photoId + key + sortOrder. After บันทึก the order is locked;
// a photo sent later takes the lowest free sortOrder (see _nextSortOrder).
//
// The sources (camera, file picker, shrink) are injectable so a widget test
// drives the sheet with no platform channels.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/backup_pick_options.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/product_photo.dart';
import '../../data/repositories/sale_photos_repository.dart';
import 'app_button.dart';
import 'confirm_dialog.dart';
import 'sale_photo_camera.dart';

// agent ร่าง — every sentence below is awaiting owner ratification (§2.7).
// 'ถ่ายรูปหลักฐานสินค้า' (the receipt button) is the owner's own wording.
const _title = 'รูปหลักฐานสินค้า';
const _hint1 = 'ถ่ายให้เห็นสภาพสินค้าก่อนส่งมอบ';
const _hint2 = 'ไม่ต้องถ่ายหน้าลูกค้าหรือทะเบียนรถ';
const _cameraLabel = 'ถ่ายรูป';
const _filesLabel = 'เลือกรูปจากเครื่อง';
const _skipLabel = 'ข้าม';
const _closeLabel = 'ปิด';
const _retryLabel = 'ลองอีกครั้ง';
const _fullNote = 'ครบ 5 รูปแล้ว';
const _reorderHint = 'กดค้างที่รูปแล้วลากเพื่อเรียงลำดับ หรือกดลูกศร';
const _moveLeft = 'เลื่อนไปก่อนหน้า';
const _moveRight = 'เลื่อนไปถัดไป';
const _confirmTitle = 'ปิดโดยไม่บันทึกรูปที่เหลือ?';
String _saveLabel(int n) => 'บันทึก $n รูป';
String _counter(int n) => salePhotoCounter(n, maxSalePhotos);
String _confirmBody(int n) => 'รูปที่ยังไม่ได้บันทึก $n รูปจะหายไป';

const maxSalePhotos = 5;

/// Where a photo comes from.
class SalePhotoSources {
  const SalePhotoSources({
    this.camera = showSalePhotoCamera,
    required this.files,
    this.shrink = shrinkProductPhoto,
  });

  final SalePhotoCamera camera;
  final Future<Uint8List?> Function() files;
  final Future<Uint8List> Function(Uint8List) shrink;

  /// The in-app camera and file_picker. The camera works on Android, iOS and
  /// the web (the shop PC runs the web build); native desktop has no camera
  /// plugin, so there the camera view shows `เปิดกล้องไม่ได้` and files remain.
  factory SalePhotoSources.platform() {
    return SalePhotoSources(
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
  _Shot(this.takenAt) : id = newUuid(), st = _St.processing {
    // §4.3 specifies this key shape; the repository never mints its own.
    key = 'salephoto-$id';
  }

  final String id;
  late final String key;

  /// Null until the photo's FIRST send attempt, then frozen (0–4): the server
  /// keeps it on replay, so a retry must send the same value.
  int? sortOrder;
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

  /// Set by the first บันทึก press: from then on the order is locked.
  bool _saveStarted = false;
  String? _notice;

  int get _savedCount => _shots.where((s) => s.st == _St.saved).length;
  int get _unsent => _shots.where((s) => s.st != _St.saved).length;
  int get _toSend => _shots.where((s) => s.st == _St.captured).length;
  bool get _anyRetryable => _shots.any((s) => s.st == _St.retryable);
  bool get _anyFailed =>
      _shots.any((s) => s.st == _St.retryable || s.st == _St.rejected);
  bool get _full => _shots.length >= maxSalePhotos;
  bool get _reorderable => !_busy && !_saveStarted && _shots.length > 1;

  Future<void> _pickFile() async {
    if (_busy || _full) return;
    setState(() {
      _notice = null;
    });
    // The picker is the first await: on the web it must open inside the tap.
    final Uint8List? raw;
    try {
      raw = await widget.sources.files();
    } catch (e) {
      if (mounted) {
        setState(() {
          _notice = ServerErrorResolver.resolveCounterError(e);
        });
      }
      return;
    }
    if (raw != null) await _addRaw(raw);
  }

  Future<void> _openCamera() async {
    if (_busy || _full) return;
    setState(() {
      _notice = null;
    });
    await widget.sources.camera(
      context,
      count: _shots.length,
      limit: maxSalePhotos,
      onShot: _addRaw,
    );
  }

  /// A new photo goes to the end of the row; its sortOrder waits for บันทึก.
  /// Resolves null when the photo was kept, else the Thai reason it was not
  /// (the camera shows it too).
  Future<String?> _addRaw(Uint8List raw) async {
    if (!mounted) return null;
    if (_full) return _fullNote;
    final shot = _Shot(DateTime.now());
    setState(() {
      _shots.add(shot);
    });
    try {
      final small = await widget.sources.shrink(raw);
      // ✕ while it was being shrunk: the late result is not wanted.
      if (!mounted || !_shots.contains(shot)) return null;
      setState(() {
        shot.bytes = small;
        shot.st = _St.captured;
      });
      return null;
    } catch (e) {
      final reason = ServerErrorResolver.resolveCounterError(e);
      if (mounted && _shots.contains(shot)) {
        setState(() {
          _shots.remove(shot);
          _notice = reason;
        });
      }
      return reason;
    }
  }

  void _remove(_Shot s) {
    setState(() {
      _shots.remove(s);
    });
  }

  /// Moves [s] to position [to] (before บันทึก only).
  void _move(_Shot s, int to) {
    if (!_reorderable) return;
    final from = _shots.indexOf(s);
    if (from < 0 || to < 0 || to >= _shots.length || from == to) return;
    setState(() {
      _shots
        ..removeAt(from)
        ..insert(to, s);
    });
  }

  /// The sortOrder a photo's first send attempt gets: the lowest of 0..4 no
  /// saved / retryable / uploading photo holds (those may be on the server). A
  /// 4xx-refused photo is not on the server, so its value is free again — e.g.
  /// A (0) refused, B–E sent as 1–4, A removed: a new F gets 0, not 5 (which
  /// the server refuses). With at most 5 photos a free value always exists,
  /// and unsent photos take theirs in on-screen order.
  int _nextSortOrder() {
    final held = {
      for (final s in _shots)
        if (s.sortOrder != null &&
            (s.st == _St.saved ||
                s.st == _St.retryable ||
                s.st == _St.uploading))
          s.sortOrder!,
    };
    return [
      for (var i = 0; i < maxSalePhotos; i++) i,
    ].firstWhere((i) => !held.contains(i));
  }

  Future<void> _saveAll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saveStarted = true;
      _notice = null;
    });
    var failed = false;
    for (final s in List.of(_shots)) {
      if (s.st != _St.captured && s.st != _St.retryable) continue;
      setState(() {
        // Sends run in tile order and the order is locked from here on, so
        // unsent photos take their free sortOrders in on-screen order.
        s.sortOrder ??= _nextSortOrder();
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
          sortOrder: s.sortOrder!,
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

  /// Long-press drag a tile onto another to put it there (touch and mouse).
  Widget _orderable(_Shot s, int index, Widget tile) {
    if (!_reorderable) return tile;
    return DragTarget<_Shot>(
      onWillAcceptWithDetails: (d) => d.data != s,
      onAcceptWithDetails: (d) => _move(d.data, index),
      builder: (context, candidates, _) => LongPressDraggable<_Shot>(
        data: s,
        feedback: Material(
          color: Colors.transparent,
          elevation: 6,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: _tileSize,
            height: _tileSize,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: s.bytes == null
                  ? const ColoredBox(color: AppColors.gray200)
                  : Image.memory(s.bytes!, fit: BoxFit.cover),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: tile),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: candidates.isEmpty
                ? null
                : Border.all(color: AppColors.orange, width: 3),
          ),
          child: tile,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failedShots = [
      for (var i = 0; i < _shots.length; i++)
        if (_shots[i].error != null) (i, _shots[i]),
    ];
    final primaryLabel = _anyRetryable ? _retryLabel : _saveLabel(_toSend);
    // Not while a photo is still being shrunk: sends run in tile order, and a
    // skipped tile would later get a sortOrder out of that order.
    final canSave =
        !_busy &&
        !_shots.any((s) => s.st == _St.processing) &&
        (_anyRetryable || _toSend > 0);

    final pickButtons = LayoutBuilder(
      builder: (context, c) {
        // Two equal ways in — no third "add" tile doing the same thing.
        final enabled = !_busy && !_full;
        final cameraBtn = AppButton.secondary(
          key: const Key('sale-photo-camera'),
          label: _cameraLabel,
          icon: Icons.photo_camera_outlined,
          fullWidth: true,
          onPressed: enabled ? _openCamera : null,
        );
        final filesBtn = AppButton.secondary(
          key: const Key('sale-photo-files'),
          label: _filesLabel,
          icon: Icons.image_outlined,
          fullWidth: true,
          onPressed: enabled ? _pickFile : null,
        );
        // 'เลือกรูปจากเครื่อง' needs ~200 px beside its icon: stack below that.
        if (c.maxWidth < 420) {
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
                  pickButtons,
                  if (_shots.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (i, s) in _shots.indexed)
                          _orderable(
                            s,
                            i,
                            _Tile(
                              key: Key('sale-photo-tile-${s.id}'),
                              shot: s,
                              enabled: !_busy,
                              onView: () => _view(s),
                              onRemove: () => _remove(s),
                              onRetry: _saveAll,
                              onLeft: _reorderable && i > 0
                                  ? () => _move(s, i - 1)
                                  : null,
                              onRight: _reorderable && i < _shots.length - 1
                                  ? () => _move(s, i + 1)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_reorderable)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _reorderHint,
                        key: const Key('sale-photo-reorder-hint'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                      ),
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
    this.onLeft,
    this.onRight,
  });

  final _Shot shot;
  final bool enabled;
  final VoidCallback onView;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  /// Move one place back / forward; null = no arrow (ends, or order locked).
  final VoidCallback? onLeft;
  final VoidCallback? onRight;

  static Widget _arrow(
    Key key,
    IconData icon,
    String tip,
    VoidCallback onTap,
  ) => Tooltip(
    message: tip,
    child: InkWell(
      key: key,
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: CircleAvatar(
            radius: 13,
            backgroundColor: Colors.black54,
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = shot;
    // Not a retryable tile: its upload may have reached the server, so the
    // photo is not ours to throw away until ลองอีกครั้ง gets an answer.
    // A tile still being shrunk can go too (its late result is dropped).
    final removable =
        enabled &&
        (s.st == _St.captured ||
            s.st == _St.processing ||
            s.st == _St.rejected);
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
            if (onLeft != null)
              Positioned(
                left: 0,
                bottom: 0,
                child: _arrow(
                  Key('sale-photo-left-${s.id}'),
                  Icons.chevron_left,
                  _moveLeft,
                  onLeft!,
                ),
              ),
            if (onRight != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: _arrow(
                  Key('sale-photo-right-${s.id}'),
                  Icons.chevron_right,
                  _moveRight,
                  onRight!,
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
