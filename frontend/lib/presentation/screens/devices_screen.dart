// DevicesScreen — Screen for managing shop terminals/devices (ADR-0004, Slice 21).
// Defined in docs/Backend_design/09_PHASE2_LANES.md §3, §88 and 08_PHASE2_SPEC.md §16.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/network/server_error_resolver.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/devices_repository.dart';
import '../../domain/models/device_model.dart';
import '../blocs/auth_cubit.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';
import '../widgets/device_enrolment_dialog.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy HH:mm');
  List<DeviceModel> _devices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repo = context.read<DevicesRepository>();
      final list = await repo.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ServerErrorResolver.resolveCounterError(e);
        _loading = false;
      });
    }
  }

  Future<void> _openCreateDeviceDialog() async {
    final result = await showDialog<({DeviceModel device, String enrolCode})>(
      context: context,
      builder: (ctx) => const _CreateDeviceDialog(),
    );

    if (result != null && mounted) {
      _loadDevices();
      _showEnrolCodeDialog(result.device, result.enrolCode);
    }
  }

  void _showEnrolCodeDialog(DeviceModel device, String enrolCode) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _EnrolCodeDisplayDialog(
        device: device,
        enrolCode: enrolCode,
      ),
    );
  }

  Future<void> _openRetireDialog(DeviceModel device) async {
    final retired = await showDialog<bool>(
      context: context,
      builder: (ctx) => _RetireDeviceDialog(device: device),
    );

    if (retired == true && mounted) {
      _loadDevices();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ปลดระวางเครื่อง #${device.deviceNo.toString().padLeft(2, '0')} (${device.label}) เรียบร้อยแล้ว'),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authState = context.watch<AuthCubit>().state;
    final currentDeviceToken = authState is Authenticated ? authState.deviceToken : null;
    final currentDeviceRole = authState is Authenticated ? authState.deviceRole : null;

    final posDevices = _devices.where((d) => d.isPos && !d.isRetired).toList();
    final backofficeDevices = _devices.where((d) => d.isBackoffice && !d.isRetired).toList();
    final retiredDevices = _devices.where((d) => d.isRetired).toList();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: RefreshIndicator(
        onRefresh: _loadDevices,
        child: CustomScrollView(
          slivers: [
            // ── Header & Action Banner ──
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'จัดการเครื่อง (Device Management)',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.navy,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'จัดการเครื่องขายหน้าร้าน (POS) และเครื่องจัดการทั่วไป (Backoffice) ตามกติกา ADR-0004',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            IconButton.outlined(
                              icon: const Icon(Icons.refresh),
                              tooltip: 'รีเฟรชรายการ',
                              onPressed: _loading ? null : _loadDevices,
                            ),
                            const SizedBox(width: 8),
                            AppButton.secondary(
                              label: 'ผูกเครื่องนี้',
                              icon: Icons.qr_code_scanner,
                              onPressed: () async {
                                final res = await DeviceEnrolmentDialog.show(context);
                                if (res == true) _loadDevices();
                              },
                            ),
                            const SizedBox(width: 8),
                            AppButton(
                              label: 'ออกรหัสผูกเครื่องใหม่',
                              icon: Icons.add_to_queue,
                              onPressed: _openCreateDeviceDialog,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // ── ADR-0004 & F8 Guideline Banner ──
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.navy.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.navy.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline, color: AppColors.navy, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'กติกาการใช้งานเครื่อง:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: AppColors.navy,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '• เครื่องขาย POS อนุญาตให้มีได้ 1 เครื่องต่อร้านค้า (มีสิทธิ์ออกใบเสร็จรับเงิน/ใบลดหนี้ และบันทึกเงินสดหน้าร้าน)\n'
                                  '• หากต้องการเปลี่ยนเครื่องขาย ให้ปลดระวาง (Retire) เครื่องเดิมก่อน จึงจะสามารถออกรหัสผูกเครื่อง POS ใหม่ได้\n'
                                  '• กรณีเครื่องล้างเบราว์เซอร์หรือ IndexedDB หาย จะต้องออกรหัสผูกเครื่องใหม่ และจะได้รับเลขเครื่อง (#No) ใหม่เสมอ (กฎ F8)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Current Terminal Info Pill ──
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: currentDeviceRole == 'pos'
                            ? AppColors.success.withValues(alpha: 0.1)
                            : (currentDeviceToken != null
                                ? AppColors.navy.withValues(alpha: 0.08)
                                : Colors.amber.withValues(alpha: 0.1)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: currentDeviceRole == 'pos'
                              ? AppColors.success.withValues(alpha: 0.3)
                              : (currentDeviceToken != null
                                  ? AppColors.navy.withValues(alpha: 0.3)
                                  : Colors.amber.withValues(alpha: 0.4)),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            currentDeviceRole == 'pos'
                                ? Icons.check_circle
                                : (currentDeviceToken != null ? Icons.computer : Icons.warning_amber),
                            color: currentDeviceRole == 'pos'
                                ? AppColors.success
                                : (currentDeviceToken != null ? AppColors.navy : Colors.orange[800]),
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              currentDeviceRole == 'pos'
                                  ? 'เครื่องปัจจุบันนี้: POS Terminal (เครื่องขายหน้าร้าน)'
                                  : (currentDeviceToken != null
                                      ? 'เครื่องปัจจุบันนี้: Backoffice Terminal'
                                      : 'เครื่องปัจจุบันนี้: ยังไม่ได้ผูกกับระบบ (โหมดทั่วไป)'),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                          ),
                          if (currentDeviceToken == null)
                            TextButton(
                              onPressed: () async {
                                final res = await DeviceEnrolmentDialog.show(context);
                                if (res == true) _loadDevices();
                              },
                              child: const Text('ผูกเครื่องนี้ทันที'),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),

            // ── Loading or Error State ──
            if (_loading)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.error, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(color: AppColors.error, fontSize: 15),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      AppButton(
                        label: 'ลองใหม่อีกครั้ง',
                        icon: Icons.refresh,
                        onPressed: _loadDevices,
                      ),
                    ],
                  ),
                ),
              )
            else if (_devices.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.devices_other, size: 64, color: theme.dividerColor),
                      const SizedBox(height: 16),
                      const Text(
                        'ยังไม่มีเครื่องที่ลงทะเบียนในระบบ',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text('กดปุ่ม "ออกรหัสผูกเครื่องใหม่" เพื่อเพิ่มเครื่องเข้าสู่ระบบ'),
                      const SizedBox(height: 16),
                      AppButton(
                        label: 'ออกรหัสผูกเครื่องใหม่',
                        icon: Icons.add,
                        onPressed: _openCreateDeviceDialog,
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // 1. Active POS Terminal
                    _buildSectionHeader('เครื่องขายหน้าร้าน (POS Terminal)', posDevices.length, 1),
                    if (posDevices.isEmpty)
                      _buildEmptyCard('ยังไม่มีเครื่องขายหน้าร้านที่ใช้งานอยู่ กด "ออกรหัสผูกเครื่องใหม่" เพื่อเพิ่ม POS')
                    else
                      for (final dev in posDevices) _buildDeviceCard(dev),

                    const SizedBox(height: 24),

                    // 2. Active Backoffice Terminals
                    _buildSectionHeader('เครื่องจัดการทั่วไป (Backoffice)', backofficeDevices.length, null),
                    if (backofficeDevices.isEmpty)
                      _buildEmptyCard('ยังไม่มีเครื่อง Backoffice กด "ออกรหัสผูกเครื่องใหม่" เพื่อเพิ่มเครื่องใช้งาน')
                    else
                      for (final dev in backofficeDevices) _buildDeviceCard(dev),

                    if (retiredDevices.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _buildSectionHeader('เครื่องที่ปลดระวางแล้ว (Retired)', retiredDevices.length, null),
                      for (final dev in retiredDevices) _buildDeviceCard(dev),
                    ],

                    const SizedBox(height: 48),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, int? max) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.navy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              max != null ? '$count/$max เครื่อง' : '$count เครื่อง',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.navy),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCard(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Center(
        child: Text(
          message,
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
      ),
    );
  }

  Widget _buildDeviceCard(DeviceModel device) {
    final theme = Theme.of(context);
    final isPos = device.isPos;
    final isRetired = device.isRetired;
    final hasUnsyncedOps = device.unsyncedOps > 0;

    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Device Number Badge ──
                Container(
                  constraints: const BoxConstraints(minWidth: 54),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: isRetired
                        ? Colors.grey.withValues(alpha: 0.2)
                        : (isPos ? AppColors.orange.withValues(alpha: 0.15) : AppColors.navy.withValues(alpha: 0.15)),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isRetired
                          ? Colors.grey.withValues(alpha: 0.3)
                          : (isPos ? AppColors.orange.withValues(alpha: 0.4) : AppColors.navy.withValues(alpha: 0.4)),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '#${device.deviceNo.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isRetired ? Colors.grey[600] : (isPos ? AppColors.orange : AppColors.navy),
                        ),
                      ),
                      Text(
                        isPos ? 'POS' : 'BO',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isRetired ? Colors.grey[600] : (isPos ? AppColors.orange : AppColors.navy),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),

                // ── Device Details ──
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              device.label,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                decoration: isRetired ? TextDecoration.lineThrough : null,
                                color: isRetired ? Colors.grey[600] : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildRoleChip(device),
                          const SizedBox(width: 6),
                          _buildStatusChip(device),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Device IDs and Timestamps
                      Text(
                        'Device ID: ${device.id}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (device.lastSeenAt != null)
                        Text(
                          'ใช้งานล่าสุด: ${_dateFormat.format(device.lastSeenAt!.toLocal())}',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      if (device.retiredAt != null)
                        Text(
                          'ปลดระวางเมื่อ: ${_dateFormat.format(device.retiredAt!.toLocal())}',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      if (!device.enrolled && device.enrolExpiresAt != null)
                        Text(
                          device.isEnrolCodeActive
                              ? 'รหัสผูกเครื่องหมดอายุ: ${_dateFormat.format(device.enrolExpiresAt!.toLocal())}'
                              : 'รหัสผูกเครื่องหมดอายุแล้ว',
                          style: TextStyle(
                            fontSize: 12,
                            color: device.isEnrolCodeActive ? Colors.orange[800] : AppColors.error,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),

                // ── Action Button ──
                if (!isRetired)
                  AppButton.danger(
                    label: 'ปลดเครื่อง',
                    icon: Icons.delete_outline,
                    onPressed: () => _openRetireDialog(device),
                  ),
              ],
            ),

            // ── Unsynced Ops Warning Banner ──
            if (hasUnsyncedOps && !isRetired) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: AppColors.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'มีรายการขายค้างส่ง ${device.unsyncedOps} รายการ'
                        '${device.unsyncedReportedAt != null ? ' (รายงานล่าสุด: ${_dateFormat.format(device.unsyncedReportedAt!.toLocal())})' : ''}',
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRoleChip(DeviceModel device) {
    final isPos = device.isPos;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isPos ? AppColors.orange.withValues(alpha: 0.12) : AppColors.navy.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isPos ? 'เครื่องขาย (POS)' : 'Backoffice',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: isPos ? AppColors.orange : AppColors.navy,
        ),
      ),
    );
  }

  Widget _buildStatusChip(DeviceModel device) {
    if (device.isRetired) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'ปลดระวางแล้ว',
          style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600),
        ),
      );
    }

    if (!device.enrolled) {
      final active = device.isEnrolCodeActive;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: active ? Colors.amber.withValues(alpha: 0.15) : AppColors.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          active ? 'รอผูกเครื่อง' : 'รหัสหมดอายุ',
          style: TextStyle(
            fontSize: 11,
            color: active ? Colors.orange[900] : AppColors.error,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'เชื่อมต่อแล้ว',
        style: TextStyle(fontSize: 11, color: AppColors.success, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Dialog 1: Create Device & Generate Code
// ════════════════════════════════════════════════════════════════════════

class _CreateDeviceDialog extends StatefulWidget {
  const _CreateDeviceDialog();

  @override
  State<_CreateDeviceDialog> createState() => _CreateDeviceDialogState();
}

class _CreateDeviceDialogState extends State<_CreateDeviceDialog> {
  final _labelController = TextEditingController();
  String _role = 'pos';
  bool _busy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      setState(() => _errorMessage = 'กรุณากรอกชื่อเรียกเครื่อง');
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final repo = context.read<DevicesRepository>();
      final result = await repo.createDevice(label: label, role: _role);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMessage = ServerErrorResolver.resolveCounterError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.add_to_queue, color: AppColors.navy),
          SizedBox(width: 10),
          Text('ออกรหัสผูกเครื่องใหม่', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'เลือกลักษณะการใช้งานของเครื่องที่ต้องการผูก:',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'pos',
                  label: Text('เครื่องขาย (POS)'),
                  icon: Icon(Icons.point_of_sale),
                ),
                ButtonSegment(
                  value: 'backoffice',
                  label: Text('Backoffice'),
                  icon: Icon(Icons.computer),
                ),
              ],
              selected: {_role},
              onSelectionChanged:
                  _busy ? null : (s) => setState(() => _role = s.first),
            ),
            const SizedBox(height: 10),
            Text(
              _role == 'pos'
                ? 'สำหรับคิดเงิน เปิดลิ้นชัก พิมพ์ใบเสร็จ และขายสินค้าออฟไลน์ (มีได้ 1 เครื่องต่อร้าน)'
                : 'สำหรับจัดการสต็อก อะไหล่ สั่งซื้อ ดูรายงาน หรือทำเอกสารหลังร้าน',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 16),
            AppTextField(
              label: 'ชื่อเรียกเครื่อง (Device Label)',
              hint: 'เช่น เคาน์เตอร์หน้าร้าน 1, โน้ตบุ๊กหลังร้าน',
              controller: _labelController,
              enabled: !_busy,
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: AppColors.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: AppColors.error, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('ยกเลิก'),
        ),
        AppButton(
          label: _busy ? 'กำลังสร้างรหัส...' : 'สร้างรหัสผูกเครื่อง',
          onPressed: _busy ? null : _submit,
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Dialog 2: Display Generated Enrolment Code
// ════════════════════════════════════════════════════════════════════════

class _EnrolCodeDisplayDialog extends StatelessWidget {
  final DeviceModel device;
  final String enrolCode;

  const _EnrolCodeDisplayDialog({
    required this.device,
    required this.enrolCode,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.vpn_key, color: AppColors.success),
          SizedBox(width: 10),
          Text('รหัสผูกเครื่องของคุณ', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'สำหรับเครื่อง #${device.deviceNo.toString().padLeft(2, '0')} (${device.label})',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.navy.withValues(alpha: 0.3)),
              ),
              child: SelectableText(
                enrolCode,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                  fontFamily: 'monospace',
                  color: AppColors.navy,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  icon: const Icon(Icons.copy),
                  tooltip: 'คัดลอกรหัส',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: enrolCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('คัดลอกรหัสผูกเครื่องเรียบร้อยแล้ว')),
                    );
                  },
                ),
                const SizedBox(width: 8),
                const Text('คัดลอกรหัสผูกเครื่อง', style: TextStyle(fontSize: 13)),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.timer_outlined, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'นำรหัส 6 หลักนี้ไปกรอกที่หน้าผูกเครื่องของเบราว์เซอร์เป้าหมาย รหัสนี้มีอายุ 15 นาที',
                      style: TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        AppButton(
          label: 'รับทราบ / ปิดหน้าต่าง',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Dialog 3: Retire Device with Physical Cash & Force Option
// ════════════════════════════════════════════════════════════════════════

class _RetireDeviceDialog extends StatefulWidget {
  final DeviceModel device;

  const _RetireDeviceDialog({required this.device});

  @override
  State<_RetireDeviceDialog> createState() => _RetireDeviceDialogState();
}

class _RetireDeviceDialogState extends State<_RetireDeviceDialog> {
  final _cashController = TextEditingController();
  final _noteController = TextEditingController();
  bool _force = false;
  bool _busy = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // If device has unsynced ops, pre-check force option
    if (widget.device.unsyncedOps > 0) {
      _force = true;
    }
  }

  @override
  void dispose() {
    _cashController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cashText = _cashController.text.trim();
    double? physicalCash;
    if (cashText.isNotEmpty) {
      physicalCash = double.tryParse(cashText);
      if (physicalCash == null || physicalCash < 0) {
        setState(() => _errorMessage = 'ยอดเงินสดต้องเป็นตัวเลขที่ถูกต้องและไม่ติดลบ');
        return;
      }
    }

    if (_force && _noteController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'กรุณาระบุเหตุผลในการบังคับปลดเครื่อง');
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final repo = context.read<DevicesRepository>();
      await repo.retireDevice(
        deviceId: widget.device.id,
        physicalCash: physicalCash,
        force: _force ? true : null,
        note: _force ? _noteController.text.trim() : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final msg = ServerErrorResolver.resolveCounterError(e);
      setState(() {
        _busy = false;
        _errorMessage = msg;
        // If server complained about unsynced ops, enable force toggle
        if (msg.contains('ค้างส่ง') || e.toString().contains('DEVICE_HAS_UNSYNCED_OPS')) {
          _force = true;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.error),
          const SizedBox(width: 10),
          Text('ปลดระวางเครื่อง #${device.deviceNo.toString().padLeft(2, '0')}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'คุณแน่ใจหรือไม่ว่าต้องการปลดระวางเครื่อง "${device.label}"?',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'เมื่อปลดระวางแล้ว เครื่องนี้จะไม่สามารถเข้าสู่ระบบหรือทำรายการขายได้อีก '
                'หากต้องการเชื่อมต่อใหม่ในอนาคต จะต้องออกรหัสผูกเครื่องใหม่และได้เลขเครื่องใหม่ (กฎ F8)',
                style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
              ),
              const SizedBox(height: 16),

              // If POS device, prompt for physical cash in case drawer is open
              if (device.isPos) ...[
                AppTextField.numeric(
                  label: 'ยอดเงินสดนับจริงในลิ้นชัก (บาท)',
                  hint: 'กรอกเฉพาะกรณีมีกะเปิดค้างอยู่บนเครื่องนี้',
                  controller: _cashController,
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
              ],

              // Warning and Force Retire option
              if (device.unsyncedOps > 0 || _force) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.error_outline, color: AppColors.error, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              device.unsyncedOps > 0
                                  ? 'เครื่องนี้ยังมีรายการขายค้างส่ง ${device.unsyncedOps} รายการ'
                                  : 'บังคับปลดระวางเครื่อง (Force Retire)',
                              style: const TextStyle(
                                color: AppColors.error,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'หากไม่สามารถต่อเน็ตเพื่อส่งรายการค้างได้ สามารถเลือก "บังคับปลดเครื่อง" '
                        'ระบบจะปิดเครื่องและส่งเรื่องไปยังหน้า "รอเจ้าของตรวจสอบ" (Review Items)',
                        style: TextStyle(fontSize: 12, height: 1.4),
                      ),
                      InkWell(
                        onTap: _busy ? null : () => setState(() => _force = !_force),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Checkbox(
                                value: _force,
                                onChanged: _busy ? null : (v) => setState(() => _force = v ?? false),
                                activeColor: AppColors.error,
                              ),
                              const SizedBox(width: 4),
                              const Expanded(
                                child: Text(
                                  'ยืนยันบังคับปลดเครื่องแม้มีรายการค้าง',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_force)
                        AppTextField(
                          label: 'เหตุผลในการบังคับปลดเครื่อง (จำเป็น)',
                          hint: 'เช่น เครื่องเสียหายเปิดไม่ติด, ลงวินโดว์ใหม่',
                          controller: _noteController,
                          enabled: !_busy,
                        ),
                    ],
                  ),
                ),
              ],

              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.error, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: AppColors.error, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'กำลังปลดเครื่อง...' : 'ยืนยันปลดระวางเครื่อง'),
        ),
      ],
    );
  }
}
