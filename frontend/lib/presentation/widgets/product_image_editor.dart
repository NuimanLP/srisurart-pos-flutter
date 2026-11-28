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
// answers late. After a pick: กำลังย่อรูป… (≤ [productPhotoProcessTimeout]) →
// กำลังอัปโหลด… (≤ [productPhotoUploadTimeout]) → done, or a red message; a
// failed upload's ลองอีกครั้ง re-sends the same in-memory JPEG, so the
// idempotency fingerprint (the body bytes) does not change.

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

/// Longest a picture upload may take before the screen stops waiting (the
/// request may still land; ลองอีกครั้ง then replays under the same key).
const productPhotoUploadTimeout = Duration(seconds: 40);

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

enum _Phase { idle, processing, uploading, failed }

class ProductImageEditor extends StatefulWidget {
  const ProductImageEditor({
    super.key,
    required this.product,
    required this.onChanged,
    this.pickPhoto = pickProductPhotoBytes,
    this.shrink = shrinkProductPhoto,
    this.processTimeout = productPhotoProcessTimeout,
    this.uploadTimeout = productPhotoUploadTimeout,
  });

  final ProductRow product;

  /// Called after the picture was replaced or removed on the server.
  final VoidCallback onChanged;

  /// Seams for tests; the defaults are the real picker and shrink.
  final Future<Uint8List?> Function() pickPhoto;
  final Future<Uint8List> Function(Uint8List source) shrink;
  final Duration processTimeout;
  final Duration uploadTimeout;

  @override
  State<ProductImageEditor> createState() => _ProductImageEditorState();
}

class _ProductImageEditorState extends State<ProductImageEditor> {
  ProductImageUrls? _urls;
  late String? _imageKey = widget.product.imageKey;
  _Phase _phase = _Phase.idle;
  String? _error;

  /// Bumped by every pick / retry / remove: a result of an older one is dropped.
  int _gen = 0;

  /// What ลองอีกครั้ง does after a failure (null = nothing worth retrying).
  Future<void> Function()? _retry;

  /// A remove (its own confirm + DELETE) is running.
  bool _removing = false;

  // agent ร่าง
  static const _offlineNote = 'ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะเปลี่ยนรูปสินค้าได้';
  static const _processingLabel = 'กำลังย่อรูป…'; // agent ร่าง
  static const _uploadingLabel = 'กำลังอัปโหลด…'; // agent ร่าง

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
      source = await widget.pickPhoto();
    } catch (e) {
      if (gen == _gen) _showError(e, null);
      return;
    }
    if (source == null || gen != _gen || !mounted) return;
    await _process(gen, source);
  }

  Future<void> _process(int gen, Uint8List source) async {
    setState(() {
      _phase = _Phase.processing;
      _error = null;
      _retry = null;
    });
    final Uint8List jpeg;
    try {
      jpeg = await widget.shrink(source).timeout(widget.processTimeout);
    } catch (e) {
      // Only a timeout is worth the same file again; a refused file is not.
      if (gen == _gen) {
        _showError(e, e is TimeoutException ? () => _process(++_gen, source) : null);
      }
      return;
    }
    if (gen != _gen || !mounted) return;
    await _upload(gen, jpeg);
  }

  /// The retry keeps [jpeg] as is: the same bytes are the same key.
  Future<void> _upload(int gen, Uint8List jpeg) async {
    setState(() {
      _phase = _Phase.uploading;
      _error = null;
      _retry = null;
    });
    try {
      final repo = context.read<ProductsRepository>();
      await repo.setImage(widget.product.id, jpeg).timeout(widget.uploadTimeout);
      if (gen != _gen) return;
      await _afterWrite(repo);
      if (mounted && gen == _gen) setState(() => _phase = _Phase.idle);
    } catch (e) {
      if (gen == _gen) _showError(e, () => _upload(++_gen, jpeg));
    }
  }

  void _showError(Object e, Future<void> Function()? retry) {
    if (!mounted) return;
    setState(() {
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
      'ลบรูปของ "${widget.product.name}" ออก การ์ดสินค้าจะแสดงเป็นไอคอนแทน', // agent ร่าง
      danger: true,
      confirmLabel: 'ลบ', // agent ร่าง
    );
    if (!ok || !mounted) return;
    ++_gen; // a pick still waiting must not overwrite the removal
    setState(() {
      _removing = true;
      _phase = _Phase.idle;
      _error = null;
      _retry = null;
    });
    try {
      final repo = context.read<ProductsRepository>();
      await repo.removeImage(widget.product.id);
      await _afterWrite(repo);
    } catch (e) {
      if (mounted) setState(() => _error = ServerErrorResolver.resolveCounterError(e));
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  /// The repository wrote the server's key to Drift; show it.
  Future<void> _afterWrite(ProductsRepository repo) async {
    final row = await repo.getById(widget.product.id);
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
    final hasImage = urls.thumb(_imageKey) != null;
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        final working =
            _phase == _Phase.processing || _phase == _Phase.uploading;
        final canWrite = isOwner && !isDegraded && !_removing;
        // Picking again is allowed while a shrink runs (it supersedes it),
        // not during an upload, which cannot be called back.
        final canPick = canWrite && _phase != _Phase.uploading;
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
                  child: ProductImage(url: urls.thumb(_imageKey), iconSize: 32),
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
                        if (hasImage)
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
                          'เปลี่ยนรูปแล้วบันทึกทันที ไม่ต้องกด "บันทึก"', // owner-ratified 2026-10-12
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
