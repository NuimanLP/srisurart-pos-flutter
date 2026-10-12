// products_suppliers_tab.part.dart — the Products screen's Suppliers tab
// (supplier-first "ตามซัพฯ" + the per-product "ตามสินค้า" view) and its
// dialogs. A `part` of products_screen.dart, which still owns it (CONTRACT §5);
// split out only to keep that file's size in check.

part of 'products_screen.dart';

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

  // Supplier-first view (owner 2026-10-12, the default). [_groups] is rebuilt
  // only when the data changes (_load / _refreshSuppliers), never in build.
  bool _bySupplier = true;
  List<SupplierGroup> _groups = [];
  String _query = '';
  final _search = TextEditingController();
  // Master/detail: the selected supplier. Narrow: the supplier pushed over
  // the list (null = the list shows; Back clears it).
  String? _selKey;
  String? _openKey;

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
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final productsRepo = context.read<ProductsRepository>();
    final suppliersRepo = context.read<SuppliersRepository>();
    // Started together: each may wait on the network (API build).
    final productsF = productsRepo.getAll();
    final suppliersF = suppliersRepo.getSuppliers();
    final products = await productsF;
    final suppliers = await suppliersF;
    if (!mounted) return;
    setState(() {
      _products = products;
      _suppliers = suppliers;
      _groups = groupSuppliers(products, suppliers);
      _selKey ??= _groups.firstOrNull?.key;
      if (_selectedId.isEmpty && products.isNotEmpty) {
        _selectedId = products.first.id;
      }
      _loading = false;
    });
  }

  Future<void> _refreshSuppliers() async {
    final suppliers = await context.read<SuppliersRepository>().getSuppliers();
    if (!mounted) return;
    setState(() {
      _suppliers = suppliers;
      _groups = groupSuppliers(_products, suppliers);
    });
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
      builder: (context, status, isDegraded) => _bySupplier
          ? _bySupplierView(context, isDegraded)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _modeBar(context),
                Expanded(child: _byProductView(context, isDegraded)),
              ],
            ),
    );
  }

  /// "ตามสินค้า": the per-product view as it was before 2026-10-12 (unchanged).
  Widget _byProductView(BuildContext context, bool isDegraded) {
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

        // Phone: the product picker sits above the detail (a fixed 260 px
        // side list left the detail ~130 px wide at 390 px).
        return LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < AppBreakpoints.compact;
            final listTitle = Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'เลือกสินค้า',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
            );
            return Flex(
          direction: narrow ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // product list
            Container(
          width: narrow ? null : 260,
          // At least 120 px (or half a very short screen, e.g. 3x zoom);
          // on a phone the title scrolls with the list so nothing is fixed.
          height: narrow
              ? math.max(math.min(120.0, box.maxHeight / 2), box.maxHeight * 0.38)
              : null,
          color: theme.colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!narrow) listTitle,
              Expanded(
                child: ListView.builder(
                  key: const Key('suppliers-product-list'),
                  itemCount: _products.length + (narrow ? 1 : 0),
                  itemBuilder: (ctx, i) {
                    if (narrow && i == 0) return listTitle;
                    final p = _products[narrow ? i - 1 : i];
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
        narrow
            ? const Divider(height: 1)
            : const VerticalDivider(width: 1),
        // detail
        Expanded(
          child: selected == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'เลือกสินค้าเพื่อดูและเพิ่มซัพพลายเออร์', // owner-ratified 2026-10-12
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.secondary),
                    ),
                  ),
                )
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

  // ── Supplier-first view ("ตามซัพฯ", owner 2026-10-12) ──────────────────────
  // Master/detail needs this much tab width; below it the list pushes to the
  // detail (3x zoom on a 1920 screen is 640 logical px — too tight for both).
  static const double _splitMin = 840;

  Widget _modeBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<bool>(
          key: const Key('suppliers-mode'),
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: AppColors.navy,
            selectedForegroundColor: AppColors.white,
            visualDensity: VisualDensity.compact,
          ),
          segments: const [
            ButtonSegment(value: true, label: Text('ตามซัพฯ')), // agent ร่าง
            ButtonSegment(value: false, label: Text('ตามสินค้า')), // agent ร่าง
          ],
          selected: {_bySupplier},
          onSelectionChanged: (v) => setState(() => _bySupplier = v.first),
        ),
      ),
    );
  }

  void _select(SupplierGroup g) => setState(() {
    _selKey = g.key;
    _openKey = g.key;
  });

  /// Tap a product: compare every supplier's price for it ("ตามสินค้า").
  void _compare(ProductRow p) => setState(() {
    _bySupplier = false;
    _selectedId = p.id;
    _adding = false;
  });

  void _createPo(SupplierGroup g) {
    if (context.isDegraded) {
      _showSupplierDegradedWarning();
      return;
    }
    context.go(AppRoutes.purchaseOrders, extra: PoPrefill(supplier: g.name));
  }

  Future<void> _openAdd(SupplierGroup? g) async {
    if (context.isDegraded) {
      _showSupplierDegradedWarning();
      return;
    }
    final key = await showDialog<String>(
      context: context,
      builder: (_) => _AddQuoteDialog(
        products: _products,
        supplierName: g?.name,
        quoted: {for (final x in _groups) x.key: x.productIds},
      ),
    );
    if (key == null || !mounted) return;
    await _refreshSuppliers();
    if (!mounted) return;
    setState(() {
      _selKey = key;
      _openKey = key;
      _query = '';
      _search.clear();
    });
  }

  Future<void> _openEdit(SupplierGroup g, SupplierQuote q) async {
    if (context.isDegraded) {
      _showSupplierDegradedWarning();
      return;
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _EditQuoteDialog(supplierName: g.name, quote: q),
    );
    if (saved == true && mounted) await _refreshSuppliers();
  }

  Widget _bySupplierView(BuildContext context, bool isDegraded) {
    return LayoutBuilder(
      builder: (context, box) {
        final visible = _groups.where((g) => g.matches(_query)).toList();
        if (box.maxWidth >= _splitMin) {
          final sel = visible.where((g) => g.key == _selKey).firstOrNull;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _modeBar(context),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 300,
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
                        child: ListView(
                          key: const Key('suppliers-group-list'),
                          children: [
                            _listHeader(context, isDegraded),
                            if (_groups.isNotEmpty)
                              ..._listBody(context, visible, isDegraded),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _groups.isEmpty
                          ? Center(child: _emptyAll(context, isDegraded))
                          : sel == null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  // agent ร่าง
                                  'เลือกซัพพลายเออร์ทางซ้ายเพื่อดูสินค้าและราคา',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.secondary,
                                  ),
                                ),
                              ),
                            )
                          : ListView(
                              key: const Key('supplier-detail'),
                              padding: const EdgeInsets.all(24),
                              children: _detail(context, sel, isDegraded),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        // Narrow: list → detail push; Back (button or system) returns.
        final open = _groups.where((g) => g.key == _openKey).firstOrNull;
        return PopScope(
          canPop: open == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _openKey != null) setState(() => _openKey = null);
          },
          child: open == null
              ? ListView(
                  key: const Key('suppliers-group-list'),
                  children: [
                    _modeBar(context),
                    _listHeader(context, isDegraded),
                    ..._listBody(context, visible, isDegraded),
                  ],
                )
              : ListView(
                  key: const Key('supplier-detail'),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    Row(
                      children: [
                        IconButton(
                          key: const Key('supplier-back'),
                          tooltip: 'กลับ', // agent ร่าง
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => setState(() => _openKey = null),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            open.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    ..._detail(context, open, isDegraded, showName: false),
                  ],
                ),
        );
      },
    );
  }

  Widget _listHeader(BuildContext context, bool isDegraded) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('suppliers-search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'ค้นหาซัพฯ หรือสินค้า', // agent ร่าง
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onChanged: (v) => setState(() => _query = v),
            // Enter opens the first match (of the text as submitted).
            onSubmitted: (q) {
              final first = _groups.where((g) => g.matches(q)).firstOrNull;
              if (first != null) _select(first);
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('supplier-new'),
              style: TextButton.styleFrom(foregroundColor: AppColors.orange),
              onPressed: isDegraded ? null : () => _openAdd(null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('ซัพพลายเออร์ใหม่'), // agent ร่าง
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _listBody(
    BuildContext context,
    List<SupplierGroup> visible,
    bool isDegraded,
  ) {
    final theme = Theme.of(context);
    if (_groups.isEmpty) return [_emptyAll(context, isDegraded)];
    if (visible.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                'ไม่พบซัพฯ หรือสินค้าที่ตรงกับ "${_query.trim()}"', // agent ร่าง
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.secondary),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _query = '';
                  _search.clear();
                }),
                child: const Text('ล้างคำค้น'), // agent ร่าง
              ),
            ],
          ),
        ),
      ];
    }
    return [
      for (final g in visible)
        InkWell(
          key: ValueKey('supplier-${g.key}'),
          onTap: () => _select(g),
          child: Container(
            decoration: BoxDecoration(
              color: g.key == _selKey
                  ? theme.colorScheme.surfaceContainerHighest
                  : null,
              border: Border(
                left: BorderSide(
                  color: g.key == _selKey
                      ? AppColors.orange
                      : Colors.transparent,
                  width: 3,
                ),
                bottom: BorderSide(color: theme.dividerColor),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '${g.productCount} สินค้า', // agent ร่าง
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (g.reorderCount > 0) ...[
                  const SizedBox(width: 8),
                  StatusChip(
                    'ต้องสั่ง ${g.reorderCount}', // agent ร่าง
                    tone: StatusTone.warning,
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  Widget _emptyAll(BuildContext context, bool isDegraded) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_shipping_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(height: 8),
          Text(
            'ยังไม่มีซัพพลายเออร์', // agent ร่าง
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            onPressed: isDegraded ? null : () => _openAdd(null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('เพิ่มซัพพลายเออร์แรก'), // agent ร่าง
          ),
        ],
      ),
    );
  }

  List<Widget> _detail(
    BuildContext context,
    SupplierGroup g,
    bool isDegraded, {
    bool showName = true,
  }) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.secondary, fontSize: 14);
    final quoteCount = g.quotes.length;
    return [
      if (showName)
        Text(
          g.name,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          Text(
            quoteCount == g.productCount
                ? '${g.productCount} สินค้า'
                : '${g.productCount} สินค้า ($quoteCount ราคา)', // agent ร่าง
            style: muted,
          ),
          if (g.cheapestCount > 0)
            Text('ถูกสุด ${g.cheapestCount} รายการ', style: muted), // agent ร่าง
          if (g.reorderCount > 0)
            Text(
              'ต้องสั่ง ${g.reorderCount}', // agent ร่าง
              style: const TextStyle(
                color: AppColors.orange,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const Key('supplier-create-po'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            onPressed: isDegraded ? null : () => _createPo(g),
            icon: const Icon(Icons.receipt_long, size: 18),
            label: Text(
              g.reorderCount > 0
                  ? 'สร้างใบสั่งซื้อ (${g.reorderCount})'
                  : 'สร้างใบสั่งซื้อ',
            ),
          ),
          OutlinedButton.icon(
            key: const Key('supplier-add-product'),
            onPressed: isDegraded ? null : () => _openAdd(g),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('เพิ่มสินค้า'), // agent ร่าง
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text.rich(
        TextSpan(
          children: [
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _CheapestPill(),
            ),
            TextSpan(
              // agent ร่าง
              text: '  = ราคารวม (ทุน + ค่าส่ง) ต่ำที่สุดในบรรดาซัพฯ ของสินค้านั้น',
              style: TextStyle(color: theme.colorScheme.secondary),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 13),
      ),
      const SizedBox(height: 10),
      LayoutBuilder(
        builder: (context, c) => c.maxWidth >= 640
            ? _quoteTable(context, g, isDegraded)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final q in g.quotes)
                    _quoteCard(context, g, q, isDegraded),
                ],
              ),
      ),
    ];
  }

  Widget? _levelChip(SupplierQuote q) => switch (q.level) {
    StockLevel.out => const StatusChip('หมด', tone: StatusTone.danger),
    StockLevel.low => const StatusChip(
      'ใกล้หมด', // agent ร่าง
      tone: StatusTone.warning,
    ),
    StockLevel.ok => null,
  };

  Color? _levelTint(SupplierQuote q) => switch (q.level) {
    StockLevel.out => AppColors.error.withValues(alpha: 0.06),
    StockLevel.low => AppColors.warning.withValues(alpha: 0.08),
    StockLevel.ok => null,
  };

  Widget _productCell(SupplierQuote q) {
    return Tooltip(
      message: 'ดูทุกซัพฯ ของสินค้านี้', // agent ร่าง
      child: InkWell(
        onTap: () => _compare(q.product),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                q.product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                q.product.partNo,
                style: const TextStyle(fontSize: 12, color: AppColors.orange),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Total + what it means: the cheapest pill, or how much dearer.
  Widget _totalCell(BuildContext context, SupplierQuote q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          baht(q.total),
          style: TextStyle(
            fontWeight: q.cheapest ? FontWeight.w900 : FontWeight.w700,
            fontSize: 16,
            color: q.cheapest ? AppColors.successLight : null,
          ),
        ),
        if (q.cheapest)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: _CheapestPill(),
          )
        else if (q.quotesForProduct > 1)
          Text(
            // agent ร่าง
            'แพงกว่า ${baht(q.overBaht)} · ถูกสุด ${q.bestName}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
      ],
    );
  }

  Widget _quoteActions(SupplierGroup g, SupplierQuote q, bool isDegraded) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'แก้ราคา', // agent ร่าง
          icon: const Icon(Icons.edit_outlined, size: 20),
          color: AppColors.navy,
          onPressed: isDegraded ? null : () => _openEdit(g, q),
        ),
        IconButton(
          tooltip: 'ลบ',
          icon: const Icon(Icons.delete_outline, size: 20),
          color: AppColors.error,
          onPressed: isDegraded ? null : () => _delete(q.row.id),
        ),
      ],
    );
  }

  Widget _quoteTable(BuildContext context, SupplierGroup g, bool isDegraded) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: c.maxWidth),
            child: DataTable(
              key: const Key('supplier-quote-table'),
              dataRowMinHeight: 64,
              dataRowMaxHeight: double.infinity,
              horizontalMargin: 16,
              columnSpacing: 24,
              headingTextStyle: TextStyle(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
                fontSize: 14,
              ),
              columns: const [
                DataColumn(label: Text('สินค้า')),
                DataColumn(label: Text('สต็อก')),
                DataColumn(label: Text('ทุน/ชิ้น'), numeric: true),
                DataColumn(label: Text('ค่าส่ง'), numeric: true),
                DataColumn(label: Text('รวม')),
                DataColumn(label: Text('จัดการ')),
              ],
              rows: [
                for (final q in g.quotes)
                  DataRow(
                    color: WidgetStatePropertyAll(_levelTint(q)),
                    cells: [
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: _productCell(q),
                        ),
                      ),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${q.product.stock}/${q.product.minStock}'),
                            if (_levelChip(q) case final chip?) ...[
                              const SizedBox(width: 8),
                              chip,
                            ],
                          ],
                        ),
                      ),
                      DataCell(Text(baht(q.row.unitCost))),
                      DataCell(Text(baht(q.row.freight))),
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: _totalCell(context, q),
                        ),
                      ),
                      DataCell(_quoteActions(g, q, isDegraded)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quoteCard(
    BuildContext context,
    SupplierGroup g,
    SupplierQuote q,
    bool isDegraded,
  ) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.secondary, fontSize: 13);
    final stripe = switch (q.level) {
      StockLevel.out => AppColors.error,
      StockLevel.low => AppColors.warning,
      StockLevel.ok => theme.dividerColor.withValues(alpha: 0.4),
    };
    final edge = BorderSide(color: theme.dividerColor.withValues(alpha: 0.3));
    // Rounded by the clip: a border with a radius must be one colour, and the
    // left edge carries the stock level.
    return Padding(
      key: ValueKey('supplier-quote-${q.row.id}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: _levelTint(q) ?? theme.colorScheme.surface,
            border: Border(
              left: BorderSide(color: stripe, width: 4),
              top: edge,
              right: edge,
              bottom: edge,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _productCell(q)),
                  if (_levelChip(q) case final chip?)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: chip,
                    ),
                ],
              ),
              Wrap(
                spacing: 14,
                runSpacing: 2,
                children: [
                  Text(
                    'สต็อก ${q.product.stock}/${q.product.minStock}',
                    style: muted,
                  ),
                  Text('ทุน/ชิ้น ${baht(q.row.unitCost)}', style: muted),
                  Text('ค่าส่ง ${baht(q.row.freight)}', style: muted),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: _totalCell(context, q)),
                  _quoteActions(g, q, isDegraded),
                ],
              ),
            ],
          ),
        ),
      ),
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
              Flexible(
                child: Text(
                  'เพิ่มซัพพลายเออร์ใหม่',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.orange,
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

/// The green "cheapest total for this product" pill (same words as the
/// per-product table's badge).
class _CheapestPill extends StatelessWidget {
  const _CheapestPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
    );
  }
}

/// "12" for a whole baht amount, "12.5" otherwise — a prefilled money field.
String _moneyText(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// A money field: empty = 0 when [emptyIsZero]; null = not a valid amount.
double? _parseMoney(String text, {bool emptyIsZero = false}) {
  final t = text.trim();
  if (t.isEmpty) return emptyIsZero ? 0 : null;
  final v = double.tryParse(t);
  return v == null || v < 0 || v.isNaN || v.isInfinite ? null : v;
}

Widget _dialogField(
  BuildContext context,
  String label,
  TextEditingController ctrl, {
  Key? key,
  bool numeric = false,
  String? hint,
  String? helper,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
}) {
  return TextField(
    key: key,
    controller: ctrl,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : null,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint ?? (numeric ? '0' : null),
      helperText: helper,
      helperMaxLines: 2,
      isDense: true,
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.orange, width: 2),
      ),
    ),
  );
}

Widget _dialogError(String? error) => error == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          error,
          style: const TextStyle(
            color: AppColors.error,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

const _supplierOfflineText =
    'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการเกี่ยวกับซัพพลายเออร์ได้';

/// Edit one quote's cost and freight. Online-only: the dialog stays open with
/// the same values on any failure; the cache changes only from the server's
/// reply (ApiSuppliersRepository.updateSupplier).
class _EditQuoteDialog extends StatefulWidget {
  const _EditQuoteDialog({required this.supplierName, required this.quote});

  final String supplierName;
  final SupplierQuote quote;

  @override
  State<_EditQuoteDialog> createState() => _EditQuoteDialogState();
}

class _EditQuoteDialogState extends State<_EditQuoteDialog> {
  late final _cost = TextEditingController(
    text: _moneyText(widget.quote.row.unitCost),
  );
  late final _freight = TextEditingController(
    text: _moneyText(widget.quote.row.freight),
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _cost.dispose();
    _freight.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final cost = _parseMoney(_cost.text);
    final freight = _parseMoney(_freight.text, emptyIsZero: true);
    if (cost == null || freight == null) return;
    if (context.isDegraded) {
      setState(() => _error = _supplierOfflineText);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Both as absolute values: a repeat after an unknown outcome is harmless.
      await context.read<SuppliersRepository>().updateSupplier(
        widget.quote.row.id,
        unitCost: Value(cost),
        freight: Value(freight),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ServerErrorResolver.resolveCounterError(e);
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        _parseMoney(_cost.text) != null &&
        _parseMoney(_freight.text, emptyIsZero: true) != null;
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) => AlertDialog(
        title: const Text('แก้ไขราคา'), // agent ร่าง
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${widget.supplierName} — ${widget.quote.product.name}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  widget.quote.product.partNo,
                  style: const TextStyle(fontSize: 12, color: AppColors.orange),
                ),
                const SizedBox(height: 16),
                _dialogField(
                  context,
                  'ราคาต่อชิ้น ฿',
                  _cost,
                  key: const Key('edit-quote-cost'),
                  numeric: true,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                _dialogField(
                  context,
                  'ค่าส่ง ฿',
                  _freight,
                  key: const Key('edit-quote-freight'),
                  numeric: true,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
                _dialogError(_error),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            key: const Key('edit-quote-save'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            onPressed: _busy || !valid || isDegraded ? null : _save,
            child: const Text('บันทึก'),
          ),
        ],
      ),
    );
  }
}

/// Add a product to a supplier ([supplierName] set), or start a new supplier
/// with its first product (null). Pops the supplier's [supplierKey] on success.
///
/// A failure keeps every field as typed, so pressing บันทึก again sends the
/// same body and ApiSuppliersRepository's PendingWrites replays the first
/// attempt instead of creating the quote twice.
class _AddQuoteDialog extends StatefulWidget {
  const _AddQuoteDialog({
    required this.products,
    required this.supplierName,
    required this.quoted,
  });

  final List<ProductRow> products;
  final String? supplierName;

  /// supplierKey → products that supplier already quotes (left out of the pick).
  final Map<String, Set<String>> quoted;

  @override
  State<_AddQuoteDialog> createState() => _AddQuoteDialogState();
}

class _AddQuoteDialogState extends State<_AddQuoteDialog> {
  final _name = TextEditingController();
  final _find = TextEditingController();
  final _cost = TextEditingController();
  final _freight = TextEditingController();
  ProductRow? _picked;
  bool _costTyped = false;
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.supplierName == null;

  String get _supplier => (_isNew ? _name.text : widget.supplierName!).trim();

  Set<String> get _already => widget.quoted[supplierKey(_supplier)] ?? const {};

  List<ProductRow> get _matches {
    final q = _find.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final already = _already;
    return widget.products
        .where(
          (p) =>
              !already.contains(p.id) &&
              (p.name.toLowerCase().contains(q) ||
                  p.nameTH.toLowerCase().contains(q) ||
                  p.partNo.toLowerCase().contains(q)),
        )
        .take(5)
        .toList();
  }

  @override
  void dispose() {
    _name.dispose();
    _find.dispose();
    _cost.dispose();
    _freight.dispose();
    super.dispose();
  }

  void _pick(ProductRow p) => setState(() {
    _picked = p;
    if (!_costTyped) _cost.text = _moneyText(p.cost);
  });

  bool get _duplicate => _picked != null && _already.contains(_picked!.id);

  bool get _valid =>
      _supplier.isNotEmpty &&
      _picked != null &&
      !_duplicate &&
      _parseMoney(_cost.text) != null &&
      _parseMoney(_freight.text, emptyIsZero: true) != null;

  Future<void> _save() async {
    if (_busy || !_valid) return;
    if (context.isDegraded) {
      setState(() => _error = _supplierOfflineText);
      return;
    }
    final name = _supplier;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<SuppliersRepository>().addSupplier(
        productId: _picked!.id,
        name: name,
        unitCost: _parseMoney(_cost.text)!,
        freight: _parseMoney(_freight.text, emptyIsZero: true)!,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ServerErrorResolver.resolveCounterError(e);
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(supplierKey(name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _matches;
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) => AlertDialog(
        title: Text(
          _isNew
              ? 'ซัพพลายเออร์ใหม่' // agent ร่าง
              : 'เพิ่มสินค้า — ${widget.supplierName}', // agent ร่าง
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isNew) ...[
                  _dialogField(
                    context,
                    'ชื่อซัพพลายเออร์',
                    _name,
                    key: const Key('add-quote-name'),
                    // agent ร่าง
                    helper: 'ซัพพลายเออร์ต้องมีสินค้าอย่างน้อย 1 รายการ',
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_picked == null) ...[
                  _dialogField(
                    context,
                    'เลือกสินค้า',
                    _find,
                    key: const Key('add-quote-find'),
                    hint: 'ค้นหาด้วยชื่อหรือรหัสสินค้า…',
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      final fresh = _matches;
                      if (fresh.isNotEmpty) _pick(fresh.first);
                    },
                  ),
                  for (final p in matches)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        p.partNo,
                        style: const TextStyle(color: AppColors.orange),
                      ),
                      trailing: Text(baht(p.cost)),
                      onTap: () => _pick(p),
                    ),
                  if (_find.text.trim().isNotEmpty && matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'ไม่พบสินค้า',
                        style: TextStyle(color: theme.colorScheme.secondary),
                      ),
                    ),
                ] else
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _picked!.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _picked!.partNo,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.orange,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'เปลี่ยนสินค้า', // agent ร่าง
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: _busy
                              ? null
                              : () => setState(() => _picked = null),
                        ),
                      ],
                    ),
                  ),
                if (_duplicate)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      // agent ร่าง
                      'ซัพฯ นี้มีราคาสินค้านี้แล้ว — แก้ราคาในรายการแทน',
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                const SizedBox(height: 12),
                _dialogField(
                  context,
                  'ราคาต่อชิ้น ฿',
                  _cost,
                  key: const Key('add-quote-cost'),
                  numeric: true,
                  onChanged: (_) => setState(() => _costTyped = true),
                ),
                const SizedBox(height: 12),
                _dialogField(
                  context,
                  'ค่าส่ง ฿',
                  _freight,
                  key: const Key('add-quote-freight'),
                  numeric: true,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
                _dialogError(_error),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            key: const Key('add-quote-save'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            onPressed: _busy || !_valid || isDegraded ? null : _save,
            child: const Text('บันทึก'),
          ),
        ],
      ),
    );
  }
}
