// products_screen.dart — Inventory Management (4 tabs).
//
// Flutter port of pos/ProductsScreen.jsx (Stock / Price Calc / Suppliers /
// Reports) + the LabelPrinter sub-view. Data flows ONLY through repository
// injection; money is formatted with baht(); category colors come from
// AppColors.catColor (db.js getCatColor parity). Stock can only change via the
// "± ปรับ" adjust action (adjustStock clamps at 0 + writes a movement); the edit
// form strips stock + partNo exactly like the JSX.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/movements_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/suppliers_repository.dart';
import '../../domain/models/aggregates.dart';
import '../../domain/reports/net_sales.dart'
    show NetSales, PaymentGroup, TopItem, toReportLites;
import '../widgets/confirm_dialog.dart';
import '../widgets/label_printer.dart';
import '../widgets/loading_view.dart';
import '../widgets/sync_status_builder.dart';
import '../widgets/thai_format.dart';
import 'vehicle_search_screen.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  // Mirrors ProductsScreen.jsx: the "🔍 ค้นหาตามรุ่นรถ" button renders the
  // VehicleSearch modal in place (setShowVehicleSearch(true)). Here we show the
  // same VehicleSearchScreen content as a fullscreen dialog with a close
  // affordance (the screen is a self-contained Scaffold with no close button).
  Future<void> _openVehicleSearch(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'ปิด',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
            const Expanded(child: VehicleSearchScreen()),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      body: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  offset: const Offset(0, 2),
                  blurRadius: 6,
                ),
              ],
            ),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      controller: _tabs,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelColor: AppColors.orange,
                      unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
                      indicatorColor: AppColors.orange,
                      indicatorWeight: 3,
                      dividerColor: Colors.transparent,
                      labelStyle: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontWeight: FontWeight.normal,
                        fontSize: 16,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tabs: const [
                        Tab(text: 'สต็อก · Stock', height: 64),
                        Tab(text: 'คำนวณราคา · Price Calc', height: 64),
                        Tab(text: 'ซัพพลายเออร์ · Suppliers', height: 64),
                        Tab(text: 'รายงานสต็อก · Reports', height: 64),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 16, left: 8),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.orange.withValues(
                          alpha: 0.1,
                        ),
                        foregroundColor: AppColors.orange,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => _openVehicleSearch(context),
                      icon: const Icon(Icons.directions_car, size: 22),
                      label: const Text(
                        'ค้นหาตามรุ่นรถ',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _StockTab(),
                _PriceCalcTab(),
                _SuppliersTab(),
                _InvReportTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STOCK TAB
// ─────────────────────────────────────────────────────────────────────────────
class _StockTab extends StatefulWidget {
  const _StockTab();
  @override
  State<_StockTab> createState() => _StockTabState();
}

class _StockTabState extends State<_StockTab> {
  List<ProductRow> _products = [];
  List<String> _categories = [];
  bool _loading = true;

  String _search = '';
  String _filterCat = 'All';
  String _filterStatus = 'All'; // All | Low | Out
  bool _showCatMgr = false;
  final _newCatCtrl = TextEditingController();

  // Bulk delete (selection mode). Selection survives filter changes on
  // purpose, so the confirm dialog always lists EVERY selected item.
  bool _selecting = false;
  final Set<String> _selected = {};
  bool _deleting = false;

  /// A delete flow (bulk or single) is running — from the first await to the
  /// end. Set BEFORE the first await so a double tap cannot open two dialogs,
  /// and every other product write on this tab is disabled while it holds.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newCatCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<ProductsRepository>();
    final products = await repo.getAll();
    final cats = await repo.getCategories();
    if (!mounted) return;
    setState(() {
      _products = products;
      _categories = cats;
      _loading = false;
      // A product deleted elsewhere can no longer be selected.
      final live = products.map((p) => p.id).toSet();
      _selected.retainWhere(live.contains);
    });
  }

  Color _catColor(String c) => AppColors.catColor(c, _categories);

  List<ProductRow> get _filtered {
    final q = _search.toLowerCase();
    return _products.where((p) {
      final zOk = _filterCat == 'All' || p.category == _filterCat;
      final sOk =
          _filterStatus == 'All' ||
          (_filterStatus == 'Low' && p.stock > 0 && p.stock <= p.minStock) ||
          (_filterStatus == 'Out' && p.stock == 0);
      final searchOk =
          q.isEmpty ||
          p.name.toLowerCase().contains(q) ||
          p.nameTH.contains(q) ||
          p.partNo.toLowerCase().contains(q);
      return zOk && sOk && searchOk;
    }).toList();
  }

  Future<void> _addCat() async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final v = _newCatCtrl.text.trim();
    if (v.isEmpty) return;
    try {
      await context.read<ProductsRepository>().addCategory(v);
    } catch (e) {
      _showError(e);
      return;
    }
    _newCatCtrl.clear();
    await _load();
  }

  /// A refused write reaches the counter as its Thai message (PR #572).
  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ServerErrorResolver.resolveCounterError(e))),
    );
  }

  Future<void> _deleteCat(String name) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final repo = context.read<ProductsRepository>();
    final ok = await showConfirm(
      context,
      'ลบประเภท',
      'ลบประเภท "$name"?',
      danger: true,
    );
    if (!ok) return;
    try {
      await repo.deleteCategory(name);
    } catch (e) {
      _showError(e);
      return;
    }
    if (_filterCat == name) _filterCat = 'All';
    await _load();
  }

  Future<void> _openEdit(ProductRow? p) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProductEditDialog(
        product: p,
        categories: _categories,
        onCategoriesChanged: _load,
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _openAdjust(ProductRow p) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustStockDialog(product: p),
    );
    if (done == true) await _load();
  }

  Future<void> _delete(ProductRow p) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = context.read<ProductsRepository>();
      final ok = await showConfirm(
        context,
        'ลบสินค้า',
        'ลบสินค้า "${p.name}" (${p.partNo}) ?\nการลบจะไม่สามารถกู้คืนได้',
        danger: true,
      );
      if (!ok || !mounted) return;
      if (context.isDegraded) {
        _showDegradedWarning();
        return;
      }
      // Same guard + per-id error handling as the bulk path: an outbox
      // reference or a server refusal reaches the counter as Thai text.
      final result = await repo.deleteMany([p.id]);
      await _load();
      if (!mounted) return;
      final reason = result.failed[p.id];
      if (reason != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(reason)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selected.clear();
    });
  }

  void _toggleOne(String id, bool? on) {
    setState(() => on == true ? _selected.add(id) : _selected.remove(id));
  }

  void _selectAllFiltered(List<ProductRow> filtered, bool on) {
    setState(() {
      for (final p in filtered) {
        on ? _selected.add(p.id) : _selected.remove(p.id);
      }
    });
  }

  Future<void> _bulkDelete() async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _bulkDeleteFlow();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deleting = false;
        });
      }
    }
  }

  Future<void> _bulkDeleteFlow() async {
    final repo = context.read<ProductsRepository>();
    final chosen = _products.where((p) => _selected.contains(p.id)).toList();
    final unsynced = await repo.productIdsWithUnsyncedOps();
    if (!mounted) return;
    final blocked = chosen.where((p) => unsynced.contains(p.id)).toList();
    final deletable = chosen.where((p) => !unsynced.contains(p.id)).toList();
    final docRefs = await repo.openDocumentRefs(deletable);
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _BulkDeleteDialog(
        deletable: deletable,
        blocked: blocked,
        docRefs: docRefs,
      ),
    );
    if (ok != true || !mounted || deletable.isEmpty) return;
    // The link may have dropped while the dialog was open.
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }

    setState(() => _deleting = true);
    final result = await repo.deleteMany(
      deletable.map((p) => p.id).toList(),
    );
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selected.removeAll(result.deleted);
    });
    await _load();
    if (!mounted) return;

    if (result.failed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ลบแล้ว ${result.deleted.length} รายการ')),
      );
      return;
    }
    final byId = {for (final p in chosen) p.id: p};
    // A failed item can be gone after the reload (e.g. the server did apply a
    // delete whose reply was lost) — it is then no longer selected; say so.
    final live = _products.map((p) => p.id).toSet();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ผลการลบสินค้า'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ลบแล้ว ${result.deleted.length} รายการ'),
              Text(
                'ไม่สำเร็จ ${result.failed.length} รายการ '
                '(รายการที่ยังอยู่ในคลังยังเลือกค้างไว้)',
                style: const TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in result.failed.entries)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${byId[e.key]?.name ?? e.key} (${byId[e.key]?.partNo ?? ''})',
                        ),
                        subtitle: Text(
                          live.contains(e.key)
                              ? e.value
                              : '${e.value} · ไม่พบสินค้านี้แล้ว (อาจถูกลบไปแล้ว)',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('ปิด'),
          ),
        ],
      ),
    );
  }

  void _showDegradedWarning() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับสินค้าได้'),
      ),
    );
  }

  void _printLabels(List<ProductRow> products, List<String> ids) {
    showDialog(
      context: context,
      builder: (_) => LabelPrinter(
        products: _products,
        selectedIds: ids,
        categories: _categories,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        final theme = Theme.of(context);
        final lowCount = _products
            .where((p) => p.stock > 0 && p.stock <= p.minStock)
            .length;
        final outCount = _products.where((p) => p.stock == 0).length;
        final filtered = _filtered;

        return Column(
          children: [
            // toolbar
            Container(
          width: double.infinity,
          color: theme.colorScheme.surface,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 16,
                children: [
                  // Left side: Summaries
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _summaryChip(
                        'ทั้งหมด',
                        _products.length,
                        theme.colorScheme.onSurface,
                        'All',
                      ),
                      _summaryChip(
                        'สต็อกต่ำ',
                        lowCount,
                        AppColors.warning,
                        'Low',
                      ),
                      _summaryChip(
                        'หมดสต็อก',
                        outCount,
                        AppColors.error,
                        'Out',
                      ),
                    ],
                  ),
                  // Right side: Search & Actions
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 260,
                        child: TextField(
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'ค้นหา ชื่อ / รหัส…',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            filled: true,
                            fillColor: theme.colorScheme.surfaceContainerLow,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: AppColors.orange,
                                width: 2,
                              ),
                            ),
                          ),
                          onChanged: (v) => setState(() => _search = v),
                        ),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.orange,
                          foregroundColor: AppColors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: isDegraded || _busy ? null : () => _openEdit(null),
                        icon: const Icon(Icons.add, size: 20),
                        label: const Text(
                          'เพิ่มสินค้า',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.navyMid,
                          foregroundColor: AppColors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _printLabels(
                          filtered,
                          filtered.map((p) => p.id).toList(),
                        ),
                        icon: const Icon(Icons.print, size: 20),
                        label: const Text(
                          'พิมพ์ป้าย',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key('bulk-delete-toggle'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _busy ? null : _toggleSelecting,
                        icon: Icon(
                          _selecting ? Icons.close : Icons.checklist,
                          size: 20,
                        ),
                        label: Text(
                          _selecting ? 'ยกเลิกการเลือก' : 'เลือกเพื่อลบ',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Bottom row: Categories & Manage
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _catFilterBtn(
                            'ทั้งหมด',
                            _filterCat == 'All',
                            null,
                            () => setState(() => _filterCat = 'All'),
                          ),
                          const SizedBox(width: 8),
                          ..._categories.map(
                            (c) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _catFilterBtn(
                                c,
                                _filterCat == c,
                                _catColor(c),
                                () => setState(
                                  () =>
                                      _filterCat = _filterCat == c ? 'All' : c,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.secondary,
                    ),
                    onPressed: () => setState(() => _showCatMgr = !_showCatMgr),
                    icon: const Icon(Icons.settings, size: 18),
                    label: const Text(
                      'จัดการประเภท',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_showCatMgr) _catManagerPanel(theme, isDegraded),
        // table
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    'ไม่พบสินค้า',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                )
              : Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.dividerColor.withValues(alpha: 0.3),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth,
                            ),
                            child: DataTable(
                              showCheckboxColumn: _selecting,
                              onSelectAll: _selecting && !_busy
                                  ? (on) =>
                                        _selectAllFiltered(filtered, on == true)
                                  : null,
                              dataRowMinHeight: 70,
                              dataRowMaxHeight: double.infinity,
                              horizontalMargin: 24,
                              columnSpacing: 28,
                              headingTextStyle: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurface,
                                fontSize: 14,
                              ),
                              columns: const [
                                DataColumn(label: Text('รหัสสินค้า')),
                                DataColumn(label: Text('ชื่อสินค้า')),
                                DataColumn(label: Text('ประเภท')),
                                DataColumn(
                                  label: Text('ราคาขาย'),
                                  numeric: true,
                                ),
                                DataColumn(
                                  label: Text('ราคาทุน'),
                                  numeric: true,
                                ),
                                DataColumn(
                                  label: Text('คงเหลือ'),
                                  numeric: true,
                                ),
                                DataColumn(label: Text('Min'), numeric: true),
                                DataColumn(label: Text('สถานะ')),
                                DataColumn(label: Text('')),
                              ],
                              rows: filtered
                                  .map((p) => _buildRow(p, isDegraded))
                                  .toList(),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        if (_selecting) _bulkBar(theme, filtered, isDegraded),
      ],
    );
      },
    );
  }

  DataRow _buildRow(ProductRow p, bool isDegraded) {
    final theme = Theme.of(context);
    final (statusLabel, statusColor) = p.stock == 0
        ? ('Out of Stock', AppColors.error)
        : p.stock <= p.minStock
        ? ('Low Stock', AppColors.warning)
        : ('In Stock', AppColors.successLight);
    return DataRow(
      selected: _selecting && _selected.contains(p.id),
      onSelectChanged: _selecting && !_busy
          ? (on) => _toggleOne(p.id, on)
          : null,
      cells: [
        DataCell(
          Text(
            p.partNo,
            style: const TextStyle(
              color: AppColors.orange,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        DataCell(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  p.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  p.nameTH,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        DataCell(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _catColor(p.category).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              p.category,
              style: TextStyle(
                color: _catColor(p.category),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        DataCell(
          Text(
            baht(p.price),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
        ),
        DataCell(
          Text(
            baht(p.cost),
            style: TextStyle(
              color: theme.colorScheme.secondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        DataCell(
          Text(
            '${p.stock}',
            style: TextStyle(
              color: statusColor,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        DataCell(
          Text(
            '${p.minStock}',
            style: TextStyle(color: theme.colorScheme.secondary),
          ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        DataCell(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.successLight.withValues(
                      alpha: 0.15,
                    ),
                    foregroundColor: AppColors.successLight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: isDegraded || _busy ? null : () => _openAdjust(p),
                  icon: const Icon(Icons.sync_alt, size: 18),
                  label: const Text(
                    'ปรับสต็อก',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: isDegraded || _busy ? null : () => _openEdit(p),
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text(
                    'แก้ไข',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'พิมพ์ป้าย',
                  icon: const Icon(Icons.print_outlined, size: 20),
                  color: theme.colorScheme.primary,
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primaryContainer
                        .withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => _printLabels(_products, [p.id]),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'ลบ',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.error,
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.error.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: isDegraded || _busy ? null : () => _delete(p),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Sticky bottom bar while selecting: count, select-all-of-filtered, clear,
  /// and the destructive action (disabled offline / in flight / empty).
  Widget _bulkBar(
    ThemeData theme,
    List<ProductRow> filtered,
    bool isDegraded,
  ) {
    final n = _selected.length;
    final visible = filtered.map((p) => p.id).toSet();
    final hidden = _selected.where((id) => !visible.contains(id)).length;
    final allFilteredOn =
        filtered.isNotEmpty && filtered.every((p) => _selected.contains(p.id));
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'เลือกแล้ว $n รายการ',
                key: const Key('bulk-delete-count'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (hidden > 0)
                Text(
                  '(ไม่อยู่ในตัวกรอง $hidden)',
                  style: TextStyle(color: theme.colorScheme.secondary),
                ),
              TextButton(
                key: const Key('bulk-select-all'),
                onPressed: _busy || filtered.isEmpty
                    ? null
                    : () => _selectAllFiltered(filtered, !allFilteredOn),
                child: Text(
                  allFilteredOn
                      ? 'ไม่เลือกทั้งหมด (ที่กรองอยู่)'
                      : 'เลือกทั้งหมด (ที่กรองอยู่ ${filtered.length})',
                ),
              ),
              TextButton(
                onPressed: _busy || n == 0
                    ? null
                    : () => setState(_selected.clear),
                child: const Text('ล้างที่เลือก'),
              ),
              FilledButton.icon(
                key: const Key('bulk-delete-go'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.white,
                ),
                onPressed: isDegraded || _busy || n == 0
                    ? null
                    : _bulkDelete,
                icon: _deleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.white,
                        ),
                      )
                    : const Icon(Icons.delete_outline, size: 20),
                label: Text(_deleting ? 'กำลังลบ…' : 'ลบที่เลือก ($n)'),
              ),
              if (isDegraded)
                const Text(
                  'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับสินค้าได้',
                  style: TextStyle(color: AppColors.error),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryChip(String label, int n, Color color, String status) {
    final active = _filterStatus == status;
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(
          () => _filterStatus = _filterStatus == status ? 'All' : status,
        ),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          constraints: const BoxConstraints(minWidth: 90),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? color.withValues(alpha: 0.1)
                : theme.colorScheme.surface,
            border: Border.all(
              color: active ? color : theme.dividerColor.withValues(alpha: 0.3),
              width: active ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: active
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$n',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: color,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: active ? color : theme.colorScheme.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _catFilterBtn(
    String label,
    bool active,
    Color? color,
    VoidCallback onTap,
  ) {
    final bg = active ? (color ?? AppColors.orange) : Colors.transparent;
    final fg = active ? AppColors.white : (color ?? AppColors.orange);
    final border = color ?? AppColors.orange;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          backgroundColor: bg,
          side: BorderSide(
            color: active ? Colors.transparent : border.withValues(alpha: 0.5),
            width: 1,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: active ? 2 : 0,
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _catManagerPanel(ThemeData theme, bool isDegraded) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          Text(
            'จัดการประเภท:',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
          ..._categories.map((c) {
            final color = _catColor(c);
            return Chip(
              label: Text(c, style: TextStyle(color: color)),
              backgroundColor: color.withValues(alpha: 0.13),
              side: BorderSide(color: color.withValues(alpha: 0.33)),
              deleteIcon: Icon(Icons.close, size: 14, color: color),
              onDeleted: isDegraded || _busy ? null : () => _deleteCat(c),
            );
          }),
          SizedBox(
            width: 160,
            child: TextField(
              controller: _newCatCtrl,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'ประเภทใหม่…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: isDegraded || _busy ? null : (_) => _addCat(),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            onPressed: isDegraded || _busy ? null : _addCat,
            child: const Text('+ เพิ่ม'),
          ),
        ],
      ),
    );
  }
}

// ── Product add/edit dialog ──────────────────────────────────────────────────
/// Above this many items the counter must type the count to confirm; any item
/// still holding stock also requires it (owner decision 2026-10-01: both kept).
const _typedConfirmAbove = 5;

/// Confirm for a bulk delete: lists every item (name, part no, stock), warns
/// about remaining stock, shows what cannot be deleted and why. Cancel is the
/// focused default; the destructive button stays disabled until a typed
/// confirmation matches when one is required.
class _BulkDeleteDialog extends StatefulWidget {
  const _BulkDeleteDialog({
    required this.deletable,
    required this.blocked,
    required this.docRefs,
  });
  final List<ProductRow> deletable;
  final List<ProductRow> blocked;

  /// productId → still-open documents naming it (warning only, 2026-10-01).
  final Map<String, List<ProductDocRef>> docRefs;

  @override
  State<_BulkDeleteDialog> createState() => _BulkDeleteDialogState();
}

class _BulkDeleteDialogState extends State<_BulkDeleteDialog> {
  final _typed = TextEditingController();

  static String _refLabel(ProductDocRef r) => switch (r.kind) {
    ProductDocKind.openPo => 'ใบสั่งซื้อ ${r.docNo}',
    ProductDocKind.activeQuote => 'ใบเสนอราคา ${r.docNo}',
    ProductDocKind.parkedBill => 'บิลที่พัก ${thaiDateTime(r.parkedAt!)}',
  };

  /// "อยู่ใน: ใบสั่งซื้อ PO…, บิลที่พัก …" — null when nothing references it.
  static String? _refsNote(List<ProductDocRef>? refs) =>
      refs == null || refs.isEmpty
      ? null
      : 'อยู่ใน: ${refs.map(_refLabel).join(', ')}';

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.deletable.length;
    final stocked = widget.deletable.where((p) => p.stock > 0).toList();
    final stockUnits = stocked.fold<int>(0, (a, p) => a + p.stock);
    // Threshold counts EVERY selected item (blocked ones too): the counter
    // picked that many, whatever this run can actually delete.
    final selectedCount = n + widget.blocked.length;
    final needTyped = selectedCount > _typedConfirmAbove || stocked.isNotEmpty;
    final typedOk = !needTyped || _typed.text.trim() == '$n';
    final referenced = widget.deletable
        .where((p) => widget.docRefs[p.id]?.isNotEmpty ?? false)
        .toList();

    Widget row(ProductRow p, {String? note}) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(note == null ? p.partNo : '${p.partNo} · $note'),
      trailing: Text(
        'คงเหลือ ${p.stock}',
        style: TextStyle(
          color: p.stock > 0 ? AppColors.error : theme.colorScheme.secondary,
          fontWeight: p.stock > 0 ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );

    return AlertDialog(
      title: Text(n == 0 ? 'ลบสินค้าไม่ได้' : 'ลบสินค้า $n รายการ'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n > 0)
              const Text(
                'การลบจะไม่สามารถกู้คืนได้',
                style: TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (stocked.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('bulk-delete-stock-warning'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '⚠ มี ${stocked.length} รายการที่ยังมีสต็อกคงเหลือ '
                  'รวม $stockUnits ชิ้น — สต็อกนี้จะหายจากคลังด้วย',
                ),
              ),
            ],
            if (referenced.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('bulk-delete-docref-warning'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '⚠ มี ${referenced.length} รายการที่อยู่ในใบสั่งซื้อที่ยังไม่รับของ '
                  'ใบเสนอราคาที่ยังไม่หมดอายุ หรือบิลที่พักในเครื่องนี้ '
                  '— ยังลบได้ แต่เอกสารเหล่านั้นจะอ้างถึงสินค้าที่ถูกลบ',
                ),
              ),
            ],
            if (widget.blocked.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'ลบไม่ได้ ${widget.blocked.length} รายการ: $productHasUnsyncedOps',
                style: TextStyle(color: theme.colorScheme.secondary),
              ),
            ],
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in widget.deletable)
                    row(p, note: _refsNote(widget.docRefs[p.id])),
                  for (final p in widget.blocked) row(p, note: 'ลบไม่ได้'),
                ],
              ),
            ),
            if (n > 0 && needTyped) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('bulk-delete-typed'),
                controller: _typed,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'พิมพ์ $n เพื่อยืนยัน',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(n == 0 ? 'ปิด' : 'ยกเลิก'),
        ),
        if (n > 0)
          FilledButton(
            key: const Key('bulk-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.white,
            ),
            onPressed: typedOk ? () => Navigator.of(context).pop(true) : null,
            child: Text('ลบ $n รายการ'),
          ),
      ],
    );
  }
}

/// The `products.name` to save: the EN name, or the (trimmed) Thai name when
/// EN is blank. Empty only when both are blank — the form then refuses.
@visibleForTesting
String productNameOrThai(String nameEn, String nameTh) {
  final en = nameEn.trim();
  return en.isNotEmpty ? en : nameTh.trim();
}

class _ProductEditDialog extends StatefulWidget {
  final ProductRow? product; // null = new
  final List<String> categories;
  final Future<void> Function() onCategoriesChanged;
  const _ProductEditDialog({
    required this.product,
    required this.categories,
    required this.onCategoriesChanged,
  });

  @override
  State<_ProductEditDialog> createState() => _ProductEditDialogState();
}

class _ProductEditDialogState extends State<_ProductEditDialog> {
  late final bool _isNew;
  late List<String> _categories;

  late final TextEditingController _partNo;
  late final TextEditingController _name;
  late final TextEditingController _nameTH;
  late final TextEditingController _brand;
  late final TextEditingController _compat;
  late final TextEditingController _stock;
  late final TextEditingController _minStock;
  late final TextEditingController _cost;
  late final TextEditingController _freight; // UI-only (margin calc)
  late final TextEditingController _price;
  final _newCatCtrl = TextEditingController();
  late String _category;

  double _taxRate = 7;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _isNew = p == null;
    _categories = List<String>.from(widget.categories);
    _partNo = TextEditingController(text: p?.partNo ?? '');
    // A Thai-only product stores its Thai name in `name` too (see
    // productNameOrThai); show EN blank so editing doesn't look like the user typed it.
    // Lossless: saving with EN blank re-derives the same `name`.
    _name = TextEditingController(
      text: p == null || p.name == p.nameTH ? '' : p.name,
    );
    _nameTH = TextEditingController(text: p?.nameTH ?? '');
    _brand = TextEditingController(text: p?.brand ?? '');
    _compat = TextEditingController(text: p?.compat ?? '');
    _stock = TextEditingController(text: p == null ? '0' : '${p.stock}');
    _minStock = TextEditingController(text: '${p?.minStock ?? 5}');
    _cost = TextEditingController(text: p == null ? '' : _numText(p.cost));
    _freight = TextEditingController(); // products carry no freight column
    _price = TextEditingController(text: p == null ? '' : _numText(p.price));
    _category =
        p?.category ??
        (_categories.isNotEmpty ? _categories.first : 'เครื่องยนต์');
    _loadTax();
  }

  Future<void> _loadTax() async {
    final s = await context.read<SettingsRepository>().getSettings();
    if (!mounted) return;
    setState(() => _taxRate = s.taxRate);
  }

  static String _numText(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    for (final c in [
      _partNo,
      _name,
      _nameTH,
      _brand,
      _compat,
      _stock,
      _minStock,
      _cost,
      _freight,
      _price,
      _newCatCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _fCost => double.tryParse(_cost.text) ?? 0;
  double get _fFreight => double.tryParse(_freight.text) ?? 0;
  double get _fSell => double.tryParse(_price.text) ?? 0;
  double get _vatDivisor => 1 + _taxRate / 100;
  double get _fTotalCost => _fCost + _fFreight;
  double get _fNetSell => _fSell / _vatDivisor;
  double get _fProfit => _fNetSell - _fTotalCost;
  double? get _fMargin => _fNetSell > 0 ? (_fProfit / _fNetSell) * 100 : null;

  Color get _marginColor {
    final m = _fMargin;
    if (m == null) return AppColors.steelBlue;
    if (m >= 30) return AppColors.successLight;
    if (m >= 15) return AppColors.warning;
    return AppColors.error;
  }

  String get _marginLabel {
    final m = _fMargin;
    if (m == null) return '—';
    if (m >= 30) return 'กำไรดี ✓';
    if (m >= 15) return 'พอได้';
    return 'ต่ำเกิน ⚠';
  }

  Future<void> _addCat() async {
    final v = _newCatCtrl.text.trim();
    if (v.isEmpty) return;
    final repo = context.read<ProductsRepository>();
    try {
      await repo.addCategory(v);
    } catch (e) {
      _toast(ServerErrorResolver.resolveCounterError(e));
      return;
    }
    await widget.onCategoriesChanged();
    final cats = await repo.getCategories();
    if (!mounted) return;
    setState(() {
      _categories = cats;
      _category = v;
      _newCatCtrl.clear();
    });
  }

  Future<void> _save() async {
    final partNo = _partNo.text.trim();
    final nameTH = _nameTH.text.trim();
    // Either name is enough; `products.name` is NOT NULL and the server refuses
    // a blank one, so a Thai-only product stores the Thai name in both.
    final name = productNameOrThai(_name.text, nameTH);
    if (partNo.isEmpty) {
      _toast('กรุณากรอกรหัสสินค้า');
      return;
    }
    if (name.isEmpty) {
      _toast('กรุณากรอกชื่อสินค้า');
      return;
    }
    final repo = context.read<ProductsRepository>();

    if (_isNew) {
      final companion = ProductsCompanion.insert(
        id: '', // repo's add() overrides this with newUuid()
        partNo: partNo,
        name: name,
        nameTH: nameTH,
        category: _category,
        brand: _brand.text.trim(),
        price: _fSell,
        cost: _fCost,
        stock: int.tryParse(_stock.text) ?? 0,
        minStock: int.tryParse(_minStock.text) ?? 5,
        compat: Value(_compat.text.trim().isEmpty ? null : _compat.text.trim()),
      );
      final ProductRow? result;
      try {
        result = await repo.add(companion);
      } catch (e) {
        if (mounted) _toast(ServerErrorResolver.resolveCounterError(e));
        return;
      }
      if (!mounted) return;
      if (result == null) {
        _toast('รหัส "$partNo" มีอยู่แล้วในระบบ');
        return;
      }
    } else {
      // Strip stock + partNo from the patch (parity with the JSX).
      final patch = ProductsCompanion(
        name: Value(name),
        nameTH: Value(nameTH),
        category: Value(_category),
        brand: Value(_brand.text.trim()),
        price: Value(_fSell),
        cost: Value(_fCost),
        minStock: Value(int.tryParse(_minStock.text) ?? 5),
        compat: Value(_compat.text.trim().isEmpty ? null : _compat.text.trim()),
      );
      final bool ok;
      try {
        ok = await repo.update(widget.product!.id, patch);
      } catch (e) {
        if (mounted) _toast(ServerErrorResolver.resolveCounterError(e));
        return;
      }
      if (!mounted) return;
      if (!ok) {
        _toast('เกิดข้อผิดพลาดในการบันทึก');
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _isNew ? 'เพิ่มสินค้าใหม่' : 'แก้ไขสินค้า',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              // Two columns that fill the dialog (one below 560 px): each
              // field used to be capped at 300 px, and 2 × 300 + 16 never fit
              // the 612 px content width, so every field sat alone on half a
              // row (#476).
              LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth >= 560
                      ? ((c.maxWidth - 16) / 2).floorToDouble()
                      : c.maxWidth;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 20,
                    children: [
                      SizedBox(
                        width: w,
                        child: _field(
                          'รหัสสินค้า',
                          _partNo,
                          enabled: _isNew,
                          hint: _isNew
                              ? null
                              : 'รหัสไม่สามารถแก้ไขได้ (ผูกกับประวัติการขาย)',
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: _field('ชื่อ (EN)', _name),
                      ),
                      SizedBox(
                        width: w,
                        child: _field('ชื่อ (TH)', _nameTH),
                      ),
                      SizedBox(
                        width: w,
                        child: _field('แบรนด์', _brand),
                      ),
                      SizedBox(
                        width: w,
                        child: _categoryField(theme),
                      ),
                      SizedBox(
                        width: w,
                        child: _field('ใช้กับรถรุ่น', _compat),
                      ),
                      SizedBox(
                        width: w,
                        child: _field(
                          'สต็อก',
                          _stock,
                          enabled: _isNew,
                          numeric: true,
                          hint: _isNew
                              ? null
                              : 'ใช้ปุ่ม "ปรับสต็อก" เพื่อเปลี่ยนสต็อกอย่างถูกต้อง',
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: _field('สต็อกขั้นต่ำ', _minStock, numeric: true),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              _priceCalcBox(theme),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('ยกเลิก'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.orange,
                      foregroundColor: AppColors.white,
                    ),
                    onPressed: _save,
                    child: const Text('บันทึก'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    bool enabled = true,
    bool numeric = false,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          enabled: enabled,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            helperText: hint,
            helperMaxLines: 2,
          ),
        ),
      ],
    );
  }

  Widget _categoryField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('ประเภทสินค้า', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _categories.contains(_category)
                    ? _category
                    : null,
                isDense: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: _categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 96,
              child: TextField(
                controller: _newCatCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'ใหม่…',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addCat(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: AppColors.orange),
              onPressed: _addCat,
              icon: const Icon(Icons.add, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  Widget _priceCalcBox(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(
          color: _marginColor.withValues(alpha: 0.5),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _marginColor.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: _marginColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'คำนวณราคา + กำไร (VAT ${_numText(_taxRate)}% อัตโนมัติ)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: _marginColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 160, maxWidth: 190),
                child: _calcInput('ราคาทุน ฿', _cost),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 160, maxWidth: 190),
                child: _calcInput('ค่าขนส่ง ฿', _freight),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 160, maxWidth: 210),
                child: _calcInput('ราคาขาย ฿ (รวม VAT)', _price, accent: true),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              children: [
                _statCell(
                  'ต้นทุนรวม',
                  baht2(_fTotalCost),
                  theme.colorScheme.onSurface,
                ),
                _statCell(
                  'ราคาสุทธิ',
                  baht2(_fNetSell),
                  theme.colorScheme.onSurface,
                ),
                _statCell(
                  'กำไร',
                  baht2(_fProfit),
                  _fProfit >= 0 ? AppColors.successLight : AppColors.error,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Margin %',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _fMargin != null
                            ? '${_fMargin!.toStringAsFixed(1)}%'
                            : '—',
                        style: TextStyle(
                          fontSize: 28,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                          color: _marginColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _marginColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _marginLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _marginColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCell(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.secondary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _calcInput(
    String label,
    TextEditingController ctrl, {
    bool accent = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            isDense: true,
            hintText: '0',
            border: OutlineInputBorder(
              borderSide: accent
                  ? BorderSide(color: _marginColor, width: 2)
                  : const BorderSide(),
            ),
            enabledBorder: accent
                ? OutlineInputBorder(
                    borderSide: BorderSide(color: _marginColor, width: 2),
                  )
                : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

// ── Adjust stock dialog ──────────────────────────────────────────────────────
class _AdjustStockDialog extends StatefulWidget {
  final ProductRow product;
  const _AdjustStockDialog({required this.product});
  @override
  State<_AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends State<_AdjustStockDialog> {
  final _delta = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _delta.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final d = int.tryParse(_delta.text);
    if (d == null) return;
    try {
      await context.read<ProductsRepository>().adjustStock(
        widget.product.id,
        d,
        d > 0 ? 'adjustment-in' : 'adjustment-out',
        _note.text.isEmpty ? 'Manual adjustment' : _note.text,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ServerErrorResolver.resolveCounterError(e))),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.product;
    final d = int.tryParse(_delta.text);
    final after = d == null ? null : (p.stock + d < 0 ? 0 : p.stock + d);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ปรับสต็อก · Adjust Stock',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      p.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    p.partNo,
                    style: const TextStyle(
                      color: AppColors.orange,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'สต็อกปัจจุบัน',
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${p.stock}',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'จำนวนที่ปรับ (+ เพิ่ม / - ลด)',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _delta,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '+10 หรือ -3',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text('หมายเหตุ', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              TextField(
                controller: _note,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'เหตุผลในการปรับ…',
                  border: OutlineInputBorder(),
                ),
              ),
              if (after != null) ...[
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'สต็อกหลังปรับ',
                        style: TextStyle(color: theme.colorScheme.secondary),
                      ),
                      Text(
                        '$after',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: after <= p.minStock
                              ? AppColors.warning
                              : AppColors.successLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('ยกเลิก'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.orange,
                      foregroundColor: AppColors.white,
                    ),
                    onPressed: _save,
                    child: const Text('บันทึก'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRICE CALC TAB
// ─────────────────────────────────────────────────────────────────────────────
class _PriceCalcTab extends StatefulWidget {
  const _PriceCalcTab();
  @override
  State<_PriceCalcTab> createState() => _PriceCalcTabState();
}

class _PriceCalcResult {
  final double totalCost, netSell, profit, margin;
  _PriceCalcResult(this.totalCost, this.netSell, this.profit, this.margin);
}

class _PriceCalcTabState extends State<_PriceCalcTab> {
  final _cost = TextEditingController();
  final _freight = TextEditingController();
  final _retail = TextEditingController();
  final _garage = TextEditingController();
  double _taxRate = 7;

  @override
  void initState() {
    super.initState();
    _loadTax();
  }

  Future<void> _loadTax() async {
    final s = await context.read<SettingsRepository>().getSettings();
    if (!mounted) return;
    setState(() => _taxRate = s.taxRate);
  }

  @override
  void dispose() {
    _cost.dispose();
    _freight.dispose();
    _retail.dispose();
    _garage.dispose();
    super.dispose();
  }

  double get _vat => 1 + _taxRate / 100;

  // #480: "ราคาขาย (รวม VAT 7%)" in _resultCard was hard-coded; other labels
  // in this tab already compute this from _taxRate (see `taxN` in build()).
  String get _taxLabel => formatRate(_taxRate);

  _PriceCalcResult? _calc(String sell) {
    final c = double.tryParse(_cost.text) ?? 0;
    final f = double.tryParse(_freight.text) ?? 0;
    final s = double.tryParse(sell) ?? 0;
    if (s == 0) return null;
    final totalCost = c + f;
    final netSell = s / _vat;
    final profit = netSell - totalCost;
    final margin = totalCost > 0 ? (profit / netSell) * 100 : 0.0;
    return _PriceCalcResult(totalCost, netSell, profit, margin);
  }

  Color _marginColor(double m) => m >= 30
      ? AppColors.successLight
      : m >= 15
      ? AppColors.warning
      : AppColors.error;

  String _marginLabel(double m) => m >= 30
      ? 'กำไรดี ✓'
      : m >= 15
      ? 'พอได้'
      : 'ต่ำเกิน ⚠';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retail = _calc(_retail.text);
    final garage = _calc(_garage.text);
    final taxN = _taxLabel;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'คำนวณราคาและกำไร',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'กรอกต้นทุน + ค่าส่ง → ใส่ราคาขาย → ระบบคำนวณ margin อัตโนมัติ (หักภาษี VAT $taxN% แล้ว)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(child: _bigInput('ราคาทุน (Cost) ฿', _cost)),
                  const SizedBox(width: 16),
                  Expanded(child: _bigInput('ค่าขนส่ง (Freight) ฿', _freight)),
                ],
              ),
              if (_cost.text.isNotEmpty || _freight.text.isNotEmpty) ...[
                const SizedBox(height: 20),
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'ต้นทุนรวมทั้งหมด',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                      Text(
                        baht2(
                          (double.tryParse(_cost.text) ?? 0) +
                              (double.tryParse(_freight.text) ?? 0),
                        ),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _bigInput(
                      'ราคาขาย ลูกค้าทั่วไป (Retail) ฿',
                      _retail,
                      accent: retail == null
                          ? null
                          : _marginColor(retail.margin),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _bigInput(
                      'ราคาขาย ช่าง/อู่ (Garage) ฿',
                      _garage,
                      accent: garage == null
                          ? null
                          : _marginColor(garage.margin),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _resultCard(
                      '👤 ลูกค้าทั่วไป · Retail',
                      retail,
                      _retail.text,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: _resultCard(
                      '🔧 ช่าง/อู่ · Garage',
                      garage,
                      _garage.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _formulaNote(theme, retail, taxN),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bigInput(String label, TextEditingController ctrl, {Color? accent}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: '0',
            isDense: true,
            enabledBorder: accent != null
                ? OutlineInputBorder(
                    borderSide: BorderSide(color: accent, width: 2),
                  )
                : const OutlineInputBorder(),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _resultCard(String label, _PriceCalcResult? result, String sellPrice) {
    final theme = Theme.of(context);
    final sell = double.tryParse(sellPrice) ?? 0;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
        boxShadow: result != null
            ? [
                BoxShadow(
                  color: _marginColor(result.margin),
                  offset: const Offset(0, -4),
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            color: result != null
                ? _marginColor(result.margin)
                : theme.dividerColor,
          ),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            baht(sell),
            style: const TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ราคาขาย (รวม VAT $_taxLabel%)',
            style: TextStyle(fontSize: 13, color: theme.colorScheme.secondary),
          ),
          const SizedBox(height: 12),
          if (result != null) ...[
            _calcRow('ราคาขาย (ไม่รวม VAT)', baht2(result.netSell)),
            _calcRow('ต้นทุนรวม', baht2(result.totalCost)),
            const Divider(),
            _calcRow(
              'กำไร',
              baht2(result.profit),
              valueColor: AppColors.orange,
              bold: true,
            ),
            const SizedBox(height: 12),
            Text(
              '${result.margin.toStringAsFixed(1)}%',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w800,
                height: 1,
                color: _marginColor(result.margin),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _marginLabel(result.margin),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _marginColor(result.margin),
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(
                'กรอกราคาขายเพื่อคำนวณ',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.secondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _calcRow(
    String label,
    String value, {
    Color? valueColor,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: Theme.of(context).colorScheme.secondary),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _formulaNote(ThemeData theme, _PriceCalcResult? retail, String taxN) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'วิธีคำนวณ',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'ราคาขาย ÷ ${_vat.toStringAsFixed(2)} = ราคาสุทธิ (ไม่รวม VAT $taxN%)\n'
            'ราคาสุทธิ − (ต้นทุน + ค่าส่ง) = กำไร\n'
            'กำไร ÷ ราคาสุทธิ × 100 = Margin %',
            style: TextStyle(
              fontSize: 13,
              height: 1.8,
              color: theme.colorScheme.secondary,
            ),
          ),
          if (retail != null && _cost.text.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                'ตัวอย่าง: ฿${_retail.text} ÷ ${_vat.toStringAsFixed(2)} = ${baht2(retail.netSell)} → กำไร ${baht2(retail.profit)} → margin ${retail.margin.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUPPLIERS TAB
// ─────────────────────────────────────────────────────────────────────────────
class _SuppliersTab extends StatefulWidget {
  const _SuppliersTab();
  @override
  State<_SuppliersTab> createState() => _SuppliersTabState();
}

class _SuppliersTabState extends State<_SuppliersTab> {
  List<ProductRow> _products = [];
  List<SupplierRow> _suppliers = [];
  String _selectedId = '';
  bool _loading = true;
  bool _adding = false;

  final _name = TextEditingController();
  final _unitCost = TextEditingController();
  final _freight = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _unitCost.dispose();
    _freight.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final productsRepo = context.read<ProductsRepository>();
    final suppliersRepo = context.read<SuppliersRepository>();
    final products = await productsRepo.getAll();
    final suppliers = await suppliersRepo.getSuppliers();
    if (!mounted) return;
    setState(() {
      _products = products;
      _suppliers = suppliers;
      if (_selectedId.isEmpty && products.isNotEmpty) {
        _selectedId = products.first.id;
      }
      _loading = false;
    });
  }

  Future<void> _refreshSuppliers() async {
    final suppliers = await context.read<SuppliersRepository>().getSuppliers();
    if (!mounted) return;
    setState(() => _suppliers = suppliers);
  }

  Future<void> _add() async {
    if (context.isDegraded) {
      _showSupplierDegradedWarning();
      return;
    }
    if (_name.text.isEmpty) return;
    try {
      await context.read<SuppliersRepository>().addSupplier(
        productId: _selectedId,
        name: _name.text,
        unitCost: double.tryParse(_unitCost.text) ?? 0,
        freight: double.tryParse(_freight.text) ?? 0,
      );
    } catch (e) {
      _showSupplierError(e);
      return;
    }
    _name.clear();
    _unitCost.clear();
    _freight.clear();
    setState(() => _adding = false);
    await _refreshSuppliers();
  }

  Future<void> _delete(String id) async {
    if (context.isDegraded) {
      _showSupplierDegradedWarning();
      return;
    }
    try {
      await context.read<SuppliersRepository>().deleteSupplier(id);
    } catch (e) {
      _showSupplierError(e);
      return;
    }
    await _refreshSuppliers();
  }

  void _showSupplierError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ServerErrorResolver.resolveCounterError(e))),
    );
  }

  void _showSupplierDegradedWarning() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับซัพพลายเออร์ได้'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        final theme = Theme.of(context);
        final selected = _products.where((p) => p.id == _selectedId).firstOrNull;
        final prodSuppliers =
            _suppliers.where((s) => s.productId == _selectedId).toList()..sort(
              (a, b) => (a.unitCost + a.freight).compareTo(b.unitCost + b.freight),
            );
        final minTotal = prodSuppliers.isEmpty
            ? null
            : prodSuppliers
                  .map((s) => s.unitCost + s.freight)
                  .reduce((a, b) => a < b ? a : b);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // product list
            Container(
          width: 260,
          color: theme.colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'เลือกสินค้า',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _products.length,
                  itemBuilder: (ctx, i) {
                    final p = _products[i];
                    final active = p.id == _selectedId;
                    final count = _suppliers
                        .where((s) => s.productId == p.id)
                        .length;
                    return InkWell(
                      onTap: () => setState(() {
                        _selectedId = p.id;
                        _adding = false;
                      }),
                      child: Container(
                        decoration: BoxDecoration(
                          color: active
                              ? theme.colorScheme.surfaceContainerHighest
                              : null,
                          border: Border(
                            left: BorderSide(
                              color: active
                                  ? AppColors.orange
                                  : Colors.transparent,
                              width: 3,
                            ),
                            bottom: BorderSide(color: theme.dividerColor),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              p.partNo,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.orange,
                              ),
                            ),
                            Text(
                              '$count ซัพฯ',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        // detail
        Expanded(
          child: selected == null
              ? const SizedBox.shrink()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  selected.name,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                Text(
                                  selected.partNo,
                                  style: const TextStyle(
                                    color: AppColors.orange,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.orange,
                              foregroundColor: AppColors.white,
                            ),
                            onPressed: isDegraded
                                ? null
                                : () => setState(() => _adding = true),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('เพิ่มซัพฯ'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (prodSuppliers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              'ยังไม่มีซัพพลายเออร์สำหรับสินค้านี้',
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                              ),
                            ),
                          ),
                        )
                      else
                        _supplierTable(theme, prodSuppliers, minTotal, isDegraded),
                      if (_adding) ...[
                        const SizedBox(height: 20),
                        _addForm(theme, isDegraded),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
      },
    );
  }

  Widget _supplierTable(
    ThemeData theme,
    List<SupplierRow> rows,
    double? minTotal,
    bool isDegraded,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                dataRowMinHeight: 70,
                dataRowMaxHeight: double.infinity,
                horizontalMargin: 24,
                columnSpacing: 32,
                headingTextStyle: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                  fontSize: 14,
                ),
                columns: const [
                  DataColumn(label: Text('ชื่อซัพพลายเออร์')),
                  DataColumn(label: Text('ทุน/ชิ้น'), numeric: true),
                  DataColumn(label: Text('ค่าส่ง'), numeric: true),
                  DataColumn(label: Text('รวม'), numeric: true),
                  DataColumn(label: Text('จัดการ')),
                ],
                rows: rows.map((s) {
                  final total = s.unitCost + s.freight;
                  final isMin = total == minTotal;
                  return DataRow(
                    color: WidgetStateProperty.resolveWith((states) {
                      return isMin
                          ? AppColors.forestGreen.withValues(alpha: 0.05)
                          : null;
                    }),
                    cells: [
                      DataCell(
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                s.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              if (isMin) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.forestGreen,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    '✓ ราคาถูกสุด',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          baht(s.unitCost),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          baht(s.freight),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          baht(total),
                          style: TextStyle(
                            fontWeight: isMin
                                ? FontWeight.w900
                                : FontWeight.w700,
                            fontSize: isMin ? 20 : 15,
                            color: isMin
                                ? AppColors.successLight
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      DataCell(
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: IconButton(
                            tooltip: 'ลบ',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            color: AppColors.error,
                            style: IconButton.styleFrom(
                              backgroundColor: AppColors.error.withValues(
                                alpha: 0.1,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: isDegraded ? null : () => _delete(s.id),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _addForm(ThemeData theme, bool isDegraded) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: AppColors.orange.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppColors.orange.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.add_business, color: AppColors.orange),
              const SizedBox(width: 8),
              Text(
                'เพิ่มซัพพลายเออร์ใหม่',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 200, maxWidth: 300),
                child: _formField('ชื่อซัพพลายเออร์', _name),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 160),
                child: _formField('ราคาต่อชิ้น ฿', _unitCost, numeric: true),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 160),
                child: _formField('ค่าส่ง ฿', _freight, numeric: true),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _adding = false),
                child: const Text(
                  'ยกเลิก',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                onPressed: isDegraded ? null : _add,
                child: const Text(
                  'บันทึก',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _formField(
    String label,
    TextEditingController ctrl, {
    bool numeric = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
            hintText: numeric ? '0' : '',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.orange, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INVENTORY REPORTS TAB
// ─────────────────────────────────────────────────────────────────────────────
class _InvReportTab extends StatefulWidget {
  const _InvReportTab();
  @override
  State<_InvReportTab> createState() => _InvReportTabState();
}

class _InvReportTabState extends State<_InvReportTab> {
  String _subTab = 'daily';
  bool _loading = true;

  List<SaleWithItems> _sales = [];
  List<ReturnWithItems> _returns = [];
  List<ProductRow> _products = [];
  List<MovementRow> _movements = [];
  double _taxRate = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final salesRepo = context.read<SalesRepository>();
    final returnsRepo = context.read<ReturnsRepository>();
    final productsRepo = context.read<ProductsRepository>();
    final movementsRepo = context.read<MovementsRepository>();
    final settingsRepo = context.read<SettingsRepository>();
    final sales = await salesRepo.getSales();
    final returns = await returnsRepo.getReturns();
    final products = await productsRepo.getAll();
    final movements = await movementsRepo.getMovements();
    final settings = await settingsRepo.getSettings();
    if (!mounted) return;
    setState(() {
      _sales = sales;
      _returns = returns;
      _products = products;
      _movements = movements;
      _taxRate = settings.taxRate;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    final theme = Theme.of(context);
    const sub = [
      ['daily', 'ยอดวันนี้'],
      ['monthly', 'กำไรเดือนนี้'],
      ['movement', 'ประวัติสต็อก'],
      ['ranking', 'สินค้าดี/แย่'],
    ];
    return Column(
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: sub.map((s) {
              final active = _subTab == s[0];
              return Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: active
                        ? AppColors.orange
                        : theme.colorScheme.secondary,
                  ),
                  onPressed: () => setState(() => _subTab = s[0]),
                  child: Text(
                    s[1],
                    style: TextStyle(
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _buildSub(theme),
          ),
        ),
      ],
    );
  }

  Widget _buildSub(ThemeData theme) {
    switch (_subTab) {
      case 'monthly':
        return _monthly(theme);
      case 'movement':
        return _movement(theme);
      case 'ranking':
        return _ranking(theme);
      default:
        return _daily(theme);
    }
  }

  bool _sameDay(DateTime d, DateTime now) =>
      d.year == now.year && d.month == now.month && d.day == now.day;

  /// The period's bills net of the period's credit notes, the same rule as the
  /// closing report and the server's `/reports/summary` ([NetSales]).
  NetSales _netSales(bool Function(DateTime) inPeriod) {
    final lites = toReportLites(
      sales: _sales.where((s) => inPeriod(s.sale.date)).toList(),
      returns: _returns.where((r) => inPeriod(r.ret.date)).toList(),
      products: _products,
      originalSales: _sales,
    );
    return NetSales.of(lites.sales, lites.returns, _taxRate);
  }

  Widget _daily(ThemeData theme) {
    final now = DateTime.now();
    final net = _netSales((d) => _sameDay(d, now));
    final todayRevenue = net.netRevenue;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _reportTitle('ยอดขายวันนี้', theme),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _kpi(
                  'รายได้รวม',
                  baht(todayRevenue),
                  AppColors.orange,
                  theme,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _kpi(
                  'จำนวนบิล',
                  '${net.billCount} บิล',
                  theme.colorScheme.onSurface,
                  theme,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _kpi(
                  'เฉลี่ย/บิล',
                  baht(net.avgPerBill.round()),
                  theme.colorScheme.onSurface,
                  theme,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _reportTitle('แบ่งตามวิธีชำระเงิน', theme),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _payCard(
                  '💵 เงินสด · Cash',
                  net.cash,
                  AppColors.orange,
                  theme,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _payCard(
                  '📱 โอน/QR',
                  net.qr,
                  AppColors.steelBlue,
                  theme,
                ),
              ),
            ],
          ),
          if (net.billCount == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'ยังไม่มียอดขายวันนี้\nทำรายการที่หน้า ขายสินค้า เพื่อดูข้อมูล',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.secondary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _monthly(ThemeData theme) {
    final vatDivisor = 1 + _taxRate / 100;
    final now = DateTime.now();
    // Net of the month's credit notes, manual voids dropped. Cost prefers the
    // cost recorded on the bill itself (ADR-0008) — see computeGrossProfit:
    // products.cost is recomputed on every weighted-average PO receive, so it
    // is only the fallback, and a line with no cost anywhere is disclosed.
    final net = _netSales((d) => d.year == now.year && d.month == now.month);
    final monthRevenue = net.netRevenue;
    final monthCost = net.profit.cost;
    final monthProfit = net.profit.profit;
    final estimatedLines = net.profit.estimatedCostLines;
    final unknownLines = net.profit.unknownCostLines;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _reportTitle('กำไรเดือนนี้', theme),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _kpi(
                  'รายได้รวม',
                  baht(monthRevenue),
                  theme.colorScheme.onSurface,
                  theme,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _kpi(
                  'ต้นทุนรวม',
                  baht(monthCost),
                  AppColors.warning,
                  theme,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _kpi(
                  'กำไรสุทธิ',
                  baht(monthProfit.round()),
                  monthProfit >= 0 ? AppColors.successLight : AppColors.error,
                  theme,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Margin % เดือนนี้',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
                if (monthRevenue > 0) ...[
                  Text(
                    '${((monthProfit / (monthRevenue / vatDivisor)) * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 48,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      color: monthProfit >= 0
                          ? AppColors.successLight
                          : AppColors.error,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'จาก ${net.billCount} บิล',
                    style: TextStyle(color: theme.colorScheme.secondary),
                  ),
                  // The CSV export has always disclosed this; the on-screen
                  // number never did — and this is where people actually look.
                  if (estimatedLines > 0 || unknownLines > 0) ...[
                    const SizedBox(height: 10),
                    Text(
                      [
                        if (estimatedLines > 0)
                          '$estimatedLines รายการคำนวณจากต้นทุนปัจจุบัน ไม่ใช่ ณ วันที่ขาย',
                        if (unknownLines > 0)
                          '$unknownLines รายการไม่มีข้อมูลต้นทุน (กำไรจะสูงกว่าจริง)',
                      ].join('\n'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.warning,
                      ),
                    ),
                  ],
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'ยังไม่มีข้อมูลเดือนนี้',
                      style: TextStyle(color: theme.colorScheme.secondary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _movement(ThemeData theme) {
    if (_movements.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _reportTitle('ประวัติการเคลื่อนไหวสต็อก', theme),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'ยังไม่มีประวัติ\nปรับสต็อกจากแท็บ "สต็อก" เพื่อดูประวัติ',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.secondary),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _reportTitle('ประวัติการเคลื่อนไหวสต็อก', theme),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('วันที่')),
              DataColumn(label: Text('สินค้า')),
              DataColumn(label: Text('รหัส')),
              DataColumn(label: Text('ประเภท')),
              DataColumn(label: Text('จำนวน'), numeric: true),
              DataColumn(label: Text('สต็อกหลัง'), numeric: true),
              DataColumn(label: Text('หมายเหตุ')),
            ],
            rows: _movements.map((m) {
              final typeColor = m.type == 'sale'
                  ? AppColors.orange
                  : (m.type == 'adjustment-in' || m.type == 'receive')
                  ? AppColors.successLight
                  : AppColors.warning;
              return DataRow(
                cells: [
                  DataCell(
                    Text(
                      _movDate(m.date),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  DataCell(
                    Text(
                      m.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  DataCell(
                    Text(
                      m.partNo,
                      style: const TextStyle(
                        color: AppColors.orange,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      m.type,
                      style: TextStyle(
                        color: typeColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      '${m.delta > 0 ? '+' : ''}${m.delta}',
                      style: TextStyle(
                        color: m.delta > 0
                            ? AppColors.successLight
                            : AppColors.error,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  DataCell(Text('${m.stockAfter}')),
                  DataCell(
                    Text(
                      m.note ?? '—',
                      style: TextStyle(color: theme.colorScheme.secondary),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  String _movDate(DateTime d) {
    const months = [
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day} $hh:$mm';
  }

  Widget _ranking(ThemeData theme) {
    // Every bill ever, net of every credit note, manual voids dropped — the
    // same rule as the daily/monthly reports ([NetSales]).
    final sorted = [..._netSales((_) => true).topItems]
      ..sort((a, b) => b.qty.compareTo(a.qty));
    final best = sorted.take(5).toList();
    final worst = sorted.length <= 5
        ? sorted.reversed.toList()
        : sorted.sublist(sorted.length - 5).reversed.toList();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _rankList(
              theme,
              '🏆 สินค้าขายดี · Best Sellers',
              best,
              best: true,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: _rankList(
              theme,
              '📉 สินค้าขายช้า · Slow Movers',
              worst,
              best: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rankList(
    ThemeData theme,
    String title,
    List<TopItem> rows, {
    required bool best,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _reportTitle(title, theme),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'ยังไม่มีข้อมูลการขาย',
              style: TextStyle(color: theme.colorScheme.secondary),
            ),
          ),
        ...rows.asMap().entries.map((e) {
          final i = e.key;
          final d = e.value;
          final partNo = d.partNo;
          return Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '#${i + 1}',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: best
                          ? AppColors.orange
                          : theme.colorScheme.secondary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        partNo,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.orange,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: best
                      ? [
                          Text(
                            baht(d.revenue),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: AppColors.successLight,
                            ),
                          ),
                          Text(
                            '${d.qty} ชิ้น',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ]
                      : [
                          Text(
                            '${d.qty} ชิ้น',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            baht(d.revenue),
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ],
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _reportTitle(String t, ThemeData theme) => Text(
    t,
    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
  );

  Widget _kpi(String label, String value, Color color, ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary),
          ),
        ],
      ),
    );
  }

  Widget _payCard(
    String label,
    PaymentGroup group,
    Color color,
    ThemeData theme,
  ) {
    final sum = group.net;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(left: BorderSide(color: color, width: 4)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            baht(sum),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            '${group.bills} บิล',
            style: TextStyle(fontSize: 13, color: theme.colorScheme.secondary),
          ),
        ],
      ),
    );
  }
}
