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

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/purchase_orders_repository.dart';
import '../../domain/models/aggregates.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/money_text.dart';
import '../widgets/status_chip.dart';
import '../widgets/thai_format.dart';

class PurchaseOrdersScreen extends StatefulWidget {
  const PurchaseOrdersScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _posFuture = context.read<PurchaseOrdersRepository>().getPOs();
    _productsFuture = context.read<ProductsRepository>().getAll();
  }

  void _refresh() => setState(_load);

  Future<void> _openCreate() async {
    final products = await _productsFuture;
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CreatePoDialog(products: products),
    );
    if (saved == true) _refresh();
  }

  Future<void> _receive(PurchaseOrderRow po) async {
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(
      context,
      'รับสินค้าเข้าสต็อก',
      'ยืนยันรับสินค้าเข้าสต็อก?\n(ต้นทุนสินค้าจะถูกอัปเดตตามราคาในใบสั่งซื้อ)',
    );
    if (!ok) return;
    final unmatched = await repo.receivePO(po.id);
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
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(
      context,
      'ยกเลิกใบสั่งซื้อ',
      'ยกเลิกใบสั่งซื้อ ${po.poNo}?\n(สถานะจะเปลี่ยนเป็น "ยกเลิก" — ไม่ลบข้อมูล)',
      danger: true,
    );
    if (!ok) return;
    await repo.cancelPO(po.id);
    _refresh();
  }

  Future<void> _delete(PurchaseOrderRow po) async {
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(
      context,
      'ลบใบสั่งซื้อ',
      'ลบใบสั่งซื้อ ${po.poNo} ออกจากระบบถาวร?\nการลบจะไม่สามารถกู้คืนได้',
      danger: true,
    );
    if (!ok) return;
    await repo.deletePO(po.id);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<PurchaseOrderWithItems>>(
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
            onReceive: _receive,
            onCancel: _cancel,
            onDelete: _delete,
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
  final ValueChanged<PurchaseOrderRow> onReceive;
  final ValueChanged<PurchaseOrderRow> onCancel;
  final ValueChanged<PurchaseOrderRow> onDelete;

  const _PoListView({
    required this.pos,
    required this.onCreate,
    required this.onReceive,
    required this.onCancel,
    required this.onDelete,
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
              bottom: BorderSide(
                color: Theme.of(context).dividerColor,
              ),
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
                          value: '${pos.length}', label: 'ใบสั่งซื้อทั้งหมด'),
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
                onPressed: onCreate,
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
                        data: pos[i],
                        onReceive: () => onReceive(pos[i].po),
                        onCancel: () => onCancel(pos[i].po),
                        onDelete: () => onDelete(pos[i].po),
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
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 0.8,
            color: AppColors.steelBlue,
          ),
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

  const _PoCard({
    required this.data,
    required this.onReceive,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final po = data.po;
    final theme = Theme.of(context);
    final border = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.08)
        : AppColors.gray200;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
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
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${data.items.length} รายการ · ${thaiDate(po.createdAt)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.steelBlue),
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
                  onPressed: onReceive,
                ),
                AppButton.secondary(label: 'ยกเลิก', onPressed: onCancel),
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
              IconButton(
                tooltip: 'ลบถาวร',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
                color: AppColors.error,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ],
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
  _DraftItem({
    required this.partNo,
    required this.name,
    required this.qty,
    required this.cost,
  });
}

class _CreatePoDialog extends StatefulWidget {
  final List<ProductRow> products;
  const _CreatePoDialog({required this.products});

  @override
  State<_CreatePoDialog> createState() => _CreatePoDialogState();
}

class _CreatePoDialogState extends State<_CreatePoDialog> {
  final _supplierCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final List<_DraftItem> _items = [];
  String _supplier = '';
  String _partSearch = '';
  bool _busy = false;

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
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.partNo.toLowerCase().contains(q))
        .take(5)
        .toList();
  }

  double get _poTotalDraft =>
      _items.fold<double>(0, (s, i) => s + i.qty * i.cost);

  void _addItem(ProductRow product) {
    setState(() {
      final ex = _items.where((i) => i.partNo == product.partNo).firstOrNull;
      if (ex != null) {
        ex.qty += 1;
      } else {
        _items.add(_DraftItem(
          partNo: product.partNo,
          name: product.name,
          qty: 1,
          cost: product.cost,
        ));
      }
      _partSearch = '';
      _searchCtrl.clear();
    });
  }

  void _removeItem(String partNo) {
    setState(() => _items.removeWhere((i) => i.partNo == partNo));
  }

  Future<void> _submit() async {
    if (_busy || _supplier.isEmpty || _items.isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<PurchaseOrdersRepository>().savePO(
            PoInput(
              supplier: _supplier,
              items: _items
                  .map((i) => PoLineInput(
                        partNo: i.partNo,
                        name: i.name,
                        qty: i.qty,
                        cost: i.cost,
                      ))
                  .toList(),
            ),
          );
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parts = _filteredParts;
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
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppTextField(
                        label: 'ซัพพลายเออร์ · Supplier',
                        hint: 'ชื่อบริษัทซัพพลายเออร์…',
                        controller: _supplierCtrl,
                        onChanged: (v) => setState(() => _supplier = v),
                      ),
                      const SizedBox(height: 14),
                      AppTextField(
                        label: 'เพิ่มสินค้า · Add Items',
                        hint: 'ค้นหาด้วยชื่อหรือรหัสสินค้า…',
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() => _partSearch = v),
                      ),
                      if (parts.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              for (final p in parts)
                                InkWell(
                                  onTap: () => _addItem(p),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 12),
                                    child: Row(
                                      children: [
                                        Expanded(child: Text(p.name)),
                                        Text(
                                          p.partNo,
                                          style: const TextStyle(
                                            color: AppColors.orange,
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (_items.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        for (final item in _items)
                          _DraftItemRow(
                            item: item,
                            onQty: (q) => setState(() => item.qty = q),
                            onCost: (c) => setState(() => item.cost = c),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppButton.secondary(
                    label: 'ยกเลิก',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: 'บันทึกใบสั่งซื้อ',
                    icon: Icons.save,
                    busy: _busy,
                    onPressed: (_supplier.isEmpty || _items.isEmpty)
                        ? null
                        : _submit,
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
