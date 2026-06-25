// VehicleSearchScreen — 🔍 ค้นหาอะไหล่ตามรุ่นรถ / Search by Vehicle.
//
// Ported for behaviour parity from
//   D:/Beestation/.../pos/VehicleSearch.jsx
//
// Behaviour parity notes:
//  • POPULAR_VEHICLES lists the car/pickup models this shop stocks parts for
//    (matched against the products' `compat` field — see seed data in database.dart).
//  • Results = products whose `compat` text-contains the trimmed query
//    (case-insensitive) — productsRepoProvider.getAll() then filter.
//  • Quick-chip toggles: tapping the active chip clears the query.
//  • The matched substring of `compat` is highlighted (orange).
//  • Each result card has a 📋 คัดลอกรหัส button that copies the partNo.
//    The .jsx card has NO tap-to-navigate; only the copy button — kept as-is.
//  • The .jsx was a centred modal opened from the topbar; here it is a routed
//    full screen inside AppShell. Same content, no overlay/close button needed
//    (AppShell provides nav).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../providers/providers.dart';

/// Popular car/pickup models this auto-parts shop carries — each value is a
/// substring of one or more products' `compat` field so a chip tap returns real
/// results (see seed data in database.dart). This is a car shop, not motorcycle.
const List<String> _popularVehicles = [
  'Toyota Hilux', 'Toyota Vios', 'Toyota Fortuner',
  'Honda City', 'Honda Civic', 'Honda Jazz',
  'Isuzu D-Max', 'Isuzu MU-X', 'Ford Ranger',
  'Mitsubishi Triton', 'Nissan Navara', 'Mazda 2',
];

/// Products + category list, loaded once for the screen (categories drive the
/// per-category color, mirroring getCatColor in the .jsx).
final _vehicleSearchDataProvider =
    FutureProvider.autoDispose<({List<ProductRow> products, List<String> categories})>(
  (ref) async {
    final repo = ref.watch(productsRepoProvider);
    final products = await repo.getAll();
    final categories = await repo.getCategories();
    return (products: products, categories: categories);
  },
);

class VehicleSearchScreen extends ConsumerStatefulWidget {
  const VehicleSearchScreen({super.key});

  @override
  ConsumerState<VehicleSearchScreen> createState() =>
      _VehicleSearchScreenState();
}

class _VehicleSearchScreenState extends ConsumerState<VehicleSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setQuery(String v) {
    setState(() {
      _query = v;
      if (_controller.text != v) {
        _controller.value = TextEditingValue(
          text: v,
          selection: TextSelection.collapsed(offset: v.length),
        );
      }
    });
  }

  void _toggleChip(String v) {
    // .jsx: setQuery(q => q === v ? '' : v)
    _setQuery(_query == v ? '' : v);
  }

  void _copy(String partNo) {
    Clipboard.setData(ClipboardData(text: partNo));
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(_vehicleSearchDataProvider);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          _searchArea(context),
          _quickRow(context),
          Expanded(
            child: dataAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('เกิดข้อผิดพลาด: $e')),
              data: (data) => _results(context, data.products, data.categories),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ──
  Widget _header(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.gray200.withValues(alpha: 0.4)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🔍 ค้นหาตามรุ่นรถ · Search by Vehicle',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 22,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'พิมพ์รุ่นรถเพื่อดูอะไหล่ที่ใช้ได้ทั้งหมด',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.steelBlue,
            ),
          ),
        ],
      ),
    );
  }

  // ── Search input ──
  Widget _searchArea(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: TextField(
        controller: _controller,
        autofocus: true,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 18),
        decoration: InputDecoration(
          hintText: 'เช่น Toyota Hilux, Honda Civic, Isuzu D-Max...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _setQuery(''),
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  // ── Popular quick-buttons ──
  Widget _quickRow(BuildContext context) {
    // Wide screens (tablet/desktop) Wrap the chips to multiple rows — all
    // visible at once. On a phone that Wrap can grow tall enough that the fixed
    // header + search + chips exceed the body height and the Column overflows;
    // there the chips become a single horizontally-scrolling row (fixed height,
    // robust to any number/length of model names), leaving room for results.
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.rail;
    final label = Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        'รุ่นยอดนิยม:',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 1.2,
          color: AppColors.steelBlue,
        ),
      ),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.gray200.withValues(alpha: 0.25)),
        ),
      ),
      child: wide
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                label,
                for (final v in _popularVehicles) _quickChip(v),
              ],
            )
          : Row(
              children: [
                label,
                const SizedBox(width: 4),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final v in _popularVehicles) ...[
                          _quickChip(v),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _quickChip(String v) {
    final active = _query == v;
    // minHeight:44 hit target (widthFactor:1 keeps the pill compact in the Wrap).
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _toggleChip(v),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: active
                  ? AppColors.orange.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: active
                    ? AppColors.orange.withValues(alpha: 0.6)
                    : AppColors.gray200.withValues(alpha: 0.6),
              ),
            ),
            child: Text(
              v,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: active ? AppColors.orange : AppColors.steelBlue,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Results ──
  Widget _results(
    BuildContext context,
    List<ProductRow> products,
    List<String> categories,
  ) {
    final q = _query.trim().toLowerCase();

    // .jsx: if no query → empty prompt
    if (q.isEmpty) {
      return _emptyState(
        context,
        emoji: '🚗',
        title: 'เลือกรุ่นรถหรือพิมพ์ชื่อรุ่น',
        sub: 'ระบบจะค้นหาอะไหล่ที่เข้ากันได้ทั้งหมด',
      );
    }

    // .jsx filter: p.compat && p.compat.toLowerCase().includes(q)
    final results = products
        .where((p) =>
            (p.compat ?? '').isNotEmpty &&
            p.compat!.toLowerCase().contains(q))
        .toList();

    if (results.isEmpty) {
      return _emptyState(
        context,
        emoji: '🔧',
        title: 'ไม่พบอะไหล่สำหรับ "$_query"',
        sub: 'ลองค้นหาด้วยชื่ออื่น หรือตรวจสอบฟิลด์ Compat ในสต็อก',
      );
    }

    final trimmed = _query.trim();
    // Cap content width so result cards don't stretch edge-to-edge on
    // iPad-landscape / desktop (empty/loading states keep their own centering).
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppBreakpoints.rail),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 13, color: AppColors.steelBlue),
              children: [
                const TextSpan(text: 'พบ '),
                TextSpan(
                  text: '${results.length}',
                  style: const TextStyle(
                    color: AppColors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(text: ' รายการ สำหรับ "$_query"'),
              ],
            ),
          ),
        ),
            for (final p in results) ...[
              _resultCard(context, p, categories, trimmed),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  Widget _resultCard(
    BuildContext context,
    ProductRow p,
    List<String> categories,
    String trimmedQuery,
  ) {
    final isOut = p.stock == 0;
    final isLow = p.stock <= p.minStock;
    final Color stockColor = isOut
        ? AppColors.error
        : isLow
            ? AppColors.warning
            : AppColors.successLight;
    final stockLabel = isOut
        ? 'หมด'
        : isLow
            ? 'เหลือ ${p.stock}'
            : '${p.stock} ชิ้น';
    final catColor = AppColors.catColor(p.category, categories);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.gray200.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // cardTop: name block + price/stock
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        height: 1.2,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    if ((p.nameTH).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          p.nameTH,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.steelBlue,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        p.partNo,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: AppColors.gray400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    baht(p.price),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: AppColors.orange,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: stockColor.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: stockColor.withValues(alpha: 0.33),
                      ),
                    ),
                    child: Text(
                      stockLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: stockColor,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          // cardCompat with highlight
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.gray100.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: _highlight(context, p.compat ?? '', trimmedQuery),
          ),
          const SizedBox(height: 8),
          // cardFooter: category badge + brand + copy
          Row(
            children: [
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: catColor.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(4),
                    border:
                        Border.all(color: catColor.withValues(alpha: 0.27)),
                  ),
                  child: Text(
                    p.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: catColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.brand,
                  style: TextStyle(fontSize: 12, color: AppColors.gray400),
                ),
              ),
              OutlinedButton(
                onPressed: () => _copy(p.partNo),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  minimumSize: const Size(0, 44),
                  side: BorderSide(
                    color: AppColors.gray200.withValues(alpha: 0.6),
                  ),
                  foregroundColor: AppColors.steelBlue,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Text(
                  '📋 คัดลอกรหัส',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Port of the .jsx highlight(): wraps the first case-insensitive match of [q]
  /// inside [text] in an orange-tinted span.
  Widget _highlight(BuildContext context, String text, String q) {
    final baseStyle = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: AppColors.steelBlue,
    );
    if (q.isEmpty || text.isEmpty) {
      return Text(text, style: baseStyle);
    }
    final idx = text.toLowerCase().indexOf(q.toLowerCase());
    if (idx == -1) {
      return Text(text, style: baseStyle);
    }
    final before = text.substring(0, idx);
    final match = text.substring(idx, idx + q.length);
    final after = text.substring(idx + q.length);
    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: before),
          TextSpan(
            text: match,
            style: const TextStyle(
              backgroundColor: Color(0x59E8601C), // rgba(232,96,28,0.35)
              color: Color(0xFFFFCC88),
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: after),
        ],
      ),
    );
  }

  Widget _emptyState(
    BuildContext context, {
    required String emoji,
    required String title,
    required String sub,
  }) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(top: 60, left: 24, right: 24),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 40)),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.steelBlue),
            ),
          ],
        ),
      ),
    );
  }
}
