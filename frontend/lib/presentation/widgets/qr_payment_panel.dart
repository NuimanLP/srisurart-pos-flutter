// Checkout's โอน/QR panel (owner request 2026-10-10, contract §5). Owned by
// CheckoutScreen (CONTRACT.md §5); split out only to keep that file's size in
// check.
//
// Shows the selected account's QR — a dynamic PromptPay QR carrying the bill
// total, or the uploaded static image next to the big total — with the
// account's nickname and bank, a "เปลี่ยนบัญชี" chip row over the ≤5 accounts
// and an "ขยาย" button that opens the QR fullscreen for the customer to scan.
// No accounts: a hint to add one in Settings (the sale still goes through as
// โอน/QR with no account). No confirmation step (owner decision).

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../core/utils/promptpay.dart';
import '../../data/db/database.dart';
import 'payment_accounts_settings.dart' show BankLabel;

/// Shown under โอน/QR when no account is set up.
const qrNoAccountsHint =
    'ยังไม่มีบัญชีรับเงิน QR — เจ้าของร้านเพิ่มได้ที่ ตั้งค่า → บัญชีรับเงิน QR'; // agent ร่าง

class QrPaymentPanel extends StatelessWidget {
  const QrPaymentPanel({
    super.key,
    required this.accounts,
    required this.selected,
    required this.total,
    required this.onSelect,
  });

  final List<PaymentAccountRow> accounts;

  /// The account the bill will record — the caller resolves the default.
  final PaymentAccountRow? selected;
  final double total;
  final ValueChanged<PaymentAccountRow> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = selected;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.steelBlue.withValues(alpha: 0.07),
        border: Border.all(color: AppColors.steelBlue.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: a == null
          ? Text(qrNoAccountsHint, style: theme.textTheme.bodyMedium)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.nickname,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          BankLabel(a.bankCode, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => showQrFullscreen(context, a, total),
                      icon: const Icon(Icons.fullscreen),
                      label: const Text('ขยาย'), // agent ร่าง
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Center(child: QrCodeView(account: a, total: total, size: 180)),
                const SizedBox(height: 6),
                Text(
                  baht(total),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.orange,
                  ),
                ),
                if (accounts.length > 1) ...[
                  const SizedBox(height: 8),
                  Text('เปลี่ยนบัญชี', style: theme.textTheme.labelMedium), // agent ร่าง
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final acc in accounts)
                        ChoiceChip(
                          key: ValueKey('qr-account-${acc.id}'),
                          label: Text(acc.nickname),
                          selected: acc.id == a.id,
                          onSelected: (_) => onSelect(acc),
                        ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

/// The QR itself: a PromptPay payload with [total], or the stored image.
class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.account,
    required this.total,
    required this.size,
  });

  final PaymentAccountRow account;
  final double total;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (account.kind == 'image') {
      final image = account.image;
      if (image == null) return _broken();
      // A transparent PNG's black modules vanish on a dark panel: same white
      // quiet zone as the PromptPay QR below.
      return _quietZone(
        Image.memory(
          image,
          key: const ValueKey('image-qr'),
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      );
    }
    final String payload;
    try {
      payload = promptPayPayload(account.promptpayId ?? '', total);
    } on ArgumentError {
      return _broken();
    }
    return _quietZone(
      BarcodeWidget(
        key: const ValueKey('promptpay-qr'),
        barcode: Barcode.qrCode(),
        data: payload,
        width: size,
        height: size,
        drawText: false,
      ),
    );
  }

  /// A white quiet zone so a phone camera reads the QR in dark mode too.
  Widget _quietZone(Widget qr) => Container(
        key: const ValueKey('qr-quiet-zone'),
        color: Colors.white,
        padding: const EdgeInsets.all(8),
        child: qr,
      );

  Widget _broken() => SizedBox(
        width: size,
        height: size,
        child: const Center(
          child: Text(
            'แสดง QR ของบัญชีนี้ไม่ได้ กรุณาแก้ไขบัญชีในตั้งค่า', // agent ร่าง
            textAlign: TextAlign.center,
          ),
        ),
      );
}

/// The QR as large as the screen allows, for the customer's phone.
Future<void> showQrFullscreen(
  BuildContext context,
  PaymentAccountRow account,
  double total,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (ctx, c) {
            final side = (c.biggest.shortestSide - 160).clamp(160.0, 560.0);
            return Stack(
              children: [
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          account.nickname,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                          ),
                        ),
                        BankLabel(
                          account.bankCode,
                          style: const TextStyle(color: Colors.black54),
                        ),
                        const SizedBox(height: 12),
                        QrCodeView(account: account, total: total, size: side),
                        const SizedBox(height: 12),
                        Text(
                          baht(total),
                          style: const TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                            color: AppColors.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    tooltip: 'ปิด',
                    icon: const Icon(Icons.close, color: Colors.black),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
