// CustomersScreen — ลูกค้า: customer registry + loyalty points.
//
// Behaviour parity port of pos/CustomersScreen.jsx:
//  • Top bar: total-customers stat, total-spend stat, search box, + เพิ่มลูกค้า.
//  • Table: รหัส / ชื่อ / เบอร์โทร / ที่อยู่ / แต้ม / ยอดซื้อรวม / จำนวนบิล / actions.
//  • Search filters by name (EN/TH), phone, code (case-insensitive).
//  • Add / edit modal (ชื่อ TH/EN, เบอร์โทร, ที่อยู่); save validates a name.
//  • Delete with a confirm that warns when the customer has bills.
//  • จำนวนบิล = count of sales whose customerId == customer.id.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../providers/providers.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_view.dart';
import '../widgets/search_field.dart';

/// Combined snapshot: customers + sales (for the per-customer bill count).
class _CustomersData {
  final List<CustomerRow> customers;
  final Map<String, int> billCountByCustomer;
  const _CustomersData(this.customers, this.billCountByCustomer);
}

/// Loads customers + indexes sales by customerId once → O(1) bill-count lookup.
final _customersDataProvider = FutureProvider.autoDispose<_CustomersData>(
  (ref) async {
    final customers = await ref.watch(customersRepoProvider).getCustomers();
    final sales = await ref.watch(salesRepoProvider).getSales();
    final billCount = <String, int>{};
    for (final s in sales) {
      final cid = s.sale.customerId;
      if (cid != null) billCount[cid] = (billCount[cid] ?? 0) + 1;
    }
    return _CustomersData(customers, billCount);
  },
);

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _search = '';

  void _refresh() => ref.invalidate(_customersDataProvider);

  List<CustomerRow> _filter(List<CustomerRow> all) {
    final q = _search.toLowerCase();
    if (q.isEmpty) return all;
    return all.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.nameTH.contains(q) ||
          (c.phone ?? '').contains(q) ||
          c.code.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _openEditor({CustomerRow? customer}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _CustomerEditorDialog(customer: customer),
    );
    if (result == true) _refresh();
  }

  Future<void> _handleDelete(CustomerRow c, int billCount) async {
    final msg = billCount > 0
        ? 'ลบลูกค้า "${c.nameTH}"?\n\n'
            'ลูกค้ารายนี้มี $billCount บิล (ประวัติการขายจะยังคงอยู่ แต่ไม่มีชื่อลูกค้าผูก)'
        : 'ลบลูกค้า "${c.nameTH}"?';
    final ok = await showConfirm(context, 'ลบลูกค้า', msg, danger: true);
    if (!ok) return;
    await ref.read(customersRepoProvider).deleteCustomer(c.id);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(_customersDataProvider);
    return Scaffold(
      body: dataAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => Center(child: Text('เกิดข้อผิดพลาด: $e')),
        data: (data) {
          final filtered = _filter(data.customers);
          final totalSpend =
              data.customers.fold<double>(0, (s, c) => s + c.totalSpend);
          return Column(
            children: [
              _TopBar(
                customerCount: data.customers.length,
                totalSpend: totalSpend,
                onSearch: (v) => setState(() => _search = v),
                onAdd: () => _openEditor(),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.people_outline,
                        message: 'ยังไม่มีลูกค้า',
                      )
                    : _CustomersTable(
                        customers: filtered,
                        billCountByCustomer: data.billCountByCustomer,
                        onEdit: (c) => _openEditor(customer: c),
                        onDelete: _handleDelete,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final int customerCount;
  final double totalSpend;
  final ValueChanged<String> onSearch;
  final VoidCallback onAdd;

  const _TopBar({
    required this.customerCount,
    required this.totalSpend,
    required this.onSearch,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = theme.dividerColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: Row(
        children: [
          _Stat(value: '$customerCount', label: 'ลูกค้าทั้งหมด'),
          const SizedBox(width: 28),
          _Stat(value: baht(totalSpend), label: 'ยอดขายรวม'),
          const Spacer(),
          SizedBox(
            width: 260,
            child: SearchField(
              hint: 'ค้นหาลูกค้า / เบอร์โทร…',
              onChanged: onSearch,
            ),
          ),
          const SizedBox(width: 16),
          AppButton(
            label: 'เพิ่มลูกค้า',
            icon: Icons.add,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.secondary,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

class _CustomersTable extends StatelessWidget {
  final List<CustomerRow> customers;
  final Map<String, int> billCountByCustomer;
  final ValueChanged<CustomerRow> onEdit;
  final void Function(CustomerRow, int) onDelete;

  const _CustomersTable({
    required this.customers,
    required this.billCountByCustomer,
    required this.onEdit,
    required this.onDelete,
  });

  // Below this width the multi-column table can't fit (largest column set is
  // ~900px wide); fall back to a stacked card list so phone widths don't
  // RenderFlex-overflow.
  static const double _tableBreakpoint = 700;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _tableBreakpoint) {
          return _buildCardList(context);
        }
        return _buildTable(context, constraints.maxWidth);
      },
    );
  }

  Widget _buildTable(BuildContext context, double availableWidth) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 1,
      color: theme.colorScheme.secondary,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: availableWidth),
          child: DataTable(
            headingTextStyle: headerStyle,
            columnSpacing: 28,
            horizontalMargin: 18,
            columns: const [
              DataColumn(label: Text('รหัส')),
              DataColumn(label: Text('ชื่อ')),
              DataColumn(label: Text('เบอร์โทร')),
              DataColumn(label: Text('ที่อยู่')),
              DataColumn(label: Text('แต้ม')),
              DataColumn(label: Text('ยอดซื้อรวม')),
              DataColumn(label: Text('จำนวนบิล')),
              DataColumn(label: Text('')),
            ],
            rows: [
              for (final c in customers)
                _buildRow(context, theme, c, billCountByCustomer[c.id] ?? 0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardList(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: customers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final c = customers[i];
        return _buildCard(context, c, billCountByCustomer[c.id] ?? 0);
      },
    );
  }

  Widget _buildCard(BuildContext context, CustomerRow c, int billCount) {
    final theme = Theme.of(context);
    final monoStyle = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.orange,
      fontFamily: 'monospace',
    );
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.secondary,
      letterSpacing: 1,
    );
    final numStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );

    Widget metric(String label, String value, {Color? color}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: labelStyle),
          const SizedBox(height: 2),
          Text(value, style: numStyle?.copyWith(color: color)),
        ],
      );
    }

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(c.code, style: monoStyle),
                    const SizedBox(height: 4),
                    Text(
                      c.nameTH,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (c.name.isNotEmpty)
                      Text(
                        c.name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                  ],
                ),
              ),
              if ((c.phone ?? '').isNotEmpty)
                Text(c.phone!, style: theme.textTheme.bodyMedium),
            ],
          ),
          if ((c.address ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              c.address!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.secondary,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              metric('แต้ม', '${c.points}', color: AppColors.orange),
              metric('ยอดซื้อรวม', baht(c.totalSpend)),
              metric('จำนวนบิล', '$billCount'),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => onEdit(c),
                child: const Text('แก้ไข'),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: () => onDelete(c, billCount),
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                child: const Text('ลบ'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  DataRow _buildRow(
    BuildContext context,
    ThemeData theme,
    CustomerRow c,
    int billCount,
  ) {
    final monoStyle = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.orange,
      fontFamily: 'monospace',
    );
    final numStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    return DataRow(
      cells: [
        DataCell(Text(c.code, style: monoStyle)),
        DataCell(
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.nameTH,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (c.name.isNotEmpty)
                Text(
                  c.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
            ],
          ),
        ),
        DataCell(Text(c.phone ?? '')),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              c.address ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.secondary,
              ),
            ),
          ),
        ),
        DataCell(
          Text(
            '${c.points}',
            style: numStyle?.copyWith(color: AppColors.orange),
          ),
        ),
        DataCell(Text(baht(c.totalSpend), style: numStyle)),
        DataCell(
          Center(child: Text('$billCount', style: theme.textTheme.bodyLarge)),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => onEdit(c),
                child: const Text('แก้ไข'),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: () => onDelete(c, billCount),
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                child: const Text('ลบ'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Add / edit customer dialog. Pops `true` when a save succeeded.
class _CustomerEditorDialog extends ConsumerStatefulWidget {
  final CustomerRow? customer;
  const _CustomerEditorDialog({this.customer});

  @override
  ConsumerState<_CustomerEditorDialog> createState() =>
      _CustomerEditorDialogState();
}

class _CustomerEditorDialogState extends ConsumerState<_CustomerEditorDialog> {
  late final TextEditingController _nameTH;
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  bool _saving = false;

  bool get _isNew => widget.customer == null;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _nameTH = TextEditingController(text: c?.nameTH ?? '');
    _name = TextEditingController(text: c?.name ?? '');
    _phone = TextEditingController(text: c?.phone ?? '');
    _address = TextEditingController(text: c?.address ?? '');
  }

  @override
  void dispose() {
    _nameTH.dispose();
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameTH.text.trim().isEmpty && _name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากรอกชื่อลูกค้า')),
      );
      return;
    }
    setState(() => _saving = true);
    final repo = ref.read(customersRepoProvider);
    final phone = _phone.text;
    final address = _address.text;
    try {
      if (_isNew) {
        await repo.addCustomer(CustomersCompanion(
          name: Value(_name.text),
          nameTH: Value(_nameTH.text),
          phone: Value(phone.isEmpty ? null : phone),
          address: Value(address.isEmpty ? null : address),
        ));
      } else {
        await repo.updateCustomer(
          widget.customer!.id,
          CustomersCompanion(
            name: Value(_name.text),
            nameTH: Value(_nameTH.text),
            phone: Value(phone.isEmpty ? null : phone),
            address: Value(address.isEmpty ? null : address),
          ),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? 'เพิ่มลูกค้าใหม่' : 'แก้ไขข้อมูลลูกค้า'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppTextField(
                    label: 'ชื่อ (TH)',
                    controller: _nameTH,
                    autofocus: true,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: AppTextField(label: 'ชื่อ (EN)', controller: _name),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppTextField(label: 'เบอร์โทร', controller: _phone),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: AppTextField(label: 'ที่อยู่', controller: _address),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'ยกเลิก',
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: 'บันทึก',
          busy: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
