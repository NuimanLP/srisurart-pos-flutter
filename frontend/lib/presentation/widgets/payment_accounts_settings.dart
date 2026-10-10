// Settings → "บัญชีรับเงิน QR" (owner request 2026-10-10, contract §5).
//
// Lists up to [maxPaymentAccounts] QR payment accounts; the owner adds / edits
// them in a dialog (ชื่อเล่น, ธนาคาร, ชนิด พร้อมเพย์ / รูป QR, the PromptPay
// number or an image picked with file_picker and shrunk by [shrinkQrImage]),
// sets the default and deletes (confirmed). Everyone else sees the list
// read-only with the reason. Owned by SettingsScreen (CONTRACT.md §5).

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/backup_pick_options.dart';
import '../../core/utils/qr_image.dart';
import '../../data/db/database.dart';
import '../../data/repositories/payment_accounts_repository.dart';
import '../blocs/auth_cubit.dart';
import 'app_button.dart';
import 'app_card.dart';
import 'confirm_dialog.dart';
import 'sync_status_builder.dart';

/// The section body (not scrollable itself — the settings pane scrolls).
class PaymentAccountsSection extends StatefulWidget {
  const PaymentAccountsSection({super.key});

  @override
  State<PaymentAccountsSection> createState() => _PaymentAccountsSectionState();
}

class _PaymentAccountsSectionState extends State<PaymentAccountsSection> {
  late Future<List<PaymentAccountRow>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = context.read<PaymentAccountsRepository>().getLatestAccounts();
  }

  void _reload() => setState(() {
    _future = context.read<PaymentAccountsRepository>().getAccounts();
  });

  bool _canEdit(PaymentAccountsRepository repo) {
    if (!repo.ownerOnly) return true;
    final s = context.watch<AuthCubit>().state;
    return s is Authenticated && s.user.role == 'owner';
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _showError(_msg(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  void _showError(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _openDialog(
    List<PaymentAccountRow> accounts, [
    PaymentAccountRow? existing,
  ]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => PaymentAccountDialog(
        repository: context.read<PaymentAccountsRepository>(),
        existing: existing,
        firstAccount: accounts.isEmpty,
      ),
    );
    if (saved == true && mounted) _reload();
  }

  Future<void> _delete(PaymentAccountRow a) async {
    final ok = await showConfirm(
      context,
      'ลบบัญชีรับเงิน?', // agent ร่าง
      'ลบ "${a.nickname}" ออกจากรายการ บิลเก่าที่รับเงินเข้าบัญชีนี้ยังแสดงในรายงานเป็น "บัญชีที่ลบแล้ว"', // agent ร่าง
      danger: true,
      confirmLabel: 'ลบ',
    );
    if (!ok || !mounted) return;
    final repo = context.read<PaymentAccountsRepository>();
    setState(() => _busy = true);
    try {
      await repo.deleteAccount(a.id);
    } catch (e) {
      if (mounted) _showError(_msg(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<PaymentAccountsRepository>();
    final canEdit = _canEdit(repo);
    final theme = Theme.of(context);
    return SyncStatusBuilder(
      builder: (context, status, isDegraded) {
        // Online-only writes exist on the API build alone.
        final offline = repo.ownerOnly && isDegraded;
        final enabled = canEdit && !offline && !_busy;
        return FutureBuilder<List<PaymentAccountRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final accounts = snap.data ?? const <PaymentAccountRow>[];
            final full = accounts.length >= maxPaymentAccounts;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!canEdit)
                  const _Notice(
                    icon: Icons.lock_outline,
                    text: paymentAccountOwnerOnlyMessage,
                  ),
                if (canEdit && offline)
                  const _Notice(
                    icon: Icons.cloud_off,
                    text: paymentAccountsOfflineRefusal,
                  ),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Text(
                            'บัญชีรับเงิน ${accounts.length}/$maxPaymentAccounts', // agent ร่าง
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (canEdit)
                            AppButton(
                              label: '+ เพิ่มบัญชี', // agent ร่าง
                              onPressed: enabled && !full
                                  ? () => _openDialog(accounts)
                                  : null,
                            ),
                        ],
                      ),
                      if (canEdit && full)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            paymentAccountLimitMessage,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      if (accounts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'ยังไม่มีบัญชีรับเงิน QR', // agent ร่าง
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      for (final a in accounts)
                        _AccountTile(
                          account: a,
                          canEdit: canEdit,
                          enabled: enabled,
                          onSetDefault: () => _run(() => repo.setDefault(a.id)),
                          onEdit: () => _openDialog(accounts, a),
                          onDelete: () => _delete(a),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

/// `KBANK · กสิกรไทย` → the neutral-dot bank label (no logos — trademarks).
class BankLabel extends StatelessWidget {
  const BankLabel(this.bankCode, {super.key, this.style});
  final String bankCode;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: AppColors.gray400,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            bankName(bankCode),
            style: style,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.canEdit,
    required this.enabled,
    required this.onSetDefault,
    required this.onEdit,
    required this.onDelete,
  });

  final PaymentAccountRow account;
  final bool canEdit;
  final bool enabled;
  final VoidCallback onSetDefault;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = account;
    final detail = a.kind == 'promptpay'
        ? 'พร้อมเพย์ ${a.promptpayId ?? ''}' // agent ร่าง
        : 'รูป QR'; // agent ร่าง
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: a.isDefault ? AppColors.orange : theme.dividerColor,
          width: a.isDefault ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      a.nickname,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (a.isDefault)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'ค่าเริ่มต้น', // agent ร่าง
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.orange,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                BankLabel(a.bankCode, style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (canEdit)
            Wrap(
              spacing: 4,
              children: [
                if (!a.isDefault)
                  TextButton(
                    onPressed: enabled ? onSetDefault : null,
                    child: const Text('ตั้งเป็นค่าเริ่มต้น'), // agent ร่าง
                  ),
                TextButton(
                  onPressed: enabled ? onEdit : null,
                  child: const Text('แก้ไข'),
                ),
                TextButton(
                  onPressed: enabled ? onDelete : null,
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  child: const Text('ลบ'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Add / edit one account. Saves through [repository] itself, so a refusal
/// (limit, offline, server verdict) is shown inside the dialog and the
/// entered values stay; pops `true` once saved.
class PaymentAccountDialog extends StatefulWidget {
  const PaymentAccountDialog({
    super.key,
    required this.repository,
    this.existing,
    this.firstAccount = false,
  });

  final PaymentAccountsRepository repository;
  final PaymentAccountRow? existing;

  /// No account exists yet: the new one starts as the default.
  final bool firstAccount;

  @override
  State<PaymentAccountDialog> createState() => _PaymentAccountDialogState();
}

class _PaymentAccountDialogState extends State<PaymentAccountDialog> {
  late final TextEditingController _nickname;
  late final TextEditingController _promptpay;
  late String _bank;
  late String _kind;
  late bool _isDefault;
  Uint8List? _image;
  String? _imageMime;
  bool _imageChanged = false;
  String? _error;
  bool _saving = false;
  bool _picking = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nickname = TextEditingController(text: e?.nickname ?? '');
    _promptpay = TextEditingController(text: e?.promptpayId ?? '');
    _bank = e?.bankCode ?? 'KBANK';
    _kind = e?.kind ?? 'promptpay';
    _isDefault = e?.isDefault ?? widget.firstAccount;
    _image = e?.image;
    _imageMime = e?.imageMime;
  }

  @override
  void dispose() {
    _nickname.dispose();
    _promptpay.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      // First await: on the web the picker must open inside the tap.
      final file = await FilePicker.pickFile(
        type: FileType.image,
        webOptions: backupPickWebOptions,
      );
      if (file == null) return;
      final shrunk = await shrinkQrImage(await file.readAsBytes());
      if (!mounted) return;
      setState(() {
        _image = shrunk;
        _imageMime = 'image/png';
        _imageChanged = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    final promptpayId = _kind == 'promptpay' ? _promptpay.text.trim() : null;
    final error = paymentAccountError(
      nickname: _nickname.text,
      bankCode: _bank,
      kind: _kind,
      promptpayId: promptpayId,
      image: _kind == 'image' ? _image : null,
      imageMime: _kind == 'image' ? _imageMime : null,
    );
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final e = widget.existing;
      if (e == null) {
        await widget.repository.addAccount(PaymentAccountInput(
          nickname: _nickname.text,
          bankCode: _bank,
          kind: _kind,
          promptpayId: promptpayId,
          image: _kind == 'image' ? _image : null,
          imageMime: _kind == 'image' ? _imageMime : null,
          isDefault: _isDefault,
        ));
      } else {
        await widget.repository.updateAccount(
          e.id,
          PaymentAccountsCompanion(
            nickname: Value(_nickname.text.trim()),
            bankCode: Value(_bank),
            promptpayId: _kind == 'promptpay'
                ? Value(promptpayId)
                : const Value.absent(),
            image: _imageChanged ? Value(_image) : const Value.absent(),
            imageMime:
                _imageChanged ? Value(_imageMime) : const Value.absent(),
            isDefault: _isDefault != e.isDefault
                ? Value(_isDefault)
                : const Value.absent(),
          ),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        _editing ? 'แก้ไขบัญชีรับเงิน' : 'เพิ่มบัญชีรับเงิน', // agent ร่าง
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nickname,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: 'ชื่อเล่น', // agent ร่าง
                  hintText: 'เช่น บัญชีร้าน', // agent ร่าง
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _bank,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'ธนาคาร'), // agent ร่าง
                items: [
                  for (final e in paymentAccountBanks.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _bank = v ?? _bank),
              ),
              const SizedBox(height: 16),
              Text('ชนิด', style: theme.textTheme.labelLarge), // agent ร่าง
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final (kind, label) in const [
                    ('promptpay', 'พร้อมเพย์'), // agent ร่าง
                    ('image', 'รูป QR'), // agent ร่าง
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _kind == kind,
                      onSelected: _editing
                          ? null
                          : (_) => setState(() {
                              _kind = kind;
                              _error = null;
                            }),
                    ),
                ],
              ),
              if (_editing)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'เปลี่ยนชนิดไม่ได้ — ถ้าต้องการ ให้ลบแล้วเพิ่มใหม่', // agent ร่าง
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              if (_kind == 'promptpay')
                TextField(
                  controller: _promptpay,
                  keyboardType: TextInputType.number,
                  maxLength: 15,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'หมายเลขพร้อมเพย์', // agent ร่าง
                    helperText:
                        'เบอร์มือถือ 10 หลัก / เลขประจำตัว 13 หลัก / e-Wallet 15 หลัก', // agent ร่าง
                    helperMaxLines: 2,
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_image != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Image.memory(_image!, height: 160),
                      ),
                    OutlinedButton.icon(
                      onPressed: _picking || _saving ? null : _pickImage,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(
                        _image == null ? 'เลือกรูป QR' : 'เปลี่ยนรูป QR', // agent ร่าง
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _isDefault,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('ตั้งเป็นค่าเริ่มต้น'), // agent ร่าง
                onChanged: (v) => setState(() => _isDefault = v ?? false),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AppColors.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('ยกเลิก'),
        ),
        FilledButton(
          onPressed: _saving || _picking ? null : _save,
          child: const Text('บันทึก'),
        ),
      ],
    );
  }
}
