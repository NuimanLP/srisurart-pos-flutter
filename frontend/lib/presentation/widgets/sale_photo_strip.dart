// SalePhotoStrip — the photo evidence of one bill, read-only
// (10_SALE_PHOTO_EVIDENCE.md §2.3/§2.4). A horizontal row of thumbnails with
// skeleton / empty / offline / failed states; a tap opens the full-screen
// viewer. Used by Returns (_RefundDetail) and by the Reports bill sheet.
//
// Thumbnails and previews are fetched through the API (token + private CA) and
// kept in this widget's memory only — never written to disk. The preview is
// fetched when the viewer opens, not for the strip. Nothing shows on the Drift
// build (no repository).

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/sale_photos_repository.dart';
import '../repositories/repository_providers.dart';
import 'sync_status_builder.dart';
import 'thai_format.dart';

// agent ร่าง — every sentence below is awaiting owner ratification (§2.7).
const _titlePrefix = 'รูปหลักฐานตอนขาย';
const _emptyNote = 'บิลนี้ไม่มีรูปหลักฐาน';
const _offlineNote = 'ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะดูรูปได้';
const _failedNote = 'โหลดรูปไม่สำเร็จ';
const _retryLabel = 'ลองอีกครั้ง';
const _takenPrefix = 'ถ่ายเมื่อ';
const _uploadedPrefix = 'อัปโหลดเมื่อ';
String _viewerTitle(int i, int n) => 'รูป $i/$n';

class SalePhotoStrip extends StatefulWidget {
  const SalePhotoStrip({super.key, required this.saleId});

  final String saleId;

  @override
  State<SalePhotoStrip> createState() => _SalePhotoStripState();
}

class _SalePhotoStripState extends State<SalePhotoStrip> {
  SalePhotosRepository? _repo;
  Future<List<SalePhoto>>? _list;
  List<SalePhoto>? _photos;
  final Map<String, Future<Uint8List>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _repo = salePhotosRepositoryOf(context);
  }

  @override
  void didUpdateWidget(SalePhotoStrip old) {
    super.didUpdateWidget(old);
    if (old.saleId != widget.saleId) {
      _list = null;
      _photos = null;
      _thumbs.clear();
    }
  }

  void _reload() {
    setState(() {
      _list = null;
      _photos = null;
      _thumbs.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = _repo;
    if (repo == null) return const SizedBox.shrink();
    final muted = Theme.of(context).colorScheme.secondary;
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        final loaded = _photos;
        if (isDegraded) {
          // Offline: what is already on screen stays; nothing new is asked for.
          return loaded == null
              ? _Note(_offlineNote, color: muted)
              : _content(repo, loaded, degraded: true);
        }
        final future = _list ??= repo.list(widget.saleId);
        return FutureBuilder<List<SalePhoto>>(
          future: future,
          builder: (context, snap) {
            if (snap.hasError) {
              return Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  const _Note(_failedNote, color: AppColors.error),
                  TextButton(
                    key: const Key('sale-photo-strip-retry'),
                    onPressed: _reload,
                    child: const Text(_retryLabel),
                  ),
                ],
              );
            }
            final photos = snap.data;
            if (photos == null) return const _Skeleton();
            _photos = photos;
            return _content(repo, photos, degraded: false);
          },
        );
      },
    );
  }

  Widget _content(
    SalePhotosRepository repo,
    List<SalePhoto> photos, {
    required bool degraded,
  }) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.secondary;
    if (photos.isEmpty) return _Note(_emptyNote, color: muted);
    // Thumbnails are only ever started while online; offline, a photo whose
    // thumbnail was never asked for stays a placeholder.
    final missing = degraded && photos.any((p) => !_thumbs.containsKey(p.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$_titlePrefix (${photos.length})',
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: muted,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 72,
          child: ListView.separated(
            key: const Key('sale-photo-strip-list'),
            scrollDirection: Axis.horizontal,
            itemCount: photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final p = photos[i];
              final bytes = degraded
                  ? _thumbs[p.id]
                  : (_thumbs[p.id] ??= repo.bytes(
                      widget.saleId,
                      p.id,
                      SalePhotoVariant.thumb,
                    ));
              return _Thumb(
                key: Key('sale-photo-thumb-${p.id}'),
                bytes: bytes,
                onTap: () => showSalePhotoViewer(
                  context,
                  repo: repo,
                  photos: photos,
                  initial: i,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$_takenPrefix ${thaiDateTime(photos.first.takenAt)}',
          key: const Key('sale-photo-strip-taken'),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        if (missing) _Note(_offlineNote, color: muted),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(
      context,
    ).colorScheme.secondary.withValues(alpha: 0.15);
    return Row(
      key: const Key('sale-photo-strip-skeleton'),
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({super.key, required this.bytes, required this.onTap});

  /// Null: not fetched (offline) — a placeholder.
  final Future<Uint8List>? bytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(
      context,
    ).colorScheme.secondary.withValues(alpha: 0.15);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 72,
          height: 72,
          child: FutureBuilder<Uint8List>(
            future: bytes,
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) {
                return ColoredBox(
                  color: fill,
                  child: snap.hasError
                      ? const Icon(Icons.broken_image_outlined)
                      : null,
                );
              }
              return Image.memory(
                data,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: fill,
                  child: const Icon(Icons.broken_image_outlined),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Full-screen viewer: swipe between photos, pinch to zoom. Each page fetches
/// its preview when first shown; the capture time sits on the photo as a navy
/// stamp so a screenshot still tells when it was taken.
Future<void> showSalePhotoViewer(
  BuildContext context, {
  required SalePhotosRepository repo,
  required List<SalePhoto> photos,
  int initial = 0,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _Viewer(repo: repo, photos: photos, initial: initial),
    ),
  );
}

class _Viewer extends StatefulWidget {
  const _Viewer({
    required this.repo,
    required this.photos,
    required this.initial,
  });

  final SalePhotosRepository repo;
  final List<SalePhoto> photos;
  final int initial;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late final PageController _controller = PageController(
    initialPage: widget.initial,
  );
  late int _index = widget.initial;
  final Map<String, Future<Uint8List>> _previews = {};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _title(SalePhoto p) {
    final n = widget.photos.length;
    final delayed =
        p.createdAt.difference(p.takenAt).abs() > const Duration(hours: 1);
    return '${_viewerTitle(_index + 1, n)} · $_takenPrefix ${thaiDateTime(p.takenAt)}'
        '${delayed ? ' · $_uploadedPrefix ${thaiDateTime(p.createdAt)}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(
          _title(photos[_index]),
          key: const Key('sale-photo-viewer-title'),
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: photos.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final p = photos[i];
          final bytes = _previews[p.id] ??= widget.repo.bytes(
            p.saleId,
            p.id,
            SalePhotoVariant.preview,
          );
          return FutureBuilder<Uint8List>(
            future: bytes,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    ServerErrorResolver.resolveCounterError(snap.error!),
                    style: const TextStyle(color: Colors.white70),
                  ),
                );
              }
              final data = snap.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return Stack(
                fit: StackFit.expand,
                children: [
                  InteractiveViewer(
                    maxScale: 5,
                    child: Image.memory(
                      data,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        color: AppColors.navy.withValues(alpha: 0.7),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          thaiDateTime(p.takenAt),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Reports → tap a recent-sale row: the minimal bill sheet — header plus the
/// strip, nothing else (§2.4). Covers only the rows the report already shows.
Future<void> showSaleBillSheet(
  BuildContext context, {
  required String saleId,
  required String receiptNo,
  required DateTime date,
  required String paymentMethod,
  required String totalText,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              receiptNo,
              style: Theme.of(
                ctx,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              '${thaiDateTime(date)} · $paymentMethod · $totalText',
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                color: Theme.of(ctx).colorScheme.secondary,
              ),
            ),
            const SizedBox(height: 16),
            SalePhotoStrip(saleId: saleId),
          ],
        ),
      ),
    ),
  );
}
