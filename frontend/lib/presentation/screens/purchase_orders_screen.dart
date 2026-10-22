// PurchaseOrdersScreen — สั่งซื้อ: PO list (open/received/cancelled), create PO
// (supplier + line items partNo/name/qty/cost), receive PO (weighted-avg cost in
// the repo; surfaces unmatched partNos), cancel/delete PO.
//
// Ported for behaviour parity from pos/PurchaseOrdersScreen.jsx. Thai UI strings
// are copied verbatim. Data flows ONLY through purchaseOrdersRepoProvider /
// productsRepoProvider; money via baht()/MoneyText; confirms via showConfirm.
//
// NOTE on status keys: the JS layer used 'pending' for a new PO. The Drift
// PurchaseOrdersRepository.savePO now stamps status 'open' (CONTRACT §3), so the
// "awaiting receive" status is 'open' here. The Thai labels match the JS intent:
//   open → รอรับสินค้า, received → รับแล้ว, cancelled → ยกเลิก.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors/pos_exception.dart';
import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../core/utils/supplier_name.dart';
import '../../data/db/database.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/purchase_orders_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/suppliers_repository.dart';
import '../../domain/models/aggregates.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import '../widgets/barcode_scan_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/low_stock_alert.dart' show StockLevel, stockLevel;
import '../widgets/money_text.dart';
import '../widgets/purchase_order_a4.dart';
import '../widgets/status_chip.dart';
import '../widgets/sync_status_builder.dart';
import '../widgets/thai_format.dart';

/// Opens the create-PO dialog once, with [supplier] picked and its low-stock
/// products already added (from the Suppliers tab's "สร้างใบสั่งซื้อ").
/// Nothing is saved until บันทึก.
///
/// Passed as a go_router `extra`. A class, not a String/Map, on purpose:
/// go_router drops a non-JSON extra from the browser history, so a refresh or
/// back never opens the dialog a second time.
class PoPrefill {
  const PoPrefill({required this.supplier});
  final String supplier;
}

class PurchaseOrdersScreen extends StatefulWidget {
  const PurchaseOrdersScreen({super.key, this.prefill});

  final PoPrefill? prefill;

  @override
  State<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends State<PurchaseOrdersScreen> {
  // Created in initState/_refresh — never inline in build.
  late Future<List<PurchaseOrderWithItems>> _posFuture;
  // Products for the add-item search in the create modal; re-loaded on
  // _refresh too, so a receive's cost update is reflected next time the
  // create dialog opens.
  late Future<List<ProductRow>> _productsFuture;
  // True while _openCreate loads; blocks a double tap opening two dialogs.
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
    final prefill = widget.prefill;
    if (prefill != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCreate(prefill: prefill);
      });
    }
  }

  void _load() {
    _posFuture = context.read<PurchaseOrdersRepository>().getPOs();
    _productsFuture = context.read<ProductsRepository>().getAll();
  }

  void _refresh() => setState(_load);

  Future<void> _openCreate({PoPrefill? prefill}) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    if (_opening) return;
    final supplierRepo = context.read<SuppliersRepository>();
    setState(() => _opening = true);
    final List<ProductRow> products;
    // Per-product supplier quotes, read fresh for each dialog: the supplier
    // suggestions and the picked supplier's products/unit costs.
    final List<SupplierRow> suppliers;
    final List<PurchaseOrderWithItems> pos;
    try {
      products = await _productsFuture;
      suppliers = await supplierRepo.getSuppliers();
      pos = await _posFuture;
    } catch (e) {
      _showError(e);
      return;
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CreatePoDialog(
        products: products,
        suppliers: suppliers,
        // getPOs is newest first, so recently used suppliers lead the list.
        knownSuppliers: _knownSupplierNames(
          pos.map((p) => p.po.supplier),
          suppliers.map((s) => s.name),
        ),
        initialSupplier: prefill?.supplier,
      ),
    );
    if (saved == true) _refresh();
  }

  Future<void> _receive(PurchaseOrderRow po) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(
      context,
      'รับสินค้าเข้าสต็อก',
      'ยืนยันรับสินค้าเข้าสต็อก?\n(ต้นทุนสินค้าจะถูกอัปเดตตามราคาในใบสั่งซื้อ)',
    );
    if (!ok) return;
    final List<String> unmatched;
    try {
      unmatched = await repo.receivePO(po.id);
    } catch (e) {
      _showError(e);
      return;
    }
    _refresh();
    if (!mounted) return;
    if (unmatched.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('รับสินค้าแล้ว'),
          content: Text(
            '⚠ รับสินค้าแล้ว แต่ไม่พบรหัสสินค้าต่อไปนี้ในระบบ (สต็อกไม่ถูกอัปเดต):\n'
            '${unmatched.join('\n')}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('ตกลง'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _cancel(PurchaseOrderRow po) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(
      context,
      'ยกเลิกใบสั่งซื้อ',
      'ยกเลิกใบสั่งซื้อ ${po.poNo}?\n(สถานะจะเปลี่ยนเป็น "ยกเลิก" — ไม่ลบข้อมูล)',
      danger: true,
    );
    if (!ok) return;
    try {
      await repo.cancelPO(po.id);
    } catch (e) {
      _showError(e);
      return;
    }
    _refresh();
  }

  Future<void> _delete(PurchaseOrderRow po) async {
    if (context.isDegraded) {
      _showDegradedWarning();
      return;
    }
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(
      context,
      'ลบใบสั่งซื้อ',
      'ลบใบสั่งซื้อ ${po.poNo} ออกจากระบบถาวร?\nการลบจะไม่สามารถกู้คืนได้',
      danger: true,
    );
    if (!ok) return;
    try {
      await repo.deletePO(po.id);
    } catch (e) {
      _showError(e);
      return;
    }
    _refresh();
  }

  /// A4 PO preview with the print/share bar (owner request 2026-10-22).
  /// Reads only local rows, so it works while Degraded too.
  Future<void> _print(PurchaseOrderWithItems data) async {
    final SettingsRowData settings;
    try {
      settings = await context.read<SettingsRepository>().getSettings();
    } catch (e) {
      _showError(e);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(data.po.poNo)),
          body: PurchaseOrderA4View(data: data, settings: settings),
        ),
      ),
    );
  }

  /// A refused write reaches the counter as its Thai message (repositories
  /// already convert ApiException → PosException / plain Exception).
  void _showError(Object e) {
    if (!mounted) return;
    final msg = e is PosException
        ? e.message
        : '$e'.replaceFirst('Exception: ', '');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showDegradedWarning() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถดำเนินการใบสั่งซื้อได้'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SyncStatusBuilder(
        builder: (context, status, isDegraded) {
          return FutureBuilder<List<PurchaseOrderWithItems>>(
            future: _posFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const LoadingView();
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline,
                  message: 'เกิดข้อผิดพลาด',
                  hint: '${snap.error}',
                );
              }
              return _PoListView(
                pos: snap.data!,
                onCreate: _openCreate,
                opening: _opening,
                onReceive: _receive,
                onCancel: _cancel,
                onDelete: _delete,
                onPrint: _print,
                isDegraded: isDegraded,
              );
            },
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status helpers (parity with the JS statusTH / statusColor maps).
// ─────────────────────────────────────────────────────────────────────────────

/// PO status → shared [StatusChip]. Labels stay verbatim from the JS statusTH
/// map ('open' → รอรับสินค้า, NOT the generic StatusChip.of 'เปิดอยู่').
StatusChip _poStatusChip(String status) {
  switch (status) {
    case 'open':
      return const StatusChip('รอรับสินค้า', tone: StatusTone.warning);
    case 'received':
      return const StatusChip('รับแล้ว', tone: StatusTone.success);
    case 'cancelled':
      return const StatusChip('ยกเลิก', tone: StatusTone.danger);
    default:
      return StatusChip(status);
  }
}

double _poTotal(PurchaseOrderWithItems p) =>
    p.items.fold<double>(0, (s, i) => s + i.qty * i.cost);

// ─────────────────────────────────────────────────────────────────────────────
// PO list view (top stat bar + table).
// ─────────────────────────────────────────────────────────────────────────────

class _PoListView extends StatelessWidget {
  final List<PurchaseOrderWithItems> pos;
  final VoidCallback onCreate;
  final bool opening;
  final ValueChanged<PurchaseOrderRow> onReceive;
  final ValueChanged<PurchaseOrderRow> onCancel;
  final ValueChanged<PurchaseOrderRow> onDelete;
  final ValueChanged<PurchaseOrderWithItems> onPrint;
  final bool isDegraded;

  const _PoListView({
    required this.pos,
    required this.onCreate,
    this.opening = false,
    required this.onReceive,
    required this.onCancel,
    required this.onDelete,
    required this.onPrint,
    this.isDegraded = false,
  });

  @override
  Widget build(BuildContext context) {
    final pendingCount = pos.where((p) => p.po.status == 'open').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top stat bar.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: _Stat(
                        value: '${pos.length}',
                        label: 'ใบสั่งซื้อทั้งหมด',
                      ),
                    ),
                    const SizedBox(width: 28),
                    Flexible(
                      child: _Stat(
                        value: '$pendingCount',
                        label: 'รอรับสินค้า',
                        color: AppColors.warning,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              AppButton(
                label: 'สร้างใบสั่งซื้อ',
                icon: Icons.add,
                busy: opening,
                onPressed: isDegraded ? null : onCreate,
              ),
            ],
          ),
        ),
        Expanded(
          child: pos.isEmpty
              ? const EmptyState(message: 'ยังไม่มีใบสั่งซื้อ')
              // Cap content width so cards don't stretch edge-to-edge on
              // iPad-landscape / desktop, leaving a stranded empty mid-band.
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: pos.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _PoCard(
                        // The item list's open state follows the PO, not
                        // its position in the list.
                        key: ValueKey(pos[i].po.id),
                        data: pos[i],
                        onReceive: () => onReceive(pos[i].po),
                        onCancel: () => onCancel(pos[i].po),
                        onDelete: () => onDelete(pos[i].po),
                        onPrint: () => onPrint(pos[i]),
                        isDegraded: isDegraded,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final Color? color;
  const _Stat({required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 30,
            height: 1,
            color: color ?? Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: AppColors.steelBlue),
        ),
      ],
    );
  }
}

class _PoCard extends StatelessWidget {
  final PurchaseOrderWithItems data;
  final VoidCallback onReceive;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onPrint;
  final bool isDegraded;

  const _PoCard({
    super.key,
    required this.data,
    required this.onReceive,
    required this.onCancel,
    required this.onDelete,
    required this.onPrint,
    this.isDegraded = false,
  });

  @override
  Widget build(BuildContext context) {
    final po = data.po;
    final theme = Theme.of(context);
    final border = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.08)
        : AppColors.gray200;
    // Status at a glance: a coloured left edge — waiting to receive stands out
    // in a long list, a cancelled PO recedes.
    final edge = switch (po.status) {
      'open' => AppColors.warning,
      'received' => AppColors.successLight,
      _ => AppColors.gray300,
    };
    return Container(
      decoration: BoxDecoration(
        color: edge,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.only(left: 5),
      // Material, not a decorated Container: the item list's ExpansionTile
      // paints its ink on the nearest Material.
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(8),
          ),
          side: BorderSide(color: border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          po.poNo,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.orange,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          po.supplier,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${data.items.length} รายการ · ${thaiDate(po.createdAt)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.steelBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      MoneyText(_poTotal(data), emphasis: true),
                      const SizedBox(height: 6),
                      _poStatusChip(po.status),
                    ],
                  ),
                ],
              ),
              if (data.items.isNotEmpty) _PoItemsList(items: data.items),
              const SizedBox(height: 12),
              // Actions row (mirrors the JS per-status button set).
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (po.status == 'open') ...[
                    AppButton(
                      label: 'รับสินค้า',
                      icon: Icons.check,
                      onPressed: isDegraded ? null : onReceive,
                    ),
                    AppButton.secondary(
                      label: 'ยกเลิก',
                      onPressed: isDegraded ? null : onCancel,
                    ),
                  ],
                  if (po.status == 'received')
                    Text(
                      'รับแล้ว ${po.receivedAt != null ? thaiDate(po.receivedAt!) : ''}',
                      style: const TextStyle(
                        color: AppColors.successLight,
                        fontSize: 12,
                      ),
                    ),
                  if (po.status == 'cancelled')
                    Text(
                      'ยกเลิก ${po.cancelledAt != null ? thaiDate(po.cancelledAt!) : ''}',
                      style: const TextStyle(
                        color: AppColors.steelBlue,
                        fontSize: 12,
                      ),
                    ),
                  // Every status prints; a local read, so not Degraded-gated.
                  // 'พิมพ์' is agent ร่าง (owner to ratify).
                  AppButton.secondary(
                    label: 'พิมพ์',
                    icon: Icons.print,
                    onPressed: onPrint,
                  ),
                  // The server refuses deleting a received PO (the receive
                  // movements point at it); open and cancelled may be deleted.
                  if (po.status != 'received')
                    IconButton(
                      tooltip: 'ลบถาวร',
                      onPressed: isDegraded ? null : onDelete,
                      icon: const Icon(Icons.delete_outline),
                      color: AppColors.error,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
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

/// What is on the PO, so whoever unpacks the delivery can check it against the
/// boxes before pressing รับสินค้า (which receives the whole PO). Collapsed by
/// default; the heading is owner-ratified 2026-10-12.
class _PoItemsList extends StatelessWidget {
  final List<PoItemRow> items;
  const _PoItemsList({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // No divider lines above/below the tile when it opens.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        dense: true,
        title: Text(
          'ดูรายการสินค้า',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.steelBlue,
          ),
        ),
        children: [
          for (final i in items)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(i.name, style: theme.textTheme.bodyMedium),
                        Text(
                          i.partNo,
                          style: const TextStyle(
                            color: AppColors.orange,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${i.qty} × ${baht(i.cost)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
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

// ─────────────────────────────────────────────────────────────────────────────
// Create PO modal: supplier + add items (search products) + qty/cost editing.
// ─────────────────────────────────────────────────────────────────────────────

class _DraftItem {
  final String partNo;
  final String name;
  int qty;
  double cost;
  // Set once the user types a cost; a supplier change then leaves it alone.
  bool costEdited = false;
  _DraftItem({
    required this.partNo,
    required this.name,
    required this.qty,
    required this.cost,
  });
}

/// Distinct supplier names, first spelling wins, compared trimmed and
/// case-insensitively. [recent] (past PO suppliers, newest first) leads.
List<String> _knownSupplierNames(
  Iterable<String> recent,
  Iterable<String> quoted,
) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in [...recent, ...quoted]) {
    final name = raw.trim();
    if (name.isEmpty || !seen.add(supplierKey(name))) continue;
    out.add(name);
  }
  return out;
}

class _CreatePoDialog extends StatefulWidget {
  final List<ProductRow> products;
  final List<SupplierRow> suppliers;
  final List<String> knownSuppliers;

  /// Prefill: this supplier is picked and its low-stock products added.
  final String? initialSupplier;
  const _CreatePoDialog({
    required this.products,
    this.suppliers = const [],
    this.knownSuppliers = const [],
    this.initialSupplier,
  });

  @override
  State<_CreatePoDialog> createState() => _CreatePoDialogState();
}

class _CreatePoDialogState extends State<_CreatePoDialog> {
  final _supplierCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final List<_DraftItem> _items = [];
  String _supplier = '';
  String _partSearch = '';
  bool _supplierFocused = false;
  // Bumped on a re-price so the draft rows' cost fields (initialValue) rebuild.
  int _priceGen = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final supplier = widget.initialSupplier?.trim() ?? '';
    if (supplier.isEmpty) return;
    // Applied directly (no setState before the first build), as
    // _pickSupplier + _addLowStock would.
    _supplierCtrl.text = supplier;
    _supplier = supplier;
    for (final p in _lowStock) {
      final short = p.minStock - p.stock;
      _items.add(
        _DraftItem(
          partNo: p.partNo,
          name: p.name,
          qty: short < 1 ? 1 : short,
          cost: _costFor(p),
        ),
      );
    }
  }

  @override
  void dispose() {
    _supplierCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<ProductRow> get _filteredParts {
    final q = _partSearch.toLowerCase();
    if (q.isEmpty) return const [];
    return widget.products
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.partNo.toLowerCase().contains(q),
        )
        .take(5)
        .toList();
  }

  List<String> get _supplierSuggestions {
    final q = supplierKey(_supplier);
    return widget.knownSuppliers
        .where((n) => n.toLowerCase().contains(q))
        .take(8)
        .toList();
  }

  /// Supplier quote rows whose name is the typed supplier.
  List<SupplierRow> get _supplierRows {
    final q = supplierKey(_supplier);
    if (q.isEmpty) return const [];
    return widget.suppliers.where((s) => supplierKey(s.name) == q).toList();
  }

  List<ProductRow> get _supplierProducts {
    final ids = _supplierRows.map((s) => s.productId).toSet();
    return widget.products.where((p) => ids.contains(p.id)).toList();
  }

  /// The known supplier's low-stock products not yet in the draft (empty for
  /// an unknown/free-text supplier).
  List<ProductRow> get _lowStock => _supplierProducts
      .where(
        (p) =>
            stockLevel(p) != StockLevel.ok &&
            !_items.any((i) => i.partNo == p.partNo),
      )
      .toList();

  /// The picked supplier's quoted unit cost for [p] (lowest when it has
  /// several rows), else the product cost. Freight stays out of the PO cost.
  double _costFor(ProductRow p) {
    double? best;
    for (final s in _supplierRows) {
      if (s.productId == p.id && (best == null || s.unitCost < best)) {
        best = s.unitCost;
      }
    }
    return best ?? p.cost;
  }

  /// Supplier changed: re-price lines whose cost the user never edited.
  void _reprice() {
    for (final item in _items) {
      if (item.costEdited) continue;
      final p = widget.products.where((p) => p.partNo == item.partNo);
      if (p.isNotEmpty) item.cost = _costFor(p.first);
    }
    _priceGen++;
  }

  void _setSupplier(String v) => setState(() {
    _supplier = v;
    _reprice();
  });

  double get _poTotalDraft =>
      _items.fold<double>(0, (s, i) => s + i.qty * i.cost);

  bool get _canSave => _supplier.trim().isNotEmpty && _items.isNotEmpty;

  void _addItem(ProductRow product, {int qty = 1}) {
    setState(() {
      final ex = _items.where((i) => i.partNo == product.partNo).firstOrNull;
      if (ex != null) {
        ex.qty += 1;
      } else {
        _items.add(
          _DraftItem(
            partNo: product.partNo,
            name: product.name,
            qty: qty,
            cost: _costFor(product),
          ),
        );
      }
      _partSearch = '';
      _searchCtrl.clear();
    });
  }

  void _addLowStock() {
    for (final p in _lowStock) {
      final short = p.minStock - p.stock;
      _addItem(p, qty: short < 1 ? 1 : short);
    }
  }

  /// Enter in the item search: an exact part number first, else the first
  /// listed match.
  /// Enter adds the exact part number, else the first match. A camera scan
  /// passes [exactOnly]: an unknown or partial code only shows its matches.
  void _addSearchMatch({bool exactOnly = false}) {
    final q = _partSearch.trim().toLowerCase();
    if (q.isEmpty) return;
    final exact = widget.products.where((p) => p.partNo.toLowerCase() == q);
    final pick = exact.isNotEmpty
        ? exact.first
        : (exactOnly ? null : _filteredParts.firstOrNull);
    if (pick != null) _addItem(pick);
  }

  void _pickSupplier(String name) {
    _supplierCtrl.text = name;
    _setSupplier(name);
    FocusScope.of(context).unfocus();
  }

  void _removeItem(String partNo) {
    setState(() => _items.removeWhere((i) => i.partNo == partNo));
  }

  Future<void> _submit() async {
    if (_busy || !_canSave) return;
    setState(() => _busy = true);
    try {
      await context.read<PurchaseOrdersRepository>().savePO(
        PoInput(
          supplier: _supplier.trim(),
          items: _items
              .map(
                (i) => PoLineInput(
                  partNo: i.partNo,
                  name: i.name,
                  qty: i.qty,
                  cost: i.cost,
                ),
              )
              .toList(),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ServerErrorResolver.resolveCounterError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _box(List<Widget> children) => Container(
    margin: const EdgeInsets.only(top: 4),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(children: children),
  );

  Widget _partTile(ProductRow p, {double? cost}) {
    final low = p.stock <= p.minStock;
    return InkWell(
      onTap: () => _addItem(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    low
                        ? 'คงเหลือ ${p.stock} · สต็อกต่ำ'
                        : 'คงเหลือ ${p.stock}',
                    style: TextStyle(
                      fontSize: 12,
                      color: low ? AppColors.warning : AppColors.steelBlue,
                      fontWeight: low ? FontWeight.w700 : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    p.partNo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.orange,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  if (cost != null)
                    Text(baht(cost), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.add, size: 18, color: AppColors.steelBlue),
          ],
        ),
      ),
    );
  }

  Widget _supplierPicker() {
    final suggestions = _supplierSuggestions;
    final exact = suggestions.any((n) => supplierKey(n) == supplierKey(_supplier));
    final showList = _supplierFocused && !exact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          onFocusChange: (f) => setState(() => _supplierFocused = f),
          child: AppTextField(
            label: 'ซัพพลายเออร์ · Supplier',
            hint: 'ชื่อบริษัทซัพพลายเออร์…',
            controller: _supplierCtrl,
            onChanged: _setSupplier,
          ),
        ),
        // TextFieldTapRegion: tapping a suggestion is not a "tap outside" the
        // field, so the list is not torn down before the tap lands.
        if (showList)
          TextFieldTapRegion(
            child: suggestions.isNotEmpty
                ? _box([
                    for (final n in suggestions)
                      InkWell(
                        onTap: () => _pickSupplier(n),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.factory_outlined,
                                size: 18,
                                color: AppColors.steelBlue,
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(n)),
                            ],
                          ),
                        ),
                      ),
                  ])
                : _supplier.trim().isEmpty
                ? const SizedBox.shrink()
                : const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      // agent ร่าง
                      'ไม่พบซัพพลายเออร์นี้ — จะบันทึกเป็นซัพพลายเออร์ใหม่',
                      style: TextStyle(color: AppColors.steelBlue),
                    ),
                  ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final parts = _filteredParts;
    final supplierProducts = _supplierProducts;
    final lowStock = _lowStock;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'สร้างใบสั่งซื้อใหม่ · New Purchase Order',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _supplierPicker(),
                      if (supplierProducts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'สินค้าของซัพพลายเออร์นี้', // agent ร่าง
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        _box([
                          for (final p in supplierProducts)
                            _partTile(p, cost: _costFor(p)),
                        ]),
                      ],
                      const SizedBox(height: 14),
                      AppTextField(
                        label: 'เพิ่มสินค้า · Add Items',
                        hint: 'ค้นหาด้วยชื่อหรือรหัสสินค้า…',
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() => _partSearch = v),
                        onSubmitted: _addSearchMatch,
                        suffix: BarcodeScanButton(
                          onScanned: (v) {
                            _searchCtrl.text = v;
                            setState(() => _partSearch = v);
                            _addSearchMatch(exactOnly: true);
                          },
                        ),
                      ),
                      if (parts.isNotEmpty)
                        _box([for (final p in parts) _partTile(p)])
                      else if (_partSearch.trim().isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'ไม่พบสินค้า',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.steelBlue),
                          ),
                        ),
                      if (lowStock.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _addLowStock,
                            icon: const Icon(Icons.playlist_add),
                            label: Text(
                              // agent ร่าง
                              'เพิ่มสินค้าสต็อกต่ำ (${lowStock.length} รายการ)',
                            ),
                          ),
                        ),
                      if (_items.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        for (final item in _items)
                          _DraftItemRow(
                            key: ValueKey((item.partNo, _priceGen)),
                            item: item,
                            onQty: (q) => setState(() => item.qty = q),
                            onCost: (c) => setState(() {
                              item.cost = c;
                              item.costEdited = true;
                            }),
                            onRemove: () => _removeItem(item.partNo),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            const Text(
                              'มูลค่ารวม: ',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            MoneyText(_poTotalDraft, emphasis: true),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (!_canSave && !_busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    // agent ร่าง
                    'เลือกซัพพลายเออร์และเพิ่มสินค้าอย่างน้อย 1 รายการ',
                    textAlign: TextAlign.end,
                    style: TextStyle(color: AppColors.steelBlue, fontSize: 12),
                  ),
                ),
              // Wrap, not Row: at phone width (390) the two buttons don't fit
              // side by side inside the dialog.
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton.secondary(
                    label: 'ยกเลิก',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  AppButton(
                    label: 'บันทึกใบสั่งซื้อ',
                    icon: Icons.save,
                    busy: _busy,
                    onPressed: _canSave ? _submit : null,
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

class _DraftItemRow extends StatelessWidget {
  final _DraftItem item;
  final ValueChanged<int> onQty;
  final ValueChanged<double> onCost;
  final VoidCallback onRemove;

  const _DraftItemRow({
    super.key,
    required this.item,
    required this.onQty,
    required this.onCost,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        Text(
          item.partNo,
          style: const TextStyle(
            color: AppColors.orange,
            fontFamily: 'monospace',
            fontSize: 10,
          ),
        ),
      ],
    );
    final qtyField = _MiniNum(
      label: 'จำนวน',
      value: item.qty.toString(),
      onChanged: (s) => onQty(int.tryParse(s) ?? 1),
    );
    final costField = _MiniNum(
      label: 'ราคาทุน ฿',
      value: _trim(item.cost),
      onChanged: (s) => onCost(double.tryParse(s) ?? 0),
    );
    // FittedBox(scaleDown) keeps the total a deterministic 70dp cell that works
    // in BOTH the wide Row and the narrow Wrap (a Flexible here would crash the
    // Wrap), while large baht values / text scale shrink to fit instead of clip.
    final total = SizedBox(
      width: 70,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(
          baht(item.qty * item.cost),
          maxLines: 1,
          softWrap: false,
          style: const TextStyle(
            color: AppColors.orange,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
    );
    final removeBtn = IconButton(
      tooltip: 'นำออกจากใบสั่งซื้อ', // owner-ratified 2026-10-12
      onPressed: onRemove,
      icon: const Icon(Icons.close, size: 18),
      color: AppColors.steelBlue,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      // Below ~440px the single-row layout (name + 2 number fields + total +
      // remove) overflows; stack the controls under the name on narrow widths.
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: name),
                    removeBtn,
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [qtyField, costField, total],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: name),
              const SizedBox(width: 8),
              Flexible(child: qtyField),
              const SizedBox(width: 8),
              Flexible(child: costField),
              const SizedBox(width: 8),
              total,
              removeBtn,
            ],
          );
        },
      ),
    );
  }

  static String _trim(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
}

class _MiniNum extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  const _MiniNum({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: const TextStyle(color: AppColors.steelBlue, fontSize: 12),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 68,
          child: AppTextField.numeric(
            initialValue: value,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
