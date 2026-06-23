// low_stock_alert.dart — once-per-session low-stock banner (port of
// pos/LowStockAlert.jsx, adapted to a dismissible banner instead of a modal).
//
// JS behaviour parity:
//  • Lists OUT-of-stock (stock == 0) then LOW (0 < stock <= minStock) products.
//  • Shown once per app session — controlled by [lowStockShownThisSession], a
//    module-level flag the host screen checks (mirrors the JS
//    sessionStorage `sa_lowstock_dismissed` once-per-session rule, NOT per day).
//  • Provides a "ไปหน้าสั่งซื้อ" action (navigates to /purchase-orders).
//
// Camera barcode scanning is unrelated here; nothing deferred in this widget.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/db/database.dart';

/// Session flag: true once the alert has been shown/dismissed this app run.
/// The checkout screen flips this so the banner appears at most once per session.
bool lowStockShownThisSession = false;

/// Splits products into out-of-stock and low-stock buckets (db.js logic).
({List<ProductRow> out, List<ProductRow> low}) lowStockBuckets(
    List<ProductRow> products) {
  final out = products.where((p) => p.stock == 0).toList();
  final low =
      products.where((p) => p.stock > 0 && p.stock <= p.minStock).toList();
  return (out: out, low: low);
}

class LowStockBanner extends StatelessWidget {
  final List<ProductRow> outOfStock;
  final List<ProductRow> lowStock;
  final VoidCallback onClose;
  final VoidCallback onOrder;

  const LowStockBanner({
    super.key,
    required this.outOfStock,
    required this.lowStock,
    required this.onClose,
    required this.onOrder,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          border: Border.all(color: AppColors.warning),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Text('⚠', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'แจ้งเตือนสต็อก · Stock Alert',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'พบ ${outOfStock.length} รายการหมด + ${lowStock.length} รายการต่ำกว่าขั้นต่ำ',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onOrder,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              child: const Text('🛒 ไปหน้าสั่งซื้อ'),
            ),
            IconButton(
              tooltip: 'ปิด',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}
