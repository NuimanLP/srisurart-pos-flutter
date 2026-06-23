// products_screen.dart — Inventory Management (4 tabs).
//
// Flutter port of pos/ProductsScreen.jsx (Stock / Price Calc / Suppliers /
// Reports) + the LabelPrinter sub-view. Data flows ONLY through the Riverpod
// repo providers; money is formatted with baht(); category colors come from
// AppColors.catColor (db.js getCatColor parity). Stock can only change via the
// "± ปรับ" adjust action (adjustStock clamps at 0 + writes a movement); the edit
// form strips stock + partNo exactly like the JSX.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../domain/models/aggregates.dart';
import '../providers/providers.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/label_printer.dart';
import '../widgets/loading_view.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen>
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tabs,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: AppColors.orange,
                    indicatorColor: AppColors.orange,
                    tabs: const [
                      Tab(text: 'สต็อก · Stock'),
                      Tab(text: 'คำนวณราคา · Price Calc'),
                      Tab(text: 'ซัพพลายเออร์ · Suppliers'),
                      Tab(text: 'รายงานสต็อก · Reports'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.orange,
                      side: const BorderSide(color: AppColors.orange),
                    ),
                    onPressed: () {},
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('ค้นหาตามรุ่นรถ'),
                  ),
                ),
              ],
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
class _StockTab extends ConsumerStatefulWidget {
  const _StockTab();
  @override
  ConsumerState<_StockTab> createState() => _StockTabState();
}

class _StockTabState extends ConsumerState<_StockTab> {
  List<ProductRow> _products = [];
  List<String> _categories = [];
  bool _loading = true;

  String _search = '';
  String _filterCat = 'All';
  String _filterStatus = 'All'; // All | Low | Out
  bool _showCatMgr = false;
  final _newCatCtrl = TextEditingController();

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
    final repo = ref.read(productsRepoProvider);
    final products = await repo.getAll();
    final cats = await repo.getCategories();
    if (!mounted) return;
    setState(() {
      _products = products;
      _categories = cats;
      _loading = false;
    });
  }

  Color _catColor(String c) => AppColors.catColor(c, _categories);

  List<ProductRow> get _filtered {
    final q = _search.toLowerCase();
    return _products.where((p) {
      final zOk = _filterCat == 'All' || p.category == _filterCat;
      final sOk = _filterStatus == 'All' ||
          (_filterStatus == 'Low' && p.stock > 0 && p.stock <= p.minStock) ||
          (_filterStatus == 'Out' && p.stock == 0);
      final searchOk = q.isEmpty ||
          p.name.toLowerCase().contains(q) ||
          p.nameTH.contains(q) ||
          p.partNo.toLowerCase().contains(q);
      return zOk && sOk && searchOk;
    }).toList();
  }

  Future<void> _addCat() async {
    final v = _newCatCtrl.text.trim();
    if (v.isEmpty) return;
    await ref.read(productsRepoProvider).addCategory(v);
    _newCatCtrl.clear();
    await _load();
  }

  Future<void> _deleteCat(String name) async {
    final ok = await showConfirm(context, 'ลบประเภท', 'ลบประเภท "$name"?',
        danger: true);
    if (!ok) return;
    await ref.read(productsRepoProvider).deleteCategory(name);
    if (_filterCat == name) _filterCat = 'All';
    await _load();
  }

  Future<void> _openEdit(ProductRow? p) async {
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
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustStockDialog(product: p),
    );
    if (done == true) await _load();
  }

  Future<void> _delete(ProductRow p) async {
    final ok = await showConfirm(
      context,
      'ลบสินค้า',
      'ลบสินค้า "${p.name}" (${p.partNo}) ?\nการลบจะไม่สามารถกู้คืนได้',
      danger: true,
    );
    if (!ok) return;
    await ref.read(productsRepoProvider).delete(p.id);
    await _load();
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
    final theme = Theme.of(context);
    final lowCount =
        _products.where((p) => p.stock > 0 && p.stock <= p.minStock).length;
    final outCount = _products.where((p) => p.stock == 0).length;
    final filtered = _filtered;

    return Column(
      children: [
        // toolbar
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              _summaryChip('ทั้งหมด', _products.length, theme.colorScheme.onSurface, 'All'),
              _summaryChip('สต็อกต่ำ', lowCount, AppColors.warning, 'Low'),
              _summaryChip('หมดสต็อก', outCount, AppColors.error, 'Out'),
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'ค้นหา ชื่อ / รหัส…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              _catFilterBtn('ทั้งหมด', _filterCat == 'All', null,
                  () => setState(() => _filterCat = 'All')),
              ..._categories.map((c) => _catFilterBtn(
                  c, _filterCat == c, _catColor(c),
                  () => setState(() => _filterCat = _filterCat == c ? 'All' : c))),
              TextButton(
                onPressed: () => setState(() => _showCatMgr = !_showCatMgr),
                child: const Text('⚙ จัดการประเภท',
                    style: TextStyle(fontSize: 12)),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.orange,
                    foregroundColor: AppColors.white),
                onPressed: () => _openEdit(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('เพิ่มสินค้า'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.navyMid,
                    foregroundColor: AppColors.white),
                onPressed: () =>
                    _printLabels(filtered, filtered.map((p) => p.id).toList()),
                icon: const Icon(Icons.label_outline, size: 18),
                label: const Text('พิมพ์ป้าย'),
              ),
            ],
          ),
        ),
        if (_showCatMgr) _catManagerPanel(theme),
        // table
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text('ไม่พบสินค้า',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: theme.colorScheme.secondary)))
              : SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SizedBox(
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('รหัสสินค้า')),
                          DataColumn(label: Text('ชื่อสินค้า')),
                          DataColumn(label: Text('ประเภท')),
                          DataColumn(label: Text('ราคาขาย'), numeric: true),
                          DataColumn(label: Text('ราคาทุน'), numeric: true),
                          DataColumn(label: Text('คงเหลือ'), numeric: true),
                          DataColumn(label: Text('Min'), numeric: true),
                          DataColumn(label: Text('สถานะ')),
                          DataColumn(label: Text('')),
                        ],
                        rows: filtered.map(_buildRow).toList(),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  DataRow _buildRow(ProductRow p) {
    final theme = Theme.of(context);
    final (statusLabel, statusColor) = p.stock == 0
        ? ('Out of Stock', AppColors.error)
        : p.stock <= p.minStock
            ? ('Low Stock', AppColors.warning)
            : ('In Stock', AppColors.successLight);
    return DataRow(cells: [
      DataCell(Text(p.partNo,
          style: const TextStyle(color: AppColors.orange, fontSize: 12))),
      DataCell(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(p.nameTH,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.secondary)),
        ],
      )),
      DataCell(Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: _catColor(p.category),
            borderRadius: BorderRadius.circular(3)),
        child: Text(p.category,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
      )),
      DataCell(Text(baht(p.price),
          style: const TextStyle(fontWeight: FontWeight.w700))),
      DataCell(Text(baht(p.cost),
          style: TextStyle(color: theme.colorScheme.secondary))),
      DataCell(Text('${p.stock}',
          style: TextStyle(
              color: statusColor, fontSize: 20, fontWeight: FontWeight.w800))),
      DataCell(Text('${p.minStock}',
          style: TextStyle(color: theme.colorScheme.secondary))),
      DataCell(Text('● $statusLabel',
          style: TextStyle(
              color: statusColor, fontWeight: FontWeight.w700, fontSize: 13))),
      DataCell(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => _openAdjust(p),
            child: const Text('± ปรับ'),
          ),
          OutlinedButton(
            onPressed: () => _openEdit(p),
            child: const Text('แก้ไข'),
          ),
          IconButton(
            tooltip: 'พิมพ์ป้าย',
            icon: const Icon(Icons.label_outline, size: 18),
            onPressed: () => _printLabels(_products, [p.id]),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => _delete(p),
            child: const Text('ลบ'),
          ),
        ],
      )),
    ]);
  }

  Widget _summaryChip(String label, int n, Color color, String status) {
    final active = _filterStatus == status;
    return InkWell(
      onTap: () => setState(
          () => _filterStatus = _filterStatus == status ? 'All' : status),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 80),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.09) : null,
          border: Border.all(
              color: active ? color : Theme.of(context).dividerColor, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$n',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, color: color)),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.secondary)),
          ],
        ),
      ),
    );
  }

  Widget _catFilterBtn(
      String label, bool active, Color? color, VoidCallback onTap) {
    final fg = active ? (color ?? AppColors.orange) : null;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        side: BorderSide(
            color: active
                ? (color ?? AppColors.orange)
                : Theme.of(context).dividerColor),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: const Size(0, 34),
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _catManagerPanel(ThemeData theme) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          Text('จัดการประเภท:',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.secondary)),
          ..._categories.map((c) {
            final color = _catColor(c);
            return Chip(
              label: Text(c, style: TextStyle(color: color)),
              backgroundColor: color.withValues(alpha: 0.13),
              side: BorderSide(color: color.withValues(alpha: 0.33)),
              deleteIcon: Icon(Icons.close, size: 14, color: color),
              onDeleted: () => _deleteCat(c),
            );
          }),
          SizedBox(
            width: 160,
            child: TextField(
              controller: _newCatCtrl,
              decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'ประเภทใหม่…',
                  border: OutlineInputBorder()),
              onSubmitted: (_) => _addCat(),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: AppColors.white),
            onPressed: _addCat,
            child: const Text('+ เพิ่ม'),
          ),
        ],
      ),
    );
  }
}

// ── Product add/edit dialog ──────────────────────────────────────────────────
class _ProductEditDialog extends ConsumerStatefulWidget {
  final ProductRow? product; // null = new
  final List<String> categories;
  final Future<void> Function() onCategoriesChanged;
  const _ProductEditDialog({
    required this.product,
    required this.categories,
    required this.onCategoriesChanged,
  });

  @override
  ConsumerState<_ProductEditDialog> createState() => _ProductEditDialogState();
}

class _ProductEditDialogState extends ConsumerState<_ProductEditDialog> {
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
    _name = TextEditingController(text: p?.name ?? '');
    _nameTH = TextEditingController(text: p?.nameTH ?? '');
    _brand = TextEditingController(text: p?.brand ?? '');
    _compat = TextEditingController(text: p?.compat ?? '');
    _stock = TextEditingController(text: p == null ? '0' : '${p.stock}');
    _minStock = TextEditingController(text: '${p?.minStock ?? 5}');
    _cost = TextEditingController(text: p == null ? '' : _numText(p.cost));
    _freight = TextEditingController(); // products carry no freight column
    _price = TextEditingController(text: p == null ? '' : _numText(p.price));
    _category = p?.category ??
        (_categories.isNotEmpty ? _categories.first : 'เครื่องยนต์');
    _loadTax();
  }

  Future<void> _loadTax() async {
    final s = await ref.read(settingsRepoProvider).getSettings();
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
      _newCatCtrl
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
    await ref.read(productsRepoProvider).addCategory(v);
    await widget.onCategoriesChanged();
    final cats = await ref.read(productsRepoProvider).getCategories();
    if (!mounted) return;
    setState(() {
      _categories = cats;
      _category = v;
      _newCatCtrl.clear();
    });
  }

  Future<void> _save() async {
    final partNo = _partNo.text.trim();
    final name = _name.text.trim();
    if (partNo.isEmpty) {
      _toast('กรุณากรอกรหัสสินค้า');
      return;
    }
    if (name.isEmpty) {
      _toast('กรุณากรอกชื่อสินค้า');
      return;
    }
    final repo = ref.read(productsRepoProvider);

    if (_isNew) {
      final companion = ProductsCompanion.insert(
        id: '', // repo's add() overrides this with newId('p')
        partNo: partNo,
        name: name,
        nameTH: _nameTH.text.trim(),
        category: _category,
        brand: _brand.text.trim(),
        price: _fSell,
        cost: _fCost,
        stock: int.tryParse(_stock.text) ?? 0,
        minStock: int.tryParse(_minStock.text) ?? 5,
        compat: Value(_compat.text.trim().isEmpty ? null : _compat.text.trim()),
      );
      final result = await repo.add(companion);
      if (!mounted) return;
      if (result == null) {
        _toast('รหัส "$partNo" มีอยู่แล้วในระบบ');
        return;
      }
    } else {
      // Strip stock + partNo from the patch (parity with the JSX).
      final patch = ProductsCompanion(
        name: Value(name),
        nameTH: Value(_nameTH.text.trim()),
        category: Value(_category),
        brand: Value(_brand.text.trim()),
        price: Value(_fSell),
        cost: Value(_fCost),
        minStock: Value(int.tryParse(_minStock.text) ?? 5),
        compat: Value(_compat.text.trim().isEmpty ? null : _compat.text.trim()),
      );
      final ok = await repo.update(widget.product!.id, patch);
      if (!mounted) return;
      if (!ok) {
        _toast('เกิดข้อผิดพลาดในการบันทึก');
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
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
              Text(_isNew ? 'เพิ่มสินค้าใหม่' : 'แก้ไขสินค้า',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 4.2,
                children: [
                  _field('รหัสสินค้า', _partNo,
                      enabled: _isNew,
                      hint: _isNew
                          ? null
                          : 'รหัสไม่สามารถแก้ไขได้ (ผูกกับประวัติการขาย)'),
                  _field('ชื่อ (EN)', _name),
                  _field('ชื่อ (TH)', _nameTH),
                  _field('แบรนด์', _brand),
                  _categoryField(theme),
                  _field('ใช้กับรถรุ่น', _compat),
                  _field('สต็อก', _stock,
                      enabled: _isNew,
                      numeric: true,
                      hint: _isNew
                          ? null
                          : 'ใช้ปุ่ม "± ปรับ" เพื่อเปลี่ยนสต็อก (มี audit log)'),
                  _field('สต็อกขั้นต่ำ', _minStock, numeric: true),
                ],
              ),
              const SizedBox(height: 16),
              _priceCalcBox(theme),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('ยกเลิก')),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.orange,
                        foregroundColor: AppColors.white),
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

  Widget _field(String label, TextEditingController ctrl,
      {bool enabled = true, bool numeric = false, String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          enabled: enabled,
          keyboardType:
              numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
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
                initialValue:
                    _categories.contains(_category) ? _category : null,
                isDense: true,
                decoration: const InputDecoration(
                    isDense: true, border: OutlineInputBorder()),
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
                    border: OutlineInputBorder()),
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
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: _marginColor, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              '📊 คำนวณราคา + กำไร (VAT ${_numText(_taxRate)}% อัตโนมัติ)',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.secondary)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _calcInput('ราคาทุน ฿', _cost)),
              const SizedBox(width: 10),
              Expanded(child: _calcInput('ค่าขนส่ง ฿', _freight)),
              const SizedBox(width: 10),
              Expanded(
                  child: _calcInput('ราคาขาย ฿ (รวม VAT)', _price,
                      accent: true)),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                _statCell('ต้นทุนรวม', '฿${_fTotalCost.toStringAsFixed(2)}',
                    theme.colorScheme.onSurface),
                _divider(theme),
                _statCell('ราคาสุทธิ', '฿${_fNetSell.toStringAsFixed(2)}',
                    theme.colorScheme.onSurface),
                _divider(theme),
                _statCell(
                    'กำไร',
                    '฿${_fProfit.toStringAsFixed(2)}',
                    _fProfit >= 0 ? AppColors.successLight : AppColors.error),
                _divider(theme),
                Expanded(
                  flex: 12,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Column(
                      children: [
                        Text('Margin %',
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.secondary)),
                        Text(
                            _fMargin != null
                                ? '${_fMargin!.toStringAsFixed(1)}%'
                                : '—',
                            style: TextStyle(
                                fontSize: 26,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: _marginColor)),
                        Text(_marginLabel,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: _marginColor)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(ThemeData theme) =>
      Container(width: 1, height: 56, color: theme.dividerColor);

  Widget _statCell(String label, String value, Color color) {
    return Expanded(
      flex: 10,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.secondary)),
            const SizedBox(height: 3),
            Text(value,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _calcInput(String label, TextEditingController ctrl,
      {bool accent = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: Theme.of(context).textTheme.labelSmall),
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
                    borderSide: BorderSide(color: _marginColor, width: 2))
                : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

// ── Adjust stock dialog ──────────────────────────────────────────────────────
class _AdjustStockDialog extends ConsumerStatefulWidget {
  final ProductRow product;
  const _AdjustStockDialog({required this.product});
  @override
  ConsumerState<_AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends ConsumerState<_AdjustStockDialog> {
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
    await ref.read(productsRepoProvider).adjustStock(
          widget.product.id,
          d,
          d > 0 ? 'adjustment-in' : 'adjustment-out',
          _note.text.isEmpty ? 'Manual adjustment' : _note.text,
        );
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
              Text('ปรับสต็อก · Adjust Stock',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Text(p.name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                Text(p.partNo,
                    style: const TextStyle(
                        color: AppColors.orange, fontSize: 14)),
              ]),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('สต็อกปัจจุบัน',
                        style: TextStyle(
                            color: theme.colorScheme.secondary,
                            fontWeight: FontWeight.w700)),
                    Text('${p.stock}',
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text('จำนวนที่ปรับ (+ เพิ่ม / - ลด)',
                  style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              TextField(
                controller: _delta,
                keyboardType: const TextInputType.numberWithOptions(signed: true),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22),
                decoration: const InputDecoration(
                    isDense: true,
                    hintText: '+10 หรือ -3',
                    border: OutlineInputBorder()),
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
                    border: OutlineInputBorder()),
              ),
              if (after != null) ...[
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('สต็อกหลังปรับ',
                          style:
                              TextStyle(color: theme.colorScheme.secondary)),
                      Text('$after',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: after <= p.minStock
                                  ? AppColors.warning
                                  : AppColors.successLight)),
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
                      child: const Text('ยกเลิก')),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.orange,
                        foregroundColor: AppColors.white),
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
class _PriceCalcTab extends ConsumerStatefulWidget {
  const _PriceCalcTab();
  @override
  ConsumerState<_PriceCalcTab> createState() => _PriceCalcTabState();
}

class _PriceCalcResult {
  final double totalCost, netSell, profit, margin;
  _PriceCalcResult(this.totalCost, this.netSell, this.profit, this.margin);
}

class _PriceCalcTabState extends ConsumerState<_PriceCalcTab> {
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
    final s = await ref.read(settingsRepoProvider).getSettings();
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
    final taxN = _taxRate == _taxRate.roundToDouble()
        ? _taxRate.toInt().toString()
        : _taxRate.toString();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('คำนวณราคาและกำไร',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                  'กรอกต้นทุน + ค่าส่ง → ใส่ราคาขาย → ระบบคำนวณ margin อัตโนมัติ (หักภาษี VAT $taxN% แล้ว)',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.secondary)),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: _bigInput('ราคาทุน (Cost) ฿', _cost)),
                const SizedBox(width: 16),
                Expanded(child: _bigInput('ค่าขนส่ง (Freight) ฿', _freight)),
              ]),
              if (_cost.text.isNotEmpty || _freight.text.isNotEmpty) ...[
                const SizedBox(height: 20),
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('ต้นทุนรวมทั้งหมด',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.secondary)),
                      Text(
                          '฿${((double.tryParse(_cost.text) ?? 0) + (double.tryParse(_freight.text) ?? 0)).toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                    child: _bigInput('ราคาขาย ลูกค้าทั่วไป (Retail) ฿', _retail,
                        accent: retail == null
                            ? null
                            : _marginColor(retail.margin))),
                const SizedBox(width: 16),
                Expanded(
                    child: _bigInput('ราคาขาย ช่าง/อู่ (Garage) ฿', _garage,
                        accent: garage == null
                            ? null
                            : _marginColor(garage.margin))),
              ]),
              const SizedBox(height: 20),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: _resultCard(
                        '👤 ลูกค้าทั่วไป · Retail', retail, _retail.text)),
                const SizedBox(width: 20),
                Expanded(
                    child: _resultCard(
                        '🔧 ช่าง/อู่ · Garage', garage, _garage.text)),
              ]),
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
                    borderSide: BorderSide(color: accent, width: 2))
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
            ? [BoxShadow(color: _marginColor(result.margin), offset: const Offset(0, -4), spreadRadius: -2)]
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
          Text(label,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.secondary)),
          const SizedBox(height: 8),
          Text(baht(sell),
              style: const TextStyle(
                  fontSize: 42, fontWeight: FontWeight.w800, height: 1)),
          const SizedBox(height: 4),
          Text('ราคาขาย (รวม VAT 7%)',
              style: TextStyle(
                  fontSize: 13, color: theme.colorScheme.secondary)),
          const SizedBox(height: 12),
          if (result != null) ...[
            _calcRow('ราคาขาย (ไม่รวม VAT)',
                '฿${result.netSell.toStringAsFixed(2)}'),
            _calcRow('ต้นทุนรวม', '฿${result.totalCost.toStringAsFixed(2)}'),
            const Divider(),
            _calcRow('กำไร', '฿${result.profit.toStringAsFixed(2)}',
                valueColor: AppColors.orange, bold: true),
            const SizedBox(height: 12),
            Text('${result.margin.toStringAsFixed(1)}%',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    color: _marginColor(result.margin))),
            const SizedBox(height: 6),
            Text(_marginLabel(result.margin),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _marginColor(result.margin))),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text('กรอกราคาขายเพื่อคำนวณ',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.secondary)),
            ),
        ],
      ),
    );
  }

  Widget _calcRow(String label, String value,
      {Color? valueColor, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
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
          Text('วิธีคำนวณ',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.secondary)),
          const SizedBox(height: 6),
          Text(
            'ราคาขาย ÷ ${_vat.toStringAsFixed(2)} = ราคาสุทธิ (ไม่รวม VAT $taxN%)\n'
            'ราคาสุทธิ − (ต้นทุน + ค่าส่ง) = กำไร\n'
            'กำไร ÷ ราคาสุทธิ × 100 = Margin %',
            style: TextStyle(
                fontSize: 13,
                height: 1.8,
                color: theme.colorScheme.secondary),
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
                'ตัวอย่าง: ฿${_retail.text} ÷ ${_vat.toStringAsFixed(2)} = ฿${retail.netSell.toStringAsFixed(2)} → กำไร ฿${retail.profit.toStringAsFixed(2)} → margin ${retail.margin.toStringAsFixed(1)}%',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.secondary),
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
class _SuppliersTab extends ConsumerStatefulWidget {
  const _SuppliersTab();
  @override
  ConsumerState<_SuppliersTab> createState() => _SuppliersTabState();
}

class _SuppliersTabState extends ConsumerState<_SuppliersTab> {
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
    final products = await ref.read(productsRepoProvider).getAll();
    final suppliers = await ref.read(suppliersRepoProvider).getSuppliers();
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
    final suppliers = await ref.read(suppliersRepoProvider).getSuppliers();
    if (!mounted) return;
    setState(() => _suppliers = suppliers);
  }

  Future<void> _add() async {
    if (_name.text.isEmpty) return;
    await ref.read(suppliersRepoProvider).addSupplier(
          productId: _selectedId,
          name: _name.text,
          unitCost: double.tryParse(_unitCost.text) ?? 0,
          freight: double.tryParse(_freight.text) ?? 0,
        );
    _name.clear();
    _unitCost.clear();
    _freight.clear();
    setState(() => _adding = false);
    await _refreshSuppliers();
  }

  Future<void> _delete(String id) async {
    await ref.read(suppliersRepoProvider).deleteSupplier(id);
    await _refreshSuppliers();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    final theme = Theme.of(context);
    final selected =
        _products.where((p) => p.id == _selectedId).firstOrNull;
    final prodSuppliers =
        _suppliers.where((s) => s.productId == _selectedId).toList()
          ..sort((a, b) =>
              (a.unitCost + a.freight).compareTo(b.unitCost + b.freight));
    final minTotal = prodSuppliers.isEmpty
        ? null
        : prodSuppliers
            .map((s) => s.unitCost + s.freight)
            .reduce((a, b) => a < b ? a : b);

    return Row(
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
                child: Text('เลือกสินค้า',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.secondary)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _products.length,
                  itemBuilder: (ctx, i) {
                    final p = _products[i];
                    final active = p.id == _selectedId;
                    final count =
                        _suppliers.where((s) => s.productId == p.id).length;
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
                                width: 3),
                            bottom: BorderSide(color: theme.dividerColor),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            Text(p.partNo,
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.orange)),
                            Text('$count ซัพฯ',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.secondary)),
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
                                Text(selected.name,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                            fontWeight: FontWeight.w800)),
                                Text(selected.partNo,
                                    style: const TextStyle(
                                        color: AppColors.orange,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.orange,
                                foregroundColor: AppColors.white),
                            onPressed: () => setState(() => _adding = true),
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
                                    color: theme.colorScheme.secondary)),
                          ),
                        )
                      else
                        _supplierTable(theme, prodSuppliers, minTotal),
                      if (_adding) ...[
                        const SizedBox(height: 20),
                        _addForm(theme),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _supplierTable(
      ThemeData theme, List<SupplierRow> rows, double? minTotal) {
    return Column(
      children: rows.map((s) {
        final total = s.unitCost + s.freight;
        final isMin = total == minTotal;
        return Container(
          decoration: BoxDecoration(
            color: isMin
                ? AppColors.forestGreen.withValues(alpha: 0.1)
                : null,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (isMin)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.forestGreen,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text('✓ ราคาถูกสุด',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
              ),
              Expanded(
                  child: Text(baht(s.unitCost),
                      textAlign: TextAlign.right)),
              Expanded(
                  child:
                      Text(baht(s.freight), textAlign: TextAlign.right)),
              Expanded(
                child: Text(baht(total),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isMin
                            ? AppColors.successLight
                            : theme.colorScheme.onSurface)),
              ),
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                onPressed: () => _delete(s.id),
                child: const Text('ลบ'),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _addForm(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('เพิ่มซัพพลายเออร์ใหม่',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  flex: 2,
                  child: _formField('ชื่อซัพพลายเออร์', _name)),
              const SizedBox(width: 12),
              Expanded(child: _formField('ราคาต่อชิ้น ฿', _unitCost, numeric: true)),
              const SizedBox(width: 12),
              Expanded(child: _formField('ค่าส่ง ฿', _freight, numeric: true)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                  onPressed: () => setState(() => _adding = false),
                  child: const Text('ยกเลิก')),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.orange,
                    foregroundColor: AppColors.white),
                onPressed: _add,
                child: const Text('เพิ่ม'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _formField(String label, TextEditingController ctrl,
      {bool numeric = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
          decoration: InputDecoration(
              isDense: true,
              hintText: numeric ? '0' : '',
              border: const OutlineInputBorder()),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INVENTORY REPORTS TAB
// ─────────────────────────────────────────────────────────────────────────────
class _InvReportTab extends ConsumerStatefulWidget {
  const _InvReportTab();
  @override
  ConsumerState<_InvReportTab> createState() => _InvReportTabState();
}

class _SoldAgg {
  final String name;
  int qty = 0;
  double revenue = 0;
  _SoldAgg(this.name);
}

class _InvReportTabState extends ConsumerState<_InvReportTab> {
  String _subTab = 'daily';
  bool _loading = true;

  List<SaleWithItems> _sales = [];
  List<ProductRow> _products = [];
  List<MovementRow> _movements = [];
  double _taxRate = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sales = await ref.read(salesRepoProvider).getSales();
    final products = await ref.read(productsRepoProvider).getAll();
    final movements = await ref.read(movementsRepoProvider).getMovements();
    final settings = await ref.read(settingsRepoProvider).getSettings();
    if (!mounted) return;
    setState(() {
      _sales = sales;
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
                  child: Text(s[1],
                      style: TextStyle(
                          fontWeight:
                              active ? FontWeight.w800 : FontWeight.w600)),
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

  Widget _daily(ThemeData theme) {
    final now = DateTime.now();
    final todaySales =
        _sales.where((s) => _sameDay(s.sale.date, now)).toList();
    final todayRevenue =
        todaySales.fold<double>(0, (a, s) => a + s.sale.total);
    final cashSales =
        todaySales.where((s) => s.sale.paymentMethod == 'เงินสด').toList();
    final qrSales = todaySales
        .where((s) =>
            s.sale.paymentMethod == 'โอน/QR' ||
            s.sale.paymentMethod == 'PromptPay' ||
            s.sale.paymentMethod == 'โอนเงิน')
        .toList();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _reportTitle('ยอดขายวันนี้', theme),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: _kpi('รายได้รวม', baht(todayRevenue),
                    AppColors.orange, theme)),
            const SizedBox(width: 14),
            Expanded(
                child: _kpi('จำนวนบิล', '${todaySales.length} บิล',
                    theme.colorScheme.onSurface, theme)),
            const SizedBox(width: 14),
            Expanded(
                child: _kpi(
                    'เฉลี่ย/บิล',
                    baht(todaySales.isEmpty
                        ? 0
                        : (todayRevenue / todaySales.length).round()),
                    theme.colorScheme.onSurface,
                    theme)),
          ]),
          const SizedBox(height: 24),
          _reportTitle('แบ่งตามวิธีชำระเงิน', theme),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: _payCard('💵 เงินสด · Cash', cashSales,
                    AppColors.orange, theme)),
            const SizedBox(width: 14),
            Expanded(
                child: _payCard('📱 โอน/QR', qrSales,
                    AppColors.steelBlue, theme)),
          ]),
          if (todaySales.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                    'ยังไม่มียอดขายวันนี้\nทำรายการที่หน้า ขายสินค้า เพื่อดูข้อมูล',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.secondary)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _monthly(ThemeData theme) {
    final vatDivisor = 1 + _taxRate / 100;
    final now = DateTime.now();
    final monthSales = _sales
        .where((s) => s.sale.date.year == now.year && s.sale.date.month == now.month)
        .toList();
    final monthRevenue =
        monthSales.fold<double>(0, (a, s) => a + s.sale.total);
    // Cost from current product cost keyed by partNo (SaleItemRow has no cost
    // column; the JS `i.cost ?? products.find(...).cost ?? 0` reduces to this).
    final costByPart = {for (final p in _products) p.partNo: p.cost};
    final monthCost = monthSales.fold<double>(0, (acc, s) {
      return acc +
          s.items.fold<double>(0, (a, i) {
            final unitCost = costByPart[i.partNo] ?? 0;
            return a + unitCost * i.qty;
          });
    });
    final monthProfit = (monthRevenue / vatDivisor) - monthCost;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _reportTitle('กำไรเดือนนี้', theme),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: _kpi('รายได้รวม', baht(monthRevenue),
                    theme.colorScheme.onSurface, theme)),
            const SizedBox(width: 14),
            Expanded(
                child: _kpi('ต้นทุนรวม', baht(monthCost),
                    AppColors.warning, theme)),
            const SizedBox(width: 14),
            Expanded(
                child: _kpi(
                    'กำไรสุทธิ',
                    baht(monthProfit.round()),
                    monthProfit >= 0
                        ? AppColors.successLight
                        : AppColors.error,
                    theme)),
          ]),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Margin % เดือนนี้',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: theme.colorScheme.secondary)),
                if (monthRevenue > 0) ...[
                  Text(
                      '${((monthProfit / (monthRevenue / vatDivisor)) * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                          fontSize: 48,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          color: monthProfit >= 0
                              ? AppColors.successLight
                              : AppColors.error)),
                  const SizedBox(height: 4),
                  Text('จาก ${monthSales.length} บิล',
                      style: TextStyle(color: theme.colorScheme.secondary)),
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text('ยังไม่มีข้อมูลเดือนนี้',
                        style:
                            TextStyle(color: theme.colorScheme.secondary)),
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
                  style: TextStyle(color: theme.colorScheme.secondary)),
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
              return DataRow(cells: [
                DataCell(Text(_movDate(m.date),
                    style: const TextStyle(fontSize: 13))),
                DataCell(Text(m.name,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
                DataCell(Text(m.partNo,
                    style: const TextStyle(
                        color: AppColors.orange, fontSize: 12))),
                DataCell(Text(m.type,
                    style: TextStyle(
                        color: typeColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12))),
                DataCell(Text('${m.delta > 0 ? '+' : ''}${m.delta}',
                    style: TextStyle(
                        color: m.delta > 0
                            ? AppColors.successLight
                            : AppColors.error,
                        fontWeight: FontWeight.w800))),
                DataCell(Text('${m.stockAfter}')),
                DataCell(Text(m.note ?? '—',
                    style: TextStyle(color: theme.colorScheme.secondary))),
              ]);
            }).toList(),
          ),
        ),
      ],
    );
  }

  String _movDate(DateTime d) {
    const months = [
      'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
      'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day} $hh:$mm';
  }

  Widget _ranking(ThemeData theme) {
    final soldMap = <String, _SoldAgg>{};
    for (final s in _sales) {
      for (final i in s.items) {
        final key = i.partNo ?? i.productId;
        final agg = soldMap.putIfAbsent(key, () => _SoldAgg(i.name));
        agg.qty += i.qty;
        agg.revenue += i.qty * i.price;
      }
    }
    final sorted = soldMap.entries.toList()
      ..sort((a, b) => b.value.qty.compareTo(a.value.qty));
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
            child: _rankList(theme, '🏆 สินค้าขายดี · Best Sellers', best,
                best: true),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: _rankList(
                theme, '📉 สินค้าขายช้า · Slow Movers', worst,
                best: false),
          ),
        ],
      ),
    );
  }

  Widget _rankList(ThemeData theme, String title,
      List<MapEntry<String, _SoldAgg>> rows,
      {required bool best}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _reportTitle(title, theme),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('ยังไม่มีข้อมูลการขาย',
                style: TextStyle(color: theme.colorScheme.secondary)),
          ),
        ...rows.asMap().entries.map((e) {
          final i = e.key;
          final partNo = e.value.key;
          final d = e.value.value;
          return Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text('#${i + 1}',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: best
                              ? AppColors.orange
                              : theme.colorScheme.secondary)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                      Text(partNo,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.orange)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: best
                      ? [
                          Text(baht(d.revenue),
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.successLight)),
                          Text('${d.qty} ชิ้น',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.secondary)),
                        ]
                      : [
                          Text('${d.qty} ชิ้น',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800)),
                          Text(baht(d.revenue),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.secondary)),
                        ],
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _reportTitle(String t, ThemeData theme) => Text(t,
      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800));

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
          Text(value,
              style: TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w800, color: color)),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.secondary)),
        ],
      ),
    );
  }

  Widget _payCard(String label, List<SaleWithItems> arr, Color color,
      ThemeData theme) {
    final sum = arr.fold<double>(0, (a, s) => a + s.sale.total);
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
          Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.secondary)),
          const SizedBox(height: 6),
          Text(baht(sum),
              style: TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w800, color: color)),
          Text('${arr.length} บิล',
              style: TextStyle(
                  fontSize: 13, color: theme.colorScheme.secondary)),
        ],
      ),
    );
  }
}
