// Products → แก้ไขสินค้า: the product's picture (owner request 2026-10-10,
// contract §5). Shows the current thumbnail; the owner picks a photo (shrunk
// on the device by [shrinkProductPhoto]), replaces or removes it. Each action
// is its own online write (`PUT` / `DELETE /products/:id/image`), separate
// from the form's บันทึก. Offline (Degraded) the buttons are disabled;
// anyone but the owner sees the picture with the reason. Nothing at all on
// the Drift build (no server holds pictures). Owned by ProductsScreen.

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

class ProductImageEditor extends StatefulWidget {
  const ProductImageEditor({
    super.key,
    required this.product,
    required this.onChanged,
  });

  final ProductRow product;

  /// Called after the picture was replaced or removed on the server.
  final VoidCallback onChanged;

  @override
  State<ProductImageEditor> createState() => _ProductImageEditorState();
}

class _ProductImageEditorState extends State<ProductImageEditor> {
  ProductImageUrls? _urls;
  late String? _imageKey = widget.product.imageKey;
  bool _busy = false;
  String? _error;

  // agent ร่าง
  static const _offlineNote = 'ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะเปลี่ยนรูปสินค้าได้';

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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // First await: on the web the picker must open inside the tap.
      final file = await FilePicker.pickFile(
        type: FileType.image,
        webOptions: backupPickWebOptions,
      );
      if (file == null || !mounted) return;
      final jpeg = await shrinkProductPhoto(await file.readAsBytes());
      if (!mounted) return;
      final repo = context.read<ProductsRepository>();
      await repo.setImage(widget.product.id, jpeg);
      await _afterWrite(repo);
    } catch (e) {
      if (mounted) setState(() => _error = ServerErrorResolver.resolveCounterError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showConfirm(
      context,
      'ลบรูปสินค้า?', // agent ร่าง
      'ลบรูปของ "${widget.product.name}" ออก การ์ดสินค้าจะแสดงเป็นไอคอนแทน', // agent ร่าง
      danger: true,
      confirmLabel: 'ลบ',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = context.read<ProductsRepository>();
      await repo.removeImage(widget.product.id);
      await _afterWrite(repo);
    } catch (e) {
      if (mounted) setState(() => _error = ServerErrorResolver.resolveCounterError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
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
        final enabled = isOwner && !isDegraded && !_busy;
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
                          onPressed: enabled ? _pick : null,
                          icon: const Icon(Icons.photo_library_outlined, size: 18),
                          label: Text(
                            hasImage ? 'เปลี่ยนรูป' : 'เลือกรูป', // agent ร่าง
                          ),
                        ),
                        if (hasImage)
                          TextButton.icon(
                            key: const Key('product-image-remove'),
                            onPressed: enabled ? _remove : null,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.error,
                            ),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('ลบรูป'), // agent ร่าง
                          ),
                        if (_busy)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
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
