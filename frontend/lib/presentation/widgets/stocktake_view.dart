// stocktake_view.dart — ตรวจนับสต็อก (stocktake), opened from the Stock tab of
// products_screen.dart (which owns it, CONTRACT.md §5).
//
// Count → see the difference against the system → review → apply. There is no
// new write path: every difference goes through the EXISTING
// ProductsRepository.adjustStock, one product at a time, so the Drift build
// and the API build keep their own adjustStock rules (Drift: clamp at 0 + a
// movement; API: online-only, a 5xx/429/lost reply stays parked in
// PendingWrites and the next press resends the same Idempotency-Key + body).
//
// Rules:
//  • A product with no number typed is NOT counted — never treated as 0.
//  • The deltas are fixed at the FIRST press of ยืนยัน: the page pulls the
//    current stock (getAllFresh — on the API build a failed pull refuses, so
//    no delta comes from a stale cache) and recomputes counted − stock. If any
//    row differs from the review on screen, the new numbers are shown and the
//    user confirms again; otherwise the rows (product + delta) and the note are
//    frozen, and every retry sends exactly those. So a parked API adjustment
//    (fate unknown) is resent under the same Idempotency-Key + body and the
//    server replays it — never applied twice. Stock that moves after the first
//    ยืนยัน (a sale, a PO) is not re-counted; what was reviewed is what is
//    written.
//  • The note carries a per-page tag ("ตรวจนับ <date> #<tag>"), so a second
//    stocktake the same day with the same product + delta never matches a key
//    the first one left parked.
//  • Applying stops at the first failure; what was applied and what is left
//    are both shown, and the left rows stay for ลองอีกครั้ง.
//  • Counts live in memory only (no Drift table): leaving the page asks first.
//    The page is pushed on the root navigator, so it covers the shell nav.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/ids.dart';
import '../../data/db/database.dart';
import '../../data/repositories/products_repository.dart';
import 'barcode_scan_button.dart';
import 'confirm_dialog.dart';
import 'low_stock_alert.dart' show StockLevel, stockLevel;
import 'sync_status_builder.dart';
import 'thai_format.dart';

/// One counted product whose count differs from the system stock it was
/// compared with.
class StocktakeLine {
  final ProductRow product;
  final int counted;
  const StocktakeLine(this.product, this.counted);

  /// Counted − system, against the stock in [product] (the list on screen).
  int get diff => counted - product.stock;
}

/// The rows to review: only products with a count in [counts] (an uncounted
/// product is ignored, never read as 0) whose count differs from its stock,
/// in [products] order.
List<StocktakeLine> stocktakeChanges(
  List<ProductRow> products,
  Map<String, int> counts,
) => [
  for (final p in products)
    if (counts[p.id] != null && counts[p.id] != p.stock)
      StocktakeLine(p, counts[p.id]!),
];

/// A short random tag for one stocktake page (the random tail of a UUIDv7 —
/// its head is the clock and repeats for hours).
String newStocktakeTag() {
  final u = newUuid();
  return u.substring(u.length - 6);
}

/// The note every adjustment of one stocktake carries.
String stocktakeNote(DateTime date, String tag, String extra) {
  final e = extra.trim();
  return 'ตรวจนับ ${thaiDate(date)} #$tag${e.isEmpty ? '' : ' · $e'}';
}

/// Whether [a] and [b] would write the same thing (same products, same deltas).
bool sameStocktakeRows(List<StocktakeLine> a, List<StocktakeLine> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].product.id != b[i].product.id || a[i].diff != b[i].diff) {
      return false;
    }
  }
  return true;
}

class StocktakeApplyResult {
  /// Lines applied, in order.
  final List<StocktakeLine> applied;

  /// The line that failed — null when every line was applied.
  final StocktakeLine? failed;
  final Object? error;
  const StocktakeApplyResult(this.applied, {this.failed, this.error});
}

/// Applies the FROZEN [lines] one by one through [repo]'s adjustStock — each
/// with its own [StocktakeLine.diff], never recomputed — and stops at the first
/// failure. Called again with the same lines and [note] after a failure, it
/// sends the same bytes, so a parked API adjustment is replayed, not repeated.
Future<StocktakeApplyResult> applyStocktake(
  ProductsRepository repo,
  List<StocktakeLine> lines,
  String note, {
  void Function(int done)? onProgress,
}) async {
  final applied = <StocktakeLine>[];
  for (final line in lines) {
    try {
      final p = await repo.getById(line.product.id);
      // agent ร่าง
      if (p == null) throw Exception('ไม่พบสินค้านี้แล้ว');
      await repo.adjustStock(
        p.id,
        line.diff,
        line.diff > 0 ? 'adjustment-in' : 'adjustment-out',
        note,
      );
    } catch (e) {
      return StocktakeApplyResult(applied, failed: line, error: e);
    }
    applied.add(line);
    onProgress?.call(applied.length);
  }
  return StocktakeApplyResult(applied);
}

/// The stocktake page (pushed as a full-screen dialog). Pops `n` = the number
/// of products adjusted when everything was applied, else null.
class StocktakePage extends StatefulWidget {
  const StocktakePage({super.key});

  @override
  State<StocktakePage> createState() => _StocktakePageState();
}

class _StocktakePageState extends State<StocktakePage> {
  List<ProductRow> _products = [];
  List<String> _categories = [];
  bool _loading = true;

  String? _scope; // null = every category
  String _search = '';
  final _searchCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  /// productId → counted. Absent = not counted.
  final Map<String, int> _counts = {};
  final Map<String, TextEditingController> _countCtrls = {};

  bool _reviewing = false;
  bool _applying = false;
  int _progress = 0;

  String? _loadError;

  /// This page's tag in the note (see the header).
  final String _tag = newStocktakeTag();

  /// Set at the first ยืนยัน and kept: a retry must send the same rows
  /// (product + delta) and the same note. [_plan] holds what is still left.
  List<StocktakeLine>? _plan;
  String? _frozenNote;
  final List<StocktakeLine> _applied = [];
  StocktakeLine? _failed;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _noteCtrl.dispose();
    for (final c in _countCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<ProductsRepository>();
    try {
      final products = await repo.getAll();
      final cats = await repo.getCategories();
      if (!mounted) return;
      setState(() {
        _products = products;
        _categories = cats;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = ServerErrorResolver.resolveCounterError(e);
      });
    }
  }

  List<ProductRow> get _visible {
    final q = _search.toLowerCase();
    return _products.where((p) {
      final scopeOk = _scope == null || p.category == _scope;
      final searchOk =
          q.isEmpty ||
          p.name.toLowerCase().contains(q) ||
          p.nameTH.contains(q) ||
          p.partNo.toLowerCase().contains(q);
      return scopeOk && searchOk;
    }).toList();
  }

  TextEditingController _ctrlFor(String id) => _countCtrls.putIfAbsent(
    id,
    () => TextEditingController(text: _counts[id]?.toString() ?? ''),
  );

  void _setCount(String id, String text) {
    final n = int.tryParse(text.trim());
    setState(() {
      if (n == null) {
        _counts.remove(id);
      } else {
        _counts[id] = n;
      }
    });
  }

  void _showDegradedWarning() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับสินค้าได้',
        ),
      ),
    );
  }

  Future<void> _apply() async {
    if (_applying) return;
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final shown = _plan ?? stocktakeChanges(_products, _counts);
    if (shown.isEmpty) return;
    final repo = context.read<ProductsRepository>();
    setState(() {
      _applying = true;
      _progress = 0;
      _failed = null;
      _error = null;
    });
    var plan = _plan;
    if (plan == null) {
      // First ยืนยัน: fix the deltas against the current stock (header).
      final List<ProductRow> fresh;
      try {
        fresh = await repo.getAllFresh();
      } catch (e) {
        if (!mounted) return;
        setState(() => _applying = false);
        _snack(
          // agent ร่าง
          'ดึงยอดสต็อกล่าสุดไม่สำเร็จ ยังไม่ได้ปรับสต็อก — '
          '${ServerErrorResolver.resolveCounterError(e)}',
        );
        return;
      }
      if (!mounted) return;
      final current = stocktakeChanges(fresh, _counts);
      if (!sameStocktakeRows(shown, current)) {
        setState(() {
          _products = fresh;
          _applying = false;
        });
        // agent ร่าง
        _snack(
          'ยอดในระบบเปลี่ยนไประหว่างนับ — ตรวจทานตัวเลขใหม่แล้วกดยืนยันอีกครั้ง',
        );
        return;
      }
      plan = current;
      _plan = plan;
      _frozenNote = stocktakeNote(DateTime.now(), _tag, _noteCtrl.text);
    }
    final result = await applyStocktake(
      repo,
      plan,
      _frozenNote!,
      onProgress: (n) {
        if (mounted) setState(() => _progress = n);
      },
    );
    if (!mounted) return;
    _applied.addAll(result.applied);
    if (result.failed == null) {
      Navigator.of(context).pop(_applied.length);
      return;
    }
    setState(() {
      _plan = plan!.sublist(result.applied.length);
      _failed = result.failed;
      _error = ServerErrorResolver.resolveCounterError(result.error!);
      _applying = false;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onBack() async {
    if (_applying) return;
    // Once frozen, the counts cannot be edited (a new delta = a new key).
    if (_reviewing && _plan == null) {
      setState(() => _reviewing = false);
      return;
    }
    if (_counts.isNotEmpty) {
      final ok = await showConfirm(
        context,
        'ออกจากหน้าตรวจนับ?', // agent ร่าง
        'จำนวนที่นับไว้ ${_counts.length} รายการจะหายไป', // agent ร่าง
        danger: true,
        confirmLabel: 'ออก', // agent ร่าง
      );
      if (!ok || !mounted) return;
    }
    Navigator.of(context).pop(_applied.isEmpty ? null : _applied.length);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _reviewing ? 'ตรวจทานก่อนปรับสต็อก' : 'ตรวจนับสต็อก', // agent ร่าง
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _loadError = null;
                          });
                          _load();
                        },
                        child: const Text('ลองใหม่อีกครั้ง'),
                      ),
                    ],
                  ),
                ),
              )
            : SyncStatusBuilder(
                builder: (context, _, isDegraded) => _reviewing
                    ? _review(Theme.of(context), isDegraded)
                    : _entry(Theme.of(context)),
              ),
      ),
    );
  }

  // ── Step 1–2: count ────────────────────────────────────────────────────────
  Widget _entry(ThemeData theme) {
    final visible = _visible;
    final changes = stocktakeChanges(_products, _counts);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            key: const Key('stocktake-search'),
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'ค้นหา ชื่อ / รหัส…',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_search.isNotEmpty)
                    IconButton(
                      tooltip: 'ล้างคำค้นหา',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _search = '');
                      },
                    ),
                  BarcodeScanButton(
                    onScanned: (v) {
                      _searchCtrl.text = v;
                      setState(() => _search = v);
                    },
                  ),
                ],
              ),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final c in <String?>[null, ..._categories])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c ?? 'ทั้งหมด'),
                    selected: _scope == c,
                    onSelected: (_) => setState(() => _scope = c),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('ไม่พบสินค้า'))
              : ListView.separated(
                  key: const Key('stocktake-list'),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _countRow(theme, visible[i]),
                ),
        ),
        _bottomBar(
          theme,
          Text(
            // agent ร่าง
            'นับแล้ว ${_counts.length} รายการ · ไม่ตรง ${changes.length} รายการ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          FilledButton.icon(
            key: const Key('stocktake-review'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            onPressed: changes.isEmpty
                ? null
                : () => setState(() => _reviewing = true),
            icon: const Icon(Icons.fact_check, size: 20),
            label: Text('ตรวจทาน (${changes.length})'), // agent ร่าง
          ),
        ),
      ],
    );
  }

  Color? _stockColor(ProductRow p) => switch (stockLevel(p)) {
    StockLevel.out => AppColors.error,
    StockLevel.low => AppColors.warning,
    StockLevel.ok => null,
  };

  Widget _countRow(ThemeData theme, ProductRow p) {
    final counted = _counts[p.id];
    final diff = counted == null ? null : counted - p.stock;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  p.partNo,
                  style: const TextStyle(color: AppColors.orange, fontSize: 13),
                ),
                Text(
                  'ในระบบ ${p.stock}', // agent ร่าง
                  style: TextStyle(
                    color: _stockColor(p) ?? theme.colorScheme.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 84,
            child: TextField(
              key: ValueKey('stocktake-count-${p.id}'),
              controller: _ctrlFor(p.id),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.right,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'นับได้', // agent ร่าง
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => _setCount(p.id, v),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              diff == null ? '' : _signed(diff),
              key: ValueKey('stocktake-diff-${p.id}'),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: _diffColor(diff),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _signed(int d) => d > 0 ? '+$d' : (d == 0 ? '0' : '−${-d}');

  Color? _diffColor(int? d) => d == null || d == 0
      ? AppColors.successLight
      : (d > 0 ? AppColors.navyLight : AppColors.error);

  // ── Step 3–4: review and apply ─────────────────────────────────────────────
  Widget _review(ThemeData theme, bool isDegraded) {
    // Once frozen, exactly the rows still to write.
    final changes = _plan ?? stocktakeChanges(_products, _counts);
    final unitsIn = changes
        .where((l) => l.diff > 0)
        .fold<int>(0, (s, l) => s + l.diff);
    final unitsOut = changes
        .where((l) => l.diff < 0)
        .fold<int>(0, (s, l) => s - l.diff);
    final failedId = _failed?.product.id;
    return Column(
      children: [
        Expanded(
          child: ListView(
            key: const Key('stocktake-review-list'),
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null) _failureBox(theme, changes.length),
              Text(
                // agent ร่าง
                'ไม่ตรง ${changes.length} รายการ · เพิ่ม $unitsIn ชิ้น · ลด $unitsOut ชิ้น',
                key: const Key('stocktake-totals'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              for (final l in changes)
                ListTile(
                  key: ValueKey('stocktake-line-${l.product.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: l.product.id == failedId
                      ? const Icon(Icons.error, color: AppColors.error)
                      : null,
                  title: Text(l.product.name),
                  subtitle: Text(
                    // agent ร่าง
                    '${l.product.partNo} · ในระบบ ${l.product.stock} → นับได้ ${l.counted}',
                  ),
                  trailing: Text(
                    _signed(l.diff),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: _diffColor(l.diff),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                // A retry must send the same note (PendingWrites body).
                enabled: _plan == null,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'หมายเหตุเพิ่มเติม (ไม่บังคับ)', // agent ร่าง
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                // agent ร่าง
                'บันทึกการปรับว่า "${_frozenNote ?? stocktakeNote(DateTime.now(), _tag, _noteCtrl.text)}"',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        _bottomBar(
          theme,
          isDegraded
              ? const Text(
                  'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับสินค้าได้',
                  style: TextStyle(color: AppColors.error),
                )
              : Text(
                  _applying
                      // agent ร่าง
                      ? 'กำลังปรับสต็อก $_progress/${changes.length}…'
                      : '',
                ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton(
                // Frozen rows cannot be edited (a new delta = a new key).
                onPressed: _applying || _plan != null
                    ? null
                    : () => setState(() => _reviewing = false),
                child: const Text('กลับไปแก้'), // agent ร่าง
              ),
              FilledButton.icon(
                key: const Key('stocktake-apply'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.orange,
                ),
                onPressed: isDegraded || _applying || changes.isEmpty
                    ? null
                    : _apply,
                icon: const Icon(Icons.check, size: 20),
                label: Text(
                  _error == null ? 'ยืนยันปรับสต็อก' : 'ลองอีกครั้ง',
                ), // agent ร่าง
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _failureBox(ThemeData theme, int remaining) {
    final f = _failed;
    final name = f?.product.name ?? '';
    return Container(
      key: const Key('stocktake-failure'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? AppColors.errorBannerDark
            : AppColors.errorBanner,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // agent ร่าง
            'ปรับสต็อกไม่ครบ — ปรับแล้ว ${_applied.length} รายการ · ยังไม่ได้ปรับ $remaining รายการ',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text('ไม่สำเร็จที่ $name: $_error'), // agent ร่าง
          if (_applied.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'ปรับแล้ว:', // agent ร่าง
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final l in _applied)
              Text(
                // agent ร่าง
                '✓ ${l.product.name} (${l.product.partNo}) → ${l.counted}',
              ),
          ],
        ],
      ),
    );
  }

  Widget _bottomBar(ThemeData theme, Widget info, Widget actions) {
    return Material(
      elevation: 4,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [info, actions],
          ),
        ),
      ),
    );
  }
}
