// Screen for owner review: Outbox ops needing owner attention + Review items.
// Defined in docs/Backend_design/08_PHASE2_SPEC.md §14 and 09_PHASE2_LANES.md §3, §4.2, §6.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/review_items_repository.dart';
import '../../data/sync/sync_facade.dart';
import '../../domain/models/review_item.dart';

class OwnerReviewScreen extends StatefulWidget {
  const OwnerReviewScreen({super.key});

  @override
  State<OwnerReviewScreen> createState() => _OwnerReviewScreenState();
}

class _OwnerReviewScreenState extends State<OwnerReviewScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SyncFacade? syncFacade;
    try {
      syncFacade = context.read<SyncFacade>();
    } catch (_) {
      syncFacade = null;
    }

    final needsOwnerStream = syncFacade?.needsOwner ?? const Stream.empty();

    return StreamBuilder<List<OutboxOpView>>(
      stream: needsOwnerStream,
      builder: (context, snapshot) {
        final outboxOps = snapshot.data ?? const <OutboxOpView>[];
        final outboxCount = outboxOps.length;

        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'รายการรอเจ้าของ',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: AppColors.navy,
            foregroundColor: AppColors.white,
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: AppColors.orange,
              indicatorWeight: 3,
              labelColor: AppColors.orange,
              unselectedLabelColor: AppColors.gray300,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('ถูกปฏิเสธ / ค้าง'),
                      if (outboxCount > 0) ...[
                        const SizedBox(width: 8),
                        Badge.count(
                          count: outboxCount,
                          backgroundColor: AppColors.error,
                        ),
                      ],
                    ],
                  ),
                ),
                const Tab(
                  child: Text('รอตรวจ'),
                ),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _RejectedAndStuckTab(
                ops: outboxOps,
                syncFacade: syncFacade,
              ),
              const _PendingReviewItemsTab(),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 1: ถูกปฏิเสธ / ค้าง (From SyncFacade.needsOwner)
// ─────────────────────────────────────────────────────────────────────────────

class _RejectedAndStuckTab extends StatelessWidget {
  final List<OutboxOpView> ops;
  final SyncFacade? syncFacade;

  const _RejectedAndStuckTab({
    required this.ops,
    this.syncFacade,
  });

  String _opTypeThai(String type) {
    switch (type) {
      case 'sale.create':
        return 'ขายสินค้า';
      case 'return.create':
        return 'คืนสินค้า';
      case 'shift.open':
        return 'เปิดกะ';
      case 'shift.close':
        return 'ปิดกะ';
      case 'drawer.entry':
        return 'เงินเข้า/ออกลิ้นชัก';
      case 'customer.create':
        return 'เพิ่มลูกค้า';
      case 'credit_payment.create':
        return 'ชำระหนี้ช่าง';
      default:
        return type;
    }
  }

  Future<void> _handleResend(BuildContext context, OutboxOpView op) async {
    if (syncFacade == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ระบบซิงค์ยังไม่พร้อมใช้งาน')),
      );
      return;
    }

    try {
      await syncFacade!.resend(op.opId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ส่งรายการใหม่แล้ว: ${op.docNo ?? op.opId}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาดในการส่งใหม่: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _handleDiscard(BuildContext context, OutboxOpView op) async {
    if (syncFacade == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ระบบซิงค์ยังไม่พร้อมใช้งาน')),
      );
      return;
    }

    final noteController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.error),
              SizedBox(width: 8),
              Text('ยืนยันการทิ้งรายการ'),
            ],
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'รายการ: ${_opTypeThai(op.type)} ${op.docNo != null ? "(${op.docNo})" : ""}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'การทิ้งรายการจะยกเลิกการส่งรายการนี้ไปยังเซิร์ฟเวอร์ กรุณาระบุหมายเหตุหรือเหตุผลประกอบ',
                  style: TextStyle(fontSize: 13, color: AppColors.gray500),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: noteController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'หมายเหตุการทิ้งรายการ *',
                    hintText: 'ระบุเหตุผล เช่น ข้อมูลซ้ำ, ป้อนผิดพลาด',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'กรุณาระบุหมายเหตุการทิ้งรายการ';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: AppColors.white,
              ),
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              child: const Text('ยืนยันการทิ้ง'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final note = noteController.text.trim();
    try {
      final result = await syncFacade!.discard(op.opId, note);
      if (context.mounted) {
        final message = result.serverHasRow
            ? 'ทิ้งรายการแล้ว (เซิร์ฟเวอร์มีข้อมูลนี้อยู่ จะดึงข้อมูลล่าสุดในการซิงค์)'
            : 'ทิ้งรายการและลบข้อมูลในเครื่องเรียบร้อยแล้ว';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: AppColors.info,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ไม่สามารถทิ้งรายการได้: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ops.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: AppColors.success),
            const SizedBox(height: 16),
            const Text(
              'ไม่มีรายการที่ถูกปฏิเสธหรือค้างส่ง',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.navy,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'ข้อมูลทั้งหมดได้รับการซิงค์เรียบร้อยแล้ว',
              style: TextStyle(color: AppColors.gray500),
            ),
          ],
        ),
      );
    }

    final dateFormat = DateFormat('dd/MM/yyyy HH:mm');

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: ops.length,
      itemBuilder: (context, index) {
        final op = ops[index];
        final isRejected = op.status == OutboxOpStatus.rejected;

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isRejected
                  ? AppColors.error.withValues(alpha: 0.4)
                  : AppColors.warning.withValues(alpha: 0.4),
              width: 1.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isRejected
                            ? AppColors.error.withValues(alpha: 0.12)
                            : AppColors.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isRejected ? 'ถูกปฏิเสธ' : 'ค้างส่ง',
                        style: TextStyle(
                          color: isRejected ? AppColors.error : AppColors.warning,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _opTypeThai(op.type),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (op.docNo != null)
                      Text(
                        op.docNo!,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.navyLight,
                          fontSize: 14,
                        ),
                      ),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'พยายามส่งแล้ว: ${op.attempts} ครั้ง',
                      style: const TextStyle(fontSize: 13, color: AppColors.gray600),
                    ),
                    Text(
                      dateFormat.format(op.createdAt),
                      style: const TextStyle(fontSize: 13, color: AppColors.gray500),
                    ),
                  ],
                ),
                if (op.lastCode != null || op.lastMessage != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.gray100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (op.lastCode != null)
                          Text(
                            'รหัสข้อผิดพลาด: ${op.lastCode}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.error,
                            ),
                          ),
                        if (op.lastMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            op.lastMessage!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.navy,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text(
                      'ดูข้อมูล payload',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.steelBlue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.navyDeep,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          const JsonEncoder.withIndent('  ').convert(op.payload),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: AppColors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: const BorderSide(color: AppColors.error),
                      ),
                      onPressed: () => _handleDiscard(context, op),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('ทิ้ง'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.orange,
                        foregroundColor: AppColors.white,
                      ),
                      onPressed: () => _handleResend(context, op),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('ส่งใหม่'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 2: รอตรวจ (From ReviewItemsRepository)
// ─────────────────────────────────────────────────────────────────────────────

class _PendingReviewItemsTab extends StatefulWidget {
  const _PendingReviewItemsTab();

  @override
  State<_PendingReviewItemsTab> createState() => _PendingReviewItemsTabState();
}

class _PendingReviewItemsTabState extends State<_PendingReviewItemsTab> {
  bool _loading = true;
  String? _error;
  List<ReviewItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repo = context.read<ReviewItemsRepository>();
      final items = await repo.listPending();
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _handleMarkReviewed(ReviewItem item) async {
    try {
      final repo = context.read<ReviewItemsRepository>();
      await repo.markReviewed(item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('บันทึกการตรวจสอบเรียบร้อยแล้ว'),
            backgroundColor: AppColors.success,
          ),
        );
        setState(() {
          _items = _items.where((i) => i.id != item.id).toList();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาดในการบันทึก: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Color _kindColor(ReviewItemKind kind) {
    switch (kind) {
      case ReviewItemKind.voidOffline:
        return AppColors.error;
      case ReviewItemKind.creditOverride:
        return AppColors.orange;
      case ReviewItemKind.shiftUncounted:
        return AppColors.warning;
      case ReviewItemKind.dateFlag:
        return AppColors.steelBlue;
      case ReviewItemKind.deviceForceRetired:
        return Colors.purple;
      case ReviewItemKind.unknown:
        return AppColors.gray500;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.orange),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: 12),
            Text(
              'ไม่สามารถโหลดรายการรอตรวจได้: $_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.error),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadItems,
              icon: const Icon(Icons.refresh),
              label: const Text('ลองใหม่'),
            ),
          ],
        ),
      );
    }

    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadItems,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified_outlined, size: 64, color: AppColors.success),
                    const SizedBox(height: 16),
                    const Text(
                      'ไม่มีรายการที่รอตรวจ',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'ทุกรายการได้รับการตรวจสอบเรียบร้อยแล้ว',
                      style: TextStyle(color: AppColors.gray500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final dateFormat = DateFormat('dd/MM/yyyy HH:mm');

    return RefreshIndicator(
      onRefresh: _loadItems,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          final color = _kindColor(item.kind);

          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          item.kind.labelTh,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'อ้างอิง: ${item.refId}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        dateFormat.format(item.createdAt),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.gray500,
                        ),
                      ),
                    ],
                  ),
                  if (item.details.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.gray100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: item.details.entries.map((entry) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${entry.key}: ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    entry.value?.toString() ?? '-',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.forestGreen,
                        foregroundColor: AppColors.white,
                      ),
                      onPressed: () => _handleMarkReviewed(item),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('ตรวจแล้ว'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
