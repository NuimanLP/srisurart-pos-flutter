// SettingsScreen — Settings hub (ported from pos/SettingsScreen.jsx + ExportCSV.jsx).
//
// Sub-tabs:
//   ⚙ ทั่วไป       — shop info form → SettingsRepository.updateSettings
//   🎨 ธีม          — dark/light toggle via ThemeModeCubit
//   💾 สำรอง/กู้คืน — backup (snapshotRepo.exportSnapshot → .json file) /
//                     restore (importLegacyBackup; reload after)
//   📤 ส่งออก CSV   — sales summary / sales detail / inventory CSV exporters
//                     (ALWAYS via csvSafe), ported from ExportCSV.jsx.
//
// File save: no file_picker / share_plus dep is available. On native, exports are
// written to the app documents directory and the saved path is shown to the user;
// on the web a browser download is triggered (see core/utils/file_export.dart).
// Restore file-pick is deferred (no native picker) — a manual JSON paste dialog
// is provided as a wired fallback (see _RestorePasteDialog).

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/csv_safe.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/file_export.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/customers_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/snapshot_repository.dart';
import '../../data/repositories/suppliers_repository.dart';
import '../../domain/models/aggregates.dart';
import '../blocs/auth_cubit.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';
import '../widgets/device_enrolment_dialog.dart';
import '../widgets/font_scale_controller.dart';
import '../widgets/login_dialog.dart';
import '../widgets/thai_format.dart';
import '../widgets/theme_controller.dart';

// Week-boundary key (today − 7d, yyyy-MM-dd) — matches the db.js slice.
// todayKey()/monthKey() come from core/utils/dates.dart.
String _weekStr() => dateKey(DateTime.now().subtract(const Duration(days: 7)));

/// "File saved" dialog shared by the backup + CSV export tabs. [path] is null
/// on the web (the browser handled the download); native shows the saved
/// filesystem path with a copy-to-clipboard action.
Future<void> _showSavedFileDialog(
  BuildContext context, {
  required String title,
  required String? path,
  required String filename,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: path == null
            ? [
                Text('ดาวน์โหลดไฟล์ "$filename" แล้ว'),
                const SizedBox(height: 8),
                const Text(
                  'ดูในโฟลเดอร์ดาวน์โหลดของเบราว์เซอร์',
                  style: TextStyle(fontSize: 12),
                ),
              ]
            : [
                const Text('บันทึกไฟล์ไว้ที่:'),
                const SizedBox(height: 8),
                SelectableText(
                  path,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
      ),
      actions: [
        if (path != null)
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: path)),
            child: const Text('คัดลอกที่อยู่'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('ตกลง'),
        ),
      ],
    ),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // [key, label] — matches JS TABS + account tab for device enrolment & auth.
  static const _tabs = [
    ['general', '⚙ ทั่วไป'],
    ['account', '🔐 บัญชี / ผูกเครื่อง'],
    ['theme', '🎨 ธีม'],
    ['backup', '💾 สำรอง/กู้คืน'],
    ['export', '📤 ส่งออก CSV'],
  ];

  String _subTab = 'general';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Tab bar ──
          Material(
            color: theme.colorScheme.surface,
            child: Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final t in _tabs)
                      _TabButton(
                        label: t[1],
                        active: _subTab == t[0],
                        onTap: () => setState(() => _subTab = t[0]),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // ── Content ──
          Expanded(
            child: switch (_subTab) {
              'general' => const _GeneralTab(),
              'account' => const _AccountTab(),
              'theme' => const _ThemeTab(),
              'backup' => const _BackupTab(),
              'export' => const _ExportTab(),
              _ => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? AppColors.orange : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: active
                ? theme.colorScheme.onSurface
                : theme.colorScheme.secondary,
          ),
        ),
      ),
    );
  }
}

// Shared content scroll wrapper (maxWidth 820, padding) — matches stS.content.
class _ContentPane extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _ContentPane({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: theme.dividerColor),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// ACCOUNT & DEVICE ENROLMENT (ADR-0004)
// ════════════════════════════════════════════════════════════════════════

class _AccountTab extends StatelessWidget {
  const _AccountTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authState = context.watch<AuthCubit>().state;
    final cubit = context.read<AuthCubit>();

    final user = authState is Authenticated ? authState.user : null;
    final isAuthed = user != null;
    final deviceToken = authState is Authenticated
        ? authState.deviceToken
        : (authState is Unauthenticated ? authState.deviceToken : null);
    final isPos = authState is Authenticated
        ? authState.isPos
        : (authState is Unauthenticated ? authState.isPos : false);

    return _ContentPane(
      title: '🔐 บัญชีผู้ใช้และการผูกเครื่อง (Auth & Device)',
      children: [
        // ── 1. User Account ──
        const _SectionTitle('ข้อมูลผู้ใช้งาน (User Account)'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: isAuthed
                        ? AppColors.orange.withValues(alpha: 0.15)
                        : Colors.grey.withValues(alpha: 0.15),
                    child: Icon(
                      isAuthed ? Icons.person : Icons.person_outline,
                      color: isAuthed ? AppColors.orange : Colors.grey,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              isAuthed
                                  ? (user.displayName ?? user.username)
                                  : 'ยังไม่ได้เข้าสู่ระบบ',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isAuthed
                                    ? AppColors.success.withValues(alpha: 0.1)
                                    : Colors.grey.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isAuthed
                                    ? 'บทบาท: ${user.role}'
                                    : 'โหมดออฟไลน์ / แขก',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: isAuthed
                                      ? AppColors.success
                                      : Colors.grey[700],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isAuthed
                              ? 'Username: @${user.username}'
                              : 'ระบบทำงานในโหมด Offline-first ด้วยฐานข้อมูลภายในเครื่อง',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (isAuthed)
                    AppButton.secondary(
                      label: 'ออกจากระบบ',
                      icon: Icons.logout,
                      onPressed: () => cubit.logout(),
                    )
                  else
                    AppButton(
                      label: 'เข้าสู่ระบบ',
                      icon: Icons.login,
                      onPressed: () => LoginDialog.show(context),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // ── 2. Device Role & Enrolment ──
        const _SectionTitle('บทบาทและการผูกเครื่อง (Device Role — ADR-0004)'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ตามกติกา ADR-0004 แต่ละร้านค้าจะมีเครื่อง POS สำหรับขายของและบันทึกเงินสดหน้าร้านได้ 1 เครื่อง เครื่องอื่นจะเป็นโหมด Backoffice สำหรับจัดการสต็อกและเอกสาร',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isPos
                      ? AppColors.success.withValues(alpha: 0.08)
                      : (deviceToken != null
                          ? AppColors.navy.withValues(alpha: 0.08)
                          : Colors.grey.withValues(alpha: 0.08)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isPos
                        ? AppColors.success.withValues(alpha: 0.3)
                        : (deviceToken != null
                            ? AppColors.navy.withValues(alpha: 0.3)
                            : Colors.grey.withValues(alpha: 0.3)),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isPos
                          ? Icons.check_circle
                          : (deviceToken != null
                              ? Icons.computer
                              : Icons.warning_amber_rounded),
                      color: isPos
                          ? AppColors.success
                          : (deviceToken != null
                              ? AppColors.navy
                              : Colors.orange[800]),
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isPos
                                ? 'เครื่องนี้คือเครื่อง POS หน้าร้าน (POS Terminal)'
                                : (deviceToken != null
                                    ? 'เครื่องนี้คือ Backoffice Terminal'
                                    : 'เครื่องนี้ยังไม่ได้ผูกกับระบบ (โหมดทั่วไป)'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            deviceToken != null
                                ? 'Device Token: ${deviceToken.substring(0, deviceToken.length > 16 ? 16 : deviceToken.length)}...'
                                : 'ยังไม่มี Device Token ในเบราว์เซอร์นี้',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (deviceToken != null)
                      AppButton.danger(
                        label: 'ยกเลิกการผูกเครื่อง',
                        icon: Icons.link_off,
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('ยืนยันยกเลิกการผูกเครื่อง'),
                              content: const Text(
                                'หากยกเลิกการผูกเครื่องนี้ สิทธิ์ของเครื่อง POS จะถูกถอนออก และต้องให้เจ้าของร้านออกรหัสผูกเครื่องใหม่หากต้องการเชื่อมต่ออีกครั้ง',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: const Text('ยกเลิก'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppColors.error,
                                  ),
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('ยืนยันถอนการผูกเครื่อง'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await cubit.clearDeviceEnrolment();
                          }
                        },
                      )
                    else
                      AppButton(
                        label: 'ผูกเครื่องขาย (POS)',
                        icon: Icons.qr_code_scanner,
                        onPressed: () => DeviceEnrolmentDialog.show(context),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// GENERAL — shop info form
// ════════════════════════════════════════════════════════════════════════

class _GeneralTab extends StatefulWidget {
  const _GeneralTab();
  @override
  State<_GeneralTab> createState() => _GeneralTabState();
}

class _GeneralTabState extends State<_GeneralTab> {
  final _shopName = TextEditingController();
  final _shopNameEN = TextEditingController();
  final _phone = TextEditingController();
  final _cashierName = TextEditingController();
  final _address = TextEditingController();
  final _taxRate = TextEditingController();
  final _quoteValidDays = TextEditingController();

  bool _loaded = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await context.read<SettingsRepository>().getSettings();
    if (!mounted) return;
    _shopName.text = s.shopName;
    _shopNameEN.text = s.shopNameEN;
    _phone.text = s.phone ?? '';
    _cashierName.text = s.cashierName ?? '';
    _address.text = s.address ?? '';
    _taxRate.text = _trimNum(s.taxRate);
    _quoteValidDays.text = s.quoteValidDays.toString();
    setState(() => _loaded = true);
  }

  static String _trimNum(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _shopName.dispose();
    _shopNameEN.dispose();
    _phone.dispose();
    _cashierName.dispose();
    _address.dispose();
    _taxRate.dispose();
    _quoteValidDays.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final taxRate = double.tryParse(_taxRate.text.trim()) ?? 7;
    final validDays = int.tryParse(_quoteValidDays.text.trim()) ?? 30;
    await context.read<SettingsRepository>().updateSettings(
      SettingsRowCompanion(
        shopName: Value(_shopName.text),
        shopNameEN: Value(_shopNameEN.text),
        phone: Value(_phone.text.isEmpty ? null : _phone.text),
        cashierName: Value(
          _cashierName.text.isEmpty ? null : _cashierName.text,
        ),
        address: Value(_address.text.isEmpty ? null : _address.text),
        taxRate: Value(taxRate),
        quoteValidDays: Value(validDays),
      ),
    );
    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    return _ContentPane(
      title: 'ข้อมูลร้านค้า · Shop Information',
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionTitle('ชื่อและที่อยู่'),
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoCol = constraints.maxWidth > 480;
                  final fieldW = twoCol
                      ? (constraints.maxWidth - 14) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      SizedBox(
                        width: fieldW,
                        child: AppTextField(
                          label: 'ชื่อร้าน (TH)',
                          controller: _shopName,
                        ),
                      ),
                      SizedBox(
                        width: fieldW,
                        child: AppTextField(
                          label: 'ชื่อร้าน (EN)',
                          controller: _shopNameEN,
                        ),
                      ),
                      SizedBox(
                        width: fieldW,
                        child: AppTextField(
                          label: 'เบอร์โทร',
                          controller: _phone,
                        ),
                      ),
                      SizedBox(
                        width: fieldW,
                        child: AppTextField(
                          label: 'ชื่อแคชเชียร์ (default)',
                          controller: _cashierName,
                        ),
                      ),
                      SizedBox(
                        width: constraints.maxWidth,
                        child: AppTextField(
                          label: 'ที่อยู่',
                          controller: _address,
                        ),
                      ),
                      SizedBox(
                        width: fieldW,
                        child: AppTextField.numeric(
                          label: 'VAT (%)',
                          controller: _taxRate,
                        ),
                      ),
                      SizedBox(
                        width: fieldW,
                        child: AppTextField.numeric(
                          label: 'ใบเสนอราคา · มีอายุ (วัน)',
                          controller: _quoteValidDays,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  AppButton(label: 'บันทึกการตั้งค่า', onPressed: _save),
                  const SizedBox(width: 12),
                  if (_saved)
                    Text(
                      '✓ บันทึกแล้ว',
                      style: TextStyle(
                        color: AppColors.successLight,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// THEME — dark / light selector + font scale multiplier
// ════════════════════════════════════════════════════════════════════════

class _ThemeTab extends StatelessWidget {
  const _ThemeTab();

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<ThemeModeCubit>().state;
    final isDark = mode == ThemeMode.dark;
    final cards = [
      _ThemeCardData(
        mode: ThemeMode.dark,
        label: '🌙 Dark Mode',
        desc: 'พื้นหลังมืด เหมาะสำหรับแสงน้อย',
        bg: const Color(0xFF0B2444),
        fg: const Color(0xFFFFFFFF),
        active: isDark,
      ),
      _ThemeCardData(
        mode: ThemeMode.light,
        label: '☀️ Light Mode',
        desc: 'พื้นหลังสว่าง อ่านง่ายสำหรับผู้สูงอายุ',
        bg: const Color(0xFFFFFBF2),
        fg: const Color(0xFF0B2444),
        active: !isDark,
      ),
    ];
    return _ContentPane(
      title: 'ธีมการแสดงผล · Display Theme',
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = (constraints.maxWidth - 16) / 2;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final c in cards)
                    SizedBox(
                      width: w,
                      child: _ThemeCard(
                        data: c,
                        onTap: () => context.read<ThemeModeCubit>().set(c.mode),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 32),
        // ── Font scale section ──
        const _FontScaleSection(),
      ],
    );
  }
}

class _ThemeCardData {
  final ThemeMode mode;
  final String label;
  final String desc;
  final Color bg;
  final Color fg;
  final bool active;
  _ThemeCardData({
    required this.mode,
    required this.label,
    required this.desc,
    required this.bg,
    required this.fg,
    required this.active,
  });
}

class _ThemeCard extends StatelessWidget {
  final _ThemeCardData data;
  final VoidCallback onTap;
  const _ThemeCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: data.active
              ? AppColors.orange.withValues(alpha: 0.08)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: data.active ? AppColors.orange : theme.dividerColor,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 70,
              decoration: BoxDecoration(
                color: data.bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.black.withValues(alpha: 0.1)),
              ),
              alignment: Alignment.center,
              child: Text(
                'PREVIEW',
                style: TextStyle(
                  color: data.fg,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              data.label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              data.desc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.secondary,
                height: 1.5,
              ),
            ),
            if (data.active) ...[
              const SizedBox(height: 6),
              Text(
                '✓ ใช้งานอยู่',
                style: TextStyle(
                  color: AppColors.orange,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Font scale preset cards + slider + preview ──
class _FontScaleSection extends StatelessWidget {
  const _FontScaleSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentScale = context.watch<FontScaleCubit>().state;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('ขนาดตัวอักษร · Font Size'),
          const SizedBox(height: 4),
          // ── Preset cards ──
          LayoutBuilder(
            builder: (context, constraints) {
              final presets = fontScalePresets;
              const gap = 10.0;
              final w =
                  (constraints.maxWidth - gap * (presets.length - 1)) /
                  presets.length;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final p in presets)
                    SizedBox(
                      width: w,
                      child: _FontScalePresetCard(
                        preset: p,
                        active: (currentScale - p.value).abs() < 0.01,
                        onTap: () =>
                            context.read<FontScaleCubit>().setScale(p.value),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          // ── Slider ──
          Row(
            children: [
              Icon(
                Icons.text_decrease,
                size: 20,
                color: theme.colorScheme.secondary,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: AppColors.orange,
                    inactiveTrackColor: AppColors.orange.withValues(alpha: 0.2),
                    thumbColor: AppColors.orange,
                    overlayColor: AppColors.orange.withValues(alpha: 0.12),
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 10,
                    ),
                  ),
                  child: Slider(
                    value: currentScale.clamp(0.85, 1.25),
                    min: 0.85,
                    max: 1.25,
                    divisions: 8, // (1.25 - 0.85) / 0.05 = 8
                    onChanged: (v) {
                      // Round to 2 decimal places for clean display
                      final rounded =
                          (v * 20).round() / 20; // snap to 0.05 steps
                      context.read<FontScaleCubit>().setScale(rounded);
                    },
                  ),
                ),
              ),
              Icon(
                Icons.text_increase,
                size: 20,
                color: theme.colorScheme.secondary,
              ),
            ],
          ),
          // ── Scale label ──
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.orange.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                '${currentScale.toStringAsFixed(2)}x',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: AppColors.orange,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // ── Live preview box ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.preview,
                      size: 16,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'ตัวอย่าง · Preview',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'ศรีสุรัตน์ ออโต้พาร์ท',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Srisurart Autopart POS',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'น้ำมันเครื่อง 10W-40',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '฿1,250.00',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppColors.orange,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'สต็อก: 24 ชิ้น · หมวดหมู่: น้ำมัน',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
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

class _FontScalePresetCard extends StatelessWidget {
  final FontScalePreset preset;
  final bool active;
  final VoidCallback onTap;
  const _FontScalePresetCard({
    required this.preset,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: active
              ? AppColors.orange.withValues(alpha: 0.1)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? AppColors.orange : theme.dividerColor,
            width: active ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              preset.icon,
              size: 22,
              color: active ? AppColors.orange : theme.colorScheme.secondary,
            ),
            const SizedBox(height: 6),
            Text(
              preset.label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: active ? AppColors.orange : theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              '${preset.value}x',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                color: active ? AppColors.orange : theme.colorScheme.secondary,
                letterSpacing: 0.5,
              ),
            ),
            if (active) ...[
              const SizedBox(height: 4),
              Text(
                '✓',
                style: TextStyle(
                  color: AppColors.orange,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// BACKUP / RESTORE
// ════════════════════════════════════════════════════════════════════════

class _BackupTab extends StatefulWidget {
  const _BackupTab();
  @override
  State<_BackupTab> createState() => _BackupTabState();
}

class _BackupTabState extends State<_BackupTab> {
  String _mode = 'backup'; // backup | restore

  Map<String, dynamic>? _snapshot; // current export (for record counts)
  bool _loading = true;

  // restore state
  Map<String, dynamic>? _preview; // parsed/validated file ready to restore
  bool _confirmRestore = false;
  String? _restoreStatus; // success | error
  String _restoreMsg = '';

  @override
  void initState() {
    super.initState();
    _loadSnapshot();
  }

  Future<void> _loadSnapshot() async {
    final snap = await context.read<SnapshotRepository>().exportSnapshot();
    if (!mounted) return;
    setState(() {
      _snapshot = snap;
      _loading = false;
    });
  }

  // ── EXPORT ──────────────────────────────────────────────────────────────
  Future<void> _handleExport() async {
    try {
      final data = await context.read<SnapshotRepository>().exportSnapshot();
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final fileName = 'pos-backup-${todayKey().replaceAll('-', '')}.json';
      final path = await exportTextFile(filename: fileName, content: json);
      if (!mounted) return;
      await _showSavedFileDialog(
        context,
        title: 'ดาวน์โหลดไฟล์ backup สำเร็จ',
        path: path,
        filename: fileName,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('เกิดข้อผิดพลาด: $e')));
    }
  }

  // ── RESTORE: pick (paste) → validate → preview → confirm ───────────────
  Future<void> _pickFile() async {
    // No native file picker dependency is available on this machine. Offer a
    // manual JSON-paste dialog as a wired fallback (deferred: native picker).
    final pasted = await showDialog<String>(
      context: context,
      builder: (ctx) => const _RestorePasteDialog(),
    );
    if (pasted == null || pasted.trim().isEmpty) return;
    _validateBackup(pasted);
  }

  // Port of handleFileSelect's validation (db.js / SettingsScreen.jsx).
  void _validateBackup(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw Exception('ไฟล์ว่างเปล่า — ไม่มีข้อมูลสินค้าหรือยอดขาย');
      }
      final data = decoded.cast<String, dynamic>();
      final meta = data['__meta'];
      if (meta == null || meta is! Map) {
        throw Exception('ไม่พบข้อมูล meta — ไฟล์ไม่ถูกต้อง');
      }
      final version = meta['version'];
      if (version is! num) {
        throw Exception('ไม่พบ version ในไฟล์');
      }
      if (version > 2) {
        throw Exception(
          'ไฟล์เวอร์ชัน $version ใหม่กว่าที่ระบบรองรับ — กรุณาอัพเดทระบบ',
        );
      }
      if (data['sa_products'] == null && data['sa_sales'] == null) {
        throw Exception('ไฟล์ว่างเปล่า — ไม่มีข้อมูลสินค้าหรือยอดขาย');
      }
      setState(() {
        _preview = data;
        _confirmRestore = false;
        _restoreStatus = null;
        _restoreMsg = '';
      });
    } catch (err) {
      setState(() {
        _preview = null;
        _restoreStatus = 'error';
        _restoreMsg = 'ไม่สามารถอ่านไฟล์ได้: ${_msg(err)}';
      });
    }
  }

  static String _msg(Object e) =>
      e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';

  Future<void> _handleRestore() async {
    final data = _preview;
    if (data == null) return;
    try {
      await context.read<SnapshotRepository>().importLegacyBackup(data);
      if (!mounted) return;
      setState(() {
        _restoreStatus = 'success';
        _restoreMsg = 'นำเข้าข้อมูลสำเร็จ — กำลังโหลดหน้าใหม่…';
        _confirmRestore = false;
      });
      // Reload the snapshot record counts so the new dataset is reflected.
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      await _loadSnapshot();
      if (!mounted) return;
      setState(() => _preview = null);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _restoreStatus = 'error';
        _restoreMsg = 'เกิดข้อผิดพลาด: ${_msg(err)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final meta = (_snapshot?['__meta'] as Map?)?.cast<String, dynamic>() ?? {};
    final counts =
        (meta['recordCounts'] as Map?)?.cast<String, dynamic>() ?? {};
    return _ContentPane(
      title: 'สำรอง / กู้คืนข้อมูล · Backup & Restore',
      children: [
        // sub-tab bar
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              _SubTabBtn(
                label: '💾 สำรองข้อมูล',
                active: _mode == 'backup',
                onTap: () => setState(() => _mode = 'backup'),
              ),
              const SizedBox(width: 4),
              _SubTabBtn(
                label: '📥 กู้คืนข้อมูล',
                active: _mode == 'restore',
                onTap: () => setState(() => _mode = 'restore'),
              ),
            ],
          ),
        ),
        if (_mode == 'backup') ..._backupView(counts),
        if (_mode == 'restore') ..._restoreView(),
      ],
    );
  }

  List<Widget> _backupView(Map<String, dynamic> counts) {
    return [
      const _InfoBox(
        text:
            '💡 ข้อมูลทั้งหมดเก็บในเครื่อง หากล้างข้อมูลหรือเปลี่ยนเครื่อง ข้อมูลจะหาย แนะนำสำรองทุกสัปดาห์',
      ),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionTitle('ข้อมูลปัจจุบัน'),
            _RecordGrid(counts: counts),
            const SizedBox(height: 20),
            Center(
              child: AppButton(
                label: '⬇ ดาวน์โหลดไฟล์ backup (.json)',
                onPressed: _handleExport,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _restoreView() {
    final pmeta =
        (_preview?['__meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final pcounts =
        (pmeta['recordCounts'] as Map?)?.cast<String, dynamic>() ?? const {};
    return [
      const _InfoBox(
        danger: true,
        text:
            '⚠️ การกู้คืนจะแทนที่ข้อมูลทั้งหมด — ตรวจสอบไฟล์ให้ถูกต้องก่อนกด "กู้คืน"',
      ),
      InkWell(
        onTap: _pickFile,
        child: AppCard(
          child: Column(
            children: [
              const SizedBox(height: 8),
              const Text('📁', style: TextStyle(fontSize: 36)),
              const SizedBox(height: 8),
              Text(
                'คลิกเพื่อเลือกไฟล์ backup',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'รองรับไฟล์ .json ที่ส่งออกจากระบบนี้เท่านั้น',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      if (_preview != null) ...[
        const SizedBox(height: 16),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionTitle('ข้อมูลในไฟล์ที่เลือก'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'ร้าน: ${pmeta['shopName'] ?? '—'} · สำรองเมื่อ: ${_fmtExportedAt(pmeta['exportedAt'])}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              _RecordGrid(counts: pcounts),
              const SizedBox(height: 16),
              if (!_confirmRestore)
                AppButton.danger(
                  label: '📥 กู้คืนข้อมูลจากไฟล์นี้',
                  fullWidth: true,
                  onPressed: () => setState(() => _confirmRestore = true),
                )
              else
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.error, width: 2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '⚠ ยืนยันการกู้คืน? ข้อมูลปัจจุบันจะถูกแทนที่',
                        style: TextStyle(
                          color: AppColors.error,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: AppButton.danger(
                              label: '✓ ยืนยัน',
                              onPressed: _handleRestore,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: AppButton.secondary(
                              label: 'ยกเลิก',
                              onPressed: () =>
                                  setState(() => _confirmRestore = false),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
      if (_restoreStatus == 'success') ...[
        const SizedBox(height: 12),
        _StatusBanner(success: true, message: _restoreMsg),
      ],
      if (_restoreStatus == 'error') ...[
        const SizedBox(height: 12),
        _StatusBanner(success: false, message: _restoreMsg),
      ],
    ];
  }

  String _fmtExportedAt(dynamic iso) {
    if (iso == null) return '—';
    final d = DateTime.tryParse(iso.toString());
    if (d == null) return '—';
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }
}

class _SubTabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _SubTabBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: active
                ? theme.colorScheme.onSurface
                : theme.colorScheme.secondary,
          ),
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final String text;
  final bool danger;
  const _InfoBox({required this.text, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.steelBlue;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: danger ? 0.08 : 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          height: 1.6,
          color: danger
              ? AppColors.error
              : Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}

// 3-column grid of record counts — matches RecordGrid in the JSX.
class _RecordGrid extends StatelessWidget {
  final Map<String, dynamic> counts;
  const _RecordGrid({required this.counts});

  int _n(String k) {
    final v = counts[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = <List<dynamic>>[
      ['📦 สินค้า', _n('products')],
      ['👤 ลูกค้า', _n('customers')],
      ['🧾 บิลขาย', _n('sales')],
      ['🛒 ใบสั่งซื้อ', _n('purchaseOrders')],
      ['🏭 ซัพพลายเออร์', _n('suppliers')],
      ['📋 สต็อก log', _n('movements')],
      ['🔧 ช่าง', _n('mechanics')],
      ['↻ คืนสินค้า', _n('returns')],
      ['💳 ชำระเครดิต', _n('creditPayments')],
      ['🏷 ประเภท', _n('categories')],
      ['💵 ลิ้นชัก', _n('cashDrawer')],
      ['📝 ใบเสนอราคา', _n('quotes')],
      ['⏸ บิลพัก', _n('parked')],
      ['📚 ประวัติกะ', _n('shiftHistory')],
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const cols = 3;
        const gap = 10.0;
        final w = (constraints.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final e in entries)
              SizedBox(
                width: w,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e[0] as String,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${e[1]}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final bool success;
  final String message;
  const _StatusBanner({required this.success, required this.message});

  @override
  Widget build(BuildContext context) {
    final color = success ? AppColors.successLight : AppColors.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Text(
        '${success ? '✓' : '✕'} $message',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );
  }
}

// Manual JSON paste dialog (file-pick fallback; native picker deferred).
class _RestorePasteDialog extends StatefulWidget {
  const _RestorePasteDialog();
  @override
  State<_RestorePasteDialog> createState() => _RestorePasteDialogState();
}

class _RestorePasteDialogState extends State<_RestorePasteDialog> {
  final _ctrl = TextEditingController();
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('วางข้อมูล backup (.json)'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ตัวเลือกไฟล์แบบ native ยังไม่รองรับ — วางเนื้อหาไฟล์ .json ที่นี่',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _ctrl,
              hint: '{ "__meta": { ... }, "sa_products": [ ... ] }',
              maxLines: 8,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ยกเลิก'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('ตรวจสอบไฟล์'),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// EXPORT CSV (ported from ExportCSV.jsx + SettingsScreen export sub-tab)
// ════════════════════════════════════════════════════════════════════════

class _ExportTab extends StatefulWidget {
  const _ExportTab();
  @override
  State<_ExportTab> createState() => _ExportTabState();
}

class _ExportTabState extends State<_ExportTab> {
  String _range = 'month'; // today | week | month | all | custom
  final _customStart = TextEditingController();
  final _customEnd = TextEditingController();
  String? _exported;

  // Loaded data
  bool _loading = true;
  List<SaleWithItems> _sales = const [];
  List<ProductRow> _products = const [];
  List<CustomerRow> _customers = const [];
  List<SupplierRow> _suppliers = const [];
  double _taxRate = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _customStart.dispose();
    _customEnd.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final salesRepo = context.read<SalesRepository>();
    final productsRepo = context.read<ProductsRepository>();
    final customersRepo = context.read<CustomersRepository>();
    final suppliersRepo = context.read<SuppliersRepository>();
    final settingsRepo = context.read<SettingsRepository>();
    final sales = await salesRepo.getSales();
    final products = await productsRepo.getAll();
    final customers = await customersRepo.getCustomers();
    final suppliers = await suppliersRepo.getSuppliers();
    final settings = await settingsRepo.getSettings();
    if (!mounted) return;
    setState(() {
      _sales = sales;
      _products = products;
      _customers = customers;
      _suppliers = suppliers;
      _taxRate = settings.taxRate;
      _loading = false;
    });
  }

  // db.js filteredSales — by selected range, using ISO yyyy-MM-dd slices.
  List<SaleWithItems> _filteredSales() {
    final today = todayKey();
    final month = monthKey();
    final week = _weekStr();
    final cs = _customStart.text.trim();
    final ce = _customEnd.text.trim();
    return _sales.where((sw) {
      final d = dateKey(sw.sale.date);
      switch (_range) {
        case 'today':
          return d == today;
        case 'week':
          return d.compareTo(week) >= 0;
        case 'month':
          return d.startsWith(month);
        case 'all':
          return true;
        case 'custom':
          return (cs.isEmpty || d.compareTo(cs) >= 0) &&
              (ce.isEmpty || d.compareTo(ce) <= 0);
        default:
          return true;
      }
    }).toList();
  }

  // ── CSV builder (BOM + csvSafe + quote-escape) — matches downloadCSV ──
  String _buildCsv(List<List<dynamic>> rows) {
    const bom = '﻿';
    final body = rows
        .map((r) {
          return r
              .map((cell) {
                final str = csvSafe(cell);
                if (str.contains(',') ||
                    str.contains('"') ||
                    str.contains('\n')) {
                  return '"${str.replaceAll('"', '""')}"';
                }
                return str;
              })
              .join(',');
        })
        .join('\r\n');
    return bom + body;
  }

  Future<void> _download(
    List<List<dynamic>> rows,
    String filename,
    String exportedKey,
  ) async {
    try {
      final csv = _buildCsv(rows);
      final path = await exportTextFile(filename: filename, content: csv);
      if (!mounted) return;
      setState(() => _exported = exportedKey);
      await _showSavedFileDialog(
        context,
        title: 'ดาวน์โหลดสำเร็จ',
        path: path,
        filename: filename,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('เกิดข้อผิดพลาด: $e')));
    }
  }

  // ── exportSalesSummary (one row per bill) ──
  Future<void> _exportSummary() async {
    final fs = _filteredSales();
    final custById = {for (final c in _customers) c.id: c};
    final header = [
      'เลขที่ใบเสร็จ',
      'วันที่',
      'เวลา',
      'จำนวนรายการ',
      'ยอดก่อนส่วนลด',
      'ส่วนลด',
      'ยอดรวม',
      'วิธีชำระ',
      'ลูกค้า',
      'เงินรับ',
      'เงินทอน',
    ];
    final rows = <List<dynamic>>[header];
    for (final sw in fs) {
      final s = sw.sale;
      final cust = s.customerId == null ? null : custById[s.customerId];
      final d = s.date;
      rows.add([
        s.receiptNo,
        thaiDateSlash(d),
        thaiTime(d),
        sw.items.length,
        s.subtotal,
        s.discount,
        s.total,
        s.paymentMethod,
        cust != null ? cust.nameTH : 'ลูกค้าทั่วไป',
        s.total, // cashReceived not persisted → fall back to total (db.js)
        0, // change not persisted → 0 (db.js)
      ]);
    }
    await _download(rows, 'sales-summary-${todayKey()}.csv', 'summary');
  }

  // ── exportSalesDetail (one row per item sold) ──
  //
  // PARITY RESTORED with pos/SettingsScreen.jsx exportSalesDetail (ADR-0008).
  // The JSX prefers the cost snapshotted on the line at sale time
  // (`item.cost ?? p?.cost ?? 0`); SaleItems now carries `costAtSale` (schema
  // v2) and saveSale writes it, so this export reads it first and only falls
  // back to the current product cost for older bills.
  //
  // The JSX `?? 0` tail is deliberately NOT reproduced: a line with no cost
  // anywhere leaves the cost cells empty rather than 0, because 0 reads as
  // 100% profit and is indistinguishable from a genuinely free item. The
  // trailing 'ที่มาของต้นทุน' column says which of the three cases each row is,
  // so the figure can be audited in Excel instead of trusted blindly.
  Future<void> _exportDetail() async {
    final fs = _filteredSales();
    final vatDivisor = 1 + _taxRate / 100;
    final prodByPart = {for (final p in _products) p.partNo: p};
    final header = [
      'เลขที่',
      'วันที่',
      'รหัสสินค้า',
      'ชื่อ (EN)',
      'ชื่อ (TH)',
      'ประเภท',
      'จำนวน',
      'ราคา/ชิ้น',
      'รวม',
      'ต้นทุน/ชิ้น',
      'ต้นทุนรวม',
      'กำไร (ไม่รวม VAT)',
      'วิธีชำระ',
      'ที่มาของต้นทุน',
    ];
    final rows = <List<dynamic>>[header];
    for (final sw in fs) {
      final s = sw.sale;
      final d = s.date;
      for (final item in sw.items) {
        final pr = item.partNo == null ? null : prodByPart[item.partNo];
        // Recorded cost wins; today's product cost is only a fallback for bills
        // written before schema v2. See the parity note above.
        final recordedCost = item.costAtSale;
        final unitCost = recordedCost ?? pr?.cost;
        final costSource = recordedCost != null
            ? 'ณ วันที่ขาย'
            : (pr != null ? 'ต้นทุนปัจจุบัน' : 'ไม่มีข้อมูล');
        final cost = unitCost == null ? null : unitCost * item.qty;
        final profit = cost == null
            ? null
            : (item.price / vatDivisor) * item.qty - cost;
        rows.add([
          s.receiptNo,
          thaiDateSlash(d),
          item.partNo ?? '',
          item.name,
          item.nameTH ?? pr?.nameTH ?? '',
          pr?.category ?? '',
          item.qty,
          item.price,
          item.price * item.qty,
          unitCost ?? '',
          cost ?? '',
          profit == null ? '' : (profit * 100).round() / 100,
          s.paymentMethod,
          costSource,
        ]);
      }
    }
    await _download(rows, 'sales-detail-${todayKey()}.csv', 'detail');
  }

  // ── exportInventory (current stock snapshot) ──
  Future<void> _exportInventory() async {
    final header = [
      'รหัสสินค้า',
      'ชื่อ (EN)',
      'ชื่อ (TH)',
      'ประเภท',
      'แบรนด์',
      'ใช้กับรถรุ่น',
      'ราคาขาย',
      'ราคาทุน',
      'สต็อก',
      'สต็อกขั้นต่ำ',
      'สถานะ',
      'ซัพพลายเออร์ถูกที่สุด',
      'ราคาซัพฯถูกที่สุด',
    ];
    final rows = <List<dynamic>>[header];
    for (final pr in _products) {
      final sups = _suppliers.where((s) => s.productId == pr.id).toList();
      SupplierRow? cheapest;
      if (sups.isNotEmpty) {
        cheapest = sups.reduce(
          (a, b) => (a.unitCost + a.freight) < (b.unitCost + b.freight) ? a : b,
        );
      }
      final status = pr.stock == 0
          ? 'หมดสต็อก'
          : pr.stock <= pr.minStock
          ? 'สต็อกต่ำ'
          : 'ปกติ';
      rows.add([
        pr.partNo,
        pr.name,
        pr.nameTH,
        pr.category,
        pr.brand,
        pr.compat ?? '',
        pr.price,
        pr.cost,
        pr.stock,
        pr.minStock,
        status,
        cheapest?.name ?? '',
        cheapest != null ? (cheapest.unitCost + cheapest.freight) : '',
      ]);
    }
    await _download(rows, 'inventory-${todayKey()}.csv', 'inventory');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final fs = _filteredSales();
    final billCount = fs.length;
    final revenue = fs.fold<double>(0, (s, t) => s + t.sale.total);
    final itemCount = fs.fold<int>(0, (s, t) => s + t.items.length);

    final ranges = const [
      ['today', 'วันนี้'],
      ['week', '7 วัน'],
      ['month', 'เดือนนี้'],
      ['all', 'ทั้งหมด'],
      ['custom', 'กำหนดเอง'],
    ];

    return _ContentPane(
      title: 'ส่งออกข้อมูล · Export to CSV',
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionTitle('ช่วงวันที่ · Date Range'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in ranges)
                    _RangeBtn(
                      label: r[1],
                      active: _range == r[0],
                      onTap: () => setState(() => _range = r[0]),
                    ),
                ],
              ),
              if (_range == 'custom') ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AppTextField(
                        label: 'ตั้งแต่ (YYYY-MM-DD)',
                        controller: _customStart,
                        hint: 'YYYY-MM-DD',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppTextField(
                        label: 'ถึงวันที่ (YYYY-MM-DD)',
                        controller: _customEnd,
                        hint: 'YYYY-MM-DD',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // Summary bar
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    _SummaryCell(label: 'บิล', value: '$billCount'),
                    _divider(theme),
                    _SummaryCell(label: 'ยอดรวม', value: baht(revenue)),
                    _divider(theme),
                    _SummaryCell(label: 'รายการ', value: '$itemCount'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _ExportRow(
                title: '📋 ยอดขายรายบิล',
                desc: '1 แถว = 1 บิล · เลขที่, วันที่, ยอดรวม, วิธีชำระ',
                meta: '$billCount แถว',
                color: AppColors.orange,
                onTap: _exportSummary,
              ),
              const SizedBox(height: 10),
              _ExportRow(
                title: '📦 รายการสินค้าที่ขาย',
                desc:
                    '1 แถว = 1 สินค้า · รหัส, จำนวน, ราคา, ต้นทุน, กำไร (คอลัมน์ ที่มาของต้นทุน บอกว่าเป็นต้นทุน ณ วันที่ขาย หรือต้นทุนปัจจุบัน)',
                meta: '$itemCount แถว',
                color: AppColors.orange,
                onTap: _exportDetail,
              ),
              const SizedBox(height: 10),
              _ExportRow(
                title: '🗂 สต็อกปัจจุบัน',
                desc: 'ไม่ขึ้นกับช่วงวันที่ · รหัส, ราคา, สต็อก, ซัพพลายเออร์',
                meta: '${_products.length} รายการ',
                color: AppColors.steelBlue,
                onTap: _exportInventory,
              ),
              if (_exported != null) ...[
                const SizedBox(height: 12),
                _StatusBanner(
                  success: true,
                  message:
                      'ดาวน์โหลดสำเร็จ — เปิดใน Excel (รองรับ UTF-8 + ภาษาไทย)',
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _divider(ThemeData theme) =>
      Container(width: 1, height: 44, color: theme.dividerColor);
}

class _RangeBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _RangeBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        constraints: const BoxConstraints(minHeight: 38),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.orange : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? AppColors.orange : theme.dividerColor,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 0.6,
            color: active ? AppColors.white : theme.colorScheme.secondary,
          ),
        ),
      ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryCell({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.8,
                color: theme.colorScheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportRow extends StatelessWidget {
  final String title;
  final String desc;
  final String meta;
  final Color color;
  final VoidCallback onTap;
  const _ExportRow({
    required this.title,
    required this.desc,
    required this.meta,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: AppColors.white,
            ),
            child: const Text('⬇ ดาวน์โหลด'),
          ),
        ],
      ),
    );
  }
}
