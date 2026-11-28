// Products → แก้ไขสินค้า: the product's picture (owner request 2026-10-10,
// contract §5). Shows the current thumbnail; the owner picks a photo (shrunk
// on the device by [shrinkProductPhoto]), replaces or removes it. Each action
// is its own online write (`PUT` / `DELETE /products/:id/image`), separate
// from the form's บันทึก. Offline (Degraded) the buttons are disabled;
// anyone but the owner sees the picture with the reason. Nothing at all on
// the Drift build (no server holds pictures). Owned by ProductsScreen.
//
// iPad (2026-11-28: the spinner never stopped, no request reached the
// server): nothing is busy while the picker is open — iOS Safari can dismiss
// it without ever answering — and a generation counter drops a pick that
// answers late. After a pick: กำลังย่อรูป… (≤ [productPhotoProcessTimeout];
// one shrink at a time, the button is off meanwhile) → กำลังอัปโหลด… (ended
// by ApiClient's own write timeout) → done, or a red message; a failed
// upload's ลองอีกครั้ง re-sends the same in-memory JPEG, so the idempotency
// fingerprint (the body bytes) does not change.
//
// เพิ่มสินค้าใหม่ ([product] null, owner only): there is no id to `PUT` to
// yet, so a picked photo is shrunk and previewed locally and handed to
// [ProductImageEditor.onPicked]; the dialog uploads it after its add().

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/backup_pick_options.dart';
import '../../core/utils/product_image.dart';
import '../../core/utils/product_photo.dart';
import '../../data/db/database.dart';
import '../../data/repositories/api_products_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../blocs/auth_cubit.dart';
import 'confirm_dialog.dart';
import 'product_image.dart';
import 'sync_status_builder.dart';

/// Longest the shrink of a picked photo may take before it is given up.
const productPhotoProcessTimeout = Duration(seconds: 20);

// agent ร่าง
const productPhotoTimeoutMessage = 'ใช้เวลานานเกินไป กรุณาลองใหม่หรือเลือกรูปอื่น';

/// The picker: a photo's bytes, or null when nothing was picked. A file over
/// [maxProductPhotoInputBytes] is refused before it is read when the platform
/// knows its size.
Future<Uint8List?> pickProductPhotoBytes() async {
  // First await: on the web the picker must open inside the tap.
  final file = await FilePicker.pickFile(
    type: FileType.image, // accept="image/*": iOS hands HEIC over as JPEG
    webOptions: backupPickWebOptions,
  );
  if (file == null) return null;
  if ((file.lengthSync() ?? 0) > maxProductPhotoInputBytes) {
    throw productPhotoFileTooLarge;
  }
  return file.readAsBytes();
}

/// The picker every [ProductImageEditor] uses unless given its own — a seam
/// for tests of the dialogs that build the editor themselves.
@visibleForTesting
Future<Uint8List?> Function() productPhotoPicker = pickProductPhotoBytes;

/// Likewise for the shrink.
@visibleForTesting
Future<Uint8List> Function(Uint8List source) productPhotoShrinker = shrinkProductPhoto;

enum _Phase { idle, processing, uploading, failed }

class ProductImageEditor extends StatefulWidget {
  const ProductImageEditor({
    super.key,
    required this.product,
    required this.onChanged,
    this.onPicked,
    this.onBusyChanged,
    this.enabled = true,
    this.pickPhoto,
    this.shrink,
    this.processTimeout = productPhotoProcessTimeout,
  });

  /// Null = a product not saved yet (เพิ่มสินค้าใหม่): nothing is uploaded.
  final ProductRow? product;

  /// Called after the picture was replaced or removed on the server.
  final VoidCallback onChanged;

  /// No [product]: the shrunk JPEG of the picked photo, for the dialog to
  /// upload after it saved the product.
  final ValueChanged<Uint8List>? onPicked;

  /// True while a photo is being shrunk or uploaded, false when that ended —
  /// the Add dialog holds its บันทึก meanwhile.
  final ValueChanged<bool>? onBusyChanged;

  /// False: picking is off (the dialog is saving / uploading this picture).
  final bool enabled;

  /// Seams for tests; the defaults are the real picker and shrink.
  final Future<Uint8List?> Function()? pickPhoto;
  final Future<Uint8List> Function(Uint8List source)? shrink;
  final Duration processTimeout;

  @override
  State<ProductImageEditor> createState() => _ProductImageEditorState();
}

class _ProductImageEditorState extends State<ProductImageEditor> {
  ProductImageUrls? _urls;
  late String? _imageKey = widget.product?.imageKey;

  /// No product yet: the picked photo, shrunk, shown until the dialog saves.
  Uint8List? _local;
  _Phase _phase = _Phase.idle;
  String? _error;

  /// Bumped by every pick / retry / remove: a result of an older one is dropped.
  int _gen = 0;

  /// What ลองอีกครั้ง does after a failure (null = nothing worth retrying).
  Future<void> Function()? _retry;

  /// A remove (its own confirm + DELETE) is running.
  bool _removing = false;

  /// The shrink still running, even one the screen stopped waiting for: the
  /// next one starts only after it (on Safari each is a full-size decode).
  Future<void>? _shrinkRunning;

  bool _busyReported = false;

  /// setState, then tell the dialog when busy (shrinking / uploading) flips.
  void _update(VoidCallback fn) {
    setState(fn);
    final busy = _phase == _Phase.processing || _phase == _Phase.uploading;
    if (busy != _busyReported) {
      _busyReported = busy;
      widget.onBusyChanged?.call(busy);
    }
  }

  // agent ร่าง
  static const _offlineNote = 'ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะเปลี่ยนรูปสินค้าได้';
  static const _processingLabel = 'กำลังย่อรูป…'; // agent ร่าง
  static const _uploadingLabel = 'กำลังอัปโหลด…'; // agent ร่าง
  static const _uploadOnSaveNote = 'รูปจะอัปโหลดเมื่อกดบันทึก'; // agent ร่าง

  @override
  void initState() {
    super.initState();
    _loadUrls();
  }

  Future<void> _loadUrls() async {
    try {
      final urls = await context.read<ProductsRepository>().getImageUrls();
      if (mounted && urls != null) setState(() => _urls = urls);
    } catch (_) {
      // No URLs: no picture section.
    }
  }

  bool get _isOwner {
    try {
      final s = context.watch<AuthCubit>().state;
      return s is Authenticated && s.user.role == 'owner';
    } catch (_) {
      return false; // no AuthCubit above (never on the API build)
    }
  }

  Future<void> _pick() async {
    // No busy state here: the picker may never answer (iOS Safari).
    final gen = ++_gen;
    final Uint8List? source;
    try {
      source = await (widget.pickPhoto ?? productPhotoPicker)();
    } catch (e) {
      if (gen == _gen) _showError(e, null);
      return;
    }
    if (source == null || gen != _gen || !mounted) return;
    await _process(gen, source);
  }

  /// [source] shrunk, after any shrink still running from before.
  Future<Uint8List> _shrinkAfterPrevious(Uint8List source) {
    final previous = _shrinkRunning ?? Future<void>.value();
    final shrink = widget.shrink ?? productPhotoShrinker;
    final run = previous.then((_) => shrink(source));
    final done = run.then<void>((_) {}, onError: (_) {});
    _shrinkRunning = done;
    unawaited(done.then((_) {
      if (identical(_shrinkRunning, done)) _shrinkRunning = null;
    }));
    return run;
  }

  Future<void> _process(int gen, Uint8List source) async {
    _update(() {
      _phase = _Phase.processing;
      _error = null;
      _retry = null;
    });
    final Uint8List jpeg;
    try {
      jpeg = await _shrinkAfterPrevious(source).timeout(widget.processTimeout);
    } catch (e) {
      // Only a timeout is worth the same file again; a refused file is not.
      if (gen == _gen) {
        _showError(e, e is TimeoutException ? () => _process(++_gen, source) : null);
      }
      return;
    }
    if (gen != _gen || !mounted) return;
    if (widget.product == null) {
      widget.onPicked?.call(jpeg); // before busy flips off: บันทึก then sends it
      _update(() {
        _local = jpeg;
        _phase = _Phase.idle;
      });
      return;
    }
    await _upload(gen, jpeg);
  }

  /// The retry keeps [jpeg] as is: the same bytes are the same key. No UI
  /// timeout: ApiClient's own write timeout ends it (a 401 refresh may
  /// resend, so a shorter one here would say "failed" while it saves).
  Future<void> _upload(int gen, Uint8List jpeg) async {
    _update(() {
      _phase = _Phase.uploading;
      _error = null;
      _retry = null;
    });
    final repo = context.read<ProductsRepository>();
    final id = widget.product!.id;
    try {
      await repo.setImage(id, jpeg);
    } catch (e) {
      // The picture may have landed anyway (a pull wrote its key meanwhile).
      final row = await repo.getById(id);
      if (gen != _gen) return;
      if (row?.imageKey == null || row?.imageKey == _imageKey) {
        _showError(e, () => _upload(++_gen, jpeg));
        return;
      }
    }
    if (gen != _gen) return;
    await _afterWrite(repo);
    if (mounted && gen == _gen) _update(() => _phase = _Phase.idle);
  }

  void _showError(Object e, Future<void> Function()? retry) {
    if (!mounted) return;
    _update(() {
      _phase = _Phase.failed;
      _error = e is TimeoutException
          ? productPhotoTimeoutMessage
          : ServerErrorResolver.resolveCounterError(e);
      _retry = retry;
    });
  }

  Future<void> _remove() async {
    final ok = await showConfirm(
      context,
      'ลบรูปสินค้า?', // agent ร่าง
      'ลบรูปของ "${widget.product!.name}" ออก การ์ดสินค้าจะแสดงเป็นไอคอนแทน', // agent ร่าง
      danger: true,
      confirmLabel: 'ลบ', // agent ร่าง
    );
    if (!ok || !mounted) return;
    ++_gen; // a pick still waiting must not overwrite the removal
    _update(() {
      _removing = true;
      _phase = _Phase.idle;
      _error = null;
      _retry = null;
    });
    try {
      final repo = context.read<ProductsRepository>();
      await repo.removeImage(widget.product!.id);
      await _afterWrite(repo);
    } catch (e) {
      if (mounted) setState(() => _error = ServerErrorResolver.resolveCounterError(e));
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  /// The repository wrote the server's key to Drift; show it.
  Future<void> _afterWrite(ProductsRepository repo) async {
    final row = await repo.getById(widget.product!.id);
    if (!mounted) return;
    setState(() => _imageKey = row?.imageKey);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls;
    if (urls == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isOwner = _isOwner;
    final isNew = widget.product == null;
    // A new product: owner only, as the Add dialog had no picture before.
    if (isNew && !isOwner) return const SizedBox.shrink();
    final local = _local;
    final hasServerImage = urls.thumb(_imageKey) != null;
    final hasImage = local != null || hasServerImage;
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        final working =
            _phase == _Phase.processing || _phase == _Phase.uploading;
        final canWrite = isOwner && !isDegraded && !_removing;
        // One photo at a time: no pick while one is shrunk (on Safari a
        // second full-size decode can kill the tab) or uploaded (it cannot be
        // called back), nor while the dialog saves this picture.
        final canPick = canWrite && !working && widget.enabled;
        final note = !isOwner
            ? ApiProductsRepository.imageOwnerOnlyMessage
            : (isDegraded ? _offlineNote : null);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  key: const Key('product-image-editor-thumb'),
                  width: 96,
                  height: 96,
                  child: local != null
                      ? Image.memory(
                          local,
                          key: const Key('product-image-local-preview'),
                          fit: BoxFit.cover,
                        )
                      : ProductImage(url: urls.thumb(_imageKey), iconSize: 32),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'รูปสินค้า', // agent ร่าง
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('product-image-pick'),
                          onPressed: canPick ? _pick : null,
                          icon: const Icon(Icons.photo_library_outlined, size: 18),
                          label: Text(
                            hasImage ? 'เปลี่ยนรูป' : 'เลือกรูป', // agent ร่าง
                          ),
                        ),
                        if (hasServerImage && !isNew)
                          TextButton.icon(
                            key: const Key('product-image-remove'),
                            onPressed: canWrite && !working ? _remove : null,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.error,
                            ),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('ลบรูป'), // agent ร่าง
                          ),
                        if (_retry != null && canPick)
                          FilledButton.tonalIcon(
                            key: const Key('product-image-retry'),
                            onPressed: _retry,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('ลองอีกครั้ง'),
                          ),
                      ],
                    ),
                    if (working || _removing)
                      Padding(
                        key: const Key('product-image-status'),
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            if (working) ...[
                              const SizedBox(width: 8),
                              Text(
                                _phase == _Phase.processing
                                    ? _processingLabel
                                    : _uploadingLabel,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    // The picture is its own write, apart from the form —
                    // say so, or the owner presses ยกเลิก expecting undo.
                    if (note == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          isNew
                              ? _uploadOnSaveNote
                              : 'เปลี่ยนรูปแล้วบันทึกทันที ไม่ต้องกด "บันทึก"', // owner-ratified 2026-10-12
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                      ),
                    if (note != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          note,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _error!,
                          key: const Key('product-image-error'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
