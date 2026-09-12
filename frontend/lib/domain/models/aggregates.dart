// Domain aggregates + input DTOs for the Srisurart POS.
//
// FLAT entities are consumed DIRECTLY as the Drift-generated row classes
// (ProductRow, CustomerRow, MechanicRow, SaleRow, SaleItemRow, …). Screens and
// services use those row classes for single-table reads/writes.
//
// This file adds only:
//   1. Nested READ aggregates that pair a header row with its item rows
//      (SaleWithItems, PurchaseOrderWithItems, QuoteWithItems, ReturnWithItems,
//      ShiftWithEntries). Repositories return these for "load the whole document".
//   2. Immutable INPUT DTOs that the transactional service methods accept
//      (SaleInput, ReturnInput, PoInput, QuoteInput, ParkedInput and their line
//      types). These mirror the object shapes db.js builds before saveSale /
//      createReturn / savePO / saveQuote / parkSale.
//
// All classes are immutable (final fields, const constructors where possible).

import '../../data/db/database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// READ AGGREGATES — header row + its item rows.
// ─────────────────────────────────────────────────────────────────────────────

/// A sale header (SaleRow) together with its line items (SaleItemRow list).
class SaleWithItems {
  final SaleRow sale;
  final List<SaleItemRow> items;
  const SaleWithItems(this.sale, this.items);
}

/// A purchase-order header (PurchaseOrderRow) together with its line items.
class PurchaseOrderWithItems {
  final PurchaseOrderRow po;
  final List<PoItemRow> items;
  const PurchaseOrderWithItems(this.po, this.items);
}

/// A quote header (QuoteRow) together with its line items.
class QuoteWithItems {
  final QuoteRow quote;
  final List<QuoteItemRow> items;
  const QuoteWithItems(this.quote, this.items);
}

/// Quote status reads shared by the quotes screen + A4 view (JSX parity:
/// `new Date(q.validUntil) < new Date()` / `q.status === 'converted'`).
extension QuoteRowStatus on QuoteRow {
  bool get isExpired => validUntil.isBefore(DateTime.now());
  bool get isConverted => status == 'converted';
}

/// A return / credit-note header (ReturnRow) together with its line items.
class ReturnWithItems {
  final ReturnRow ret;
  final List<ReturnItemRow> items;
  const ReturnWithItems(this.ret, this.items);
}

/// A cash-drawer shift (ShiftRow) together with its drawer entries.
class ShiftWithEntries {
  final ShiftRow shift;
  final List<DrawerEntryRow> entries;
  const ShiftWithEntries(this.shift, this.entries);
}

// ─────────────────────────────────────────────────────────────────────────────
// INPUT DTOs — what the transactional services accept.
// ─────────────────────────────────────────────────────────────────────────────

/// One cart line passed to [SalesRepository.saveSale].
/// Mirrors `sale.items[i]` in db.js saveSale: { productId, name, qty, price,
/// partNo?, nameTH? }.
class SaleLineInput {
  final String productId;
  final String name;
  final int qty;
  final double price;
  final String? partNo;
  final String? nameTH;
  const SaleLineInput({
    required this.productId,
    required this.name,
    required this.qty,
    required this.price,
    this.partNo,
    this.nameTH,
  });
}

/// Payload for [SalesRepository.saveSale]. Mirrors the `sale` object db.js
/// receives: subtotal/discount/total/paymentMethod plus optional customer &
/// mechanic context and the cart [items]. The service computes pointsGranted,
/// receiptNo, id and date — they are NOT part of the input.
class SaleInput {
  final double subtotal;
  final double discount;
  final double total;
  final String paymentMethod;
  final String? customerId;
  final String? customerName;
  final String? mechanicId;
  final String? mechanicName;

  /// Signed price adjustment from a mechanic override (db.js `mechanicDelta`):
  /// negative = discount given, positive = markup. Null when no mechanic.
  final double? mechanicDelta;

  final List<SaleLineInput> items;

  /// The counter answered 'ยืนยัน' to the `ยืนยันขายเครดิต?` dialog
  /// (`checkout_screen.dart:561-582`): this bill may push the mechanic past his
  /// credit limit.
  ///
  /// Added for #56. The Drift `saveSale` ignores it — the JS app never had a
  /// limit check in the data layer, only in the screen — but the server does
  /// check, and answers `409 CREDIT_LIMIT_EXCEEDED` unless the body carries
  /// `overrideCreditLimit: true`, which also writes an `audit_log` row naming
  /// who let the bill past.
  ///
  /// 🔴 It is a field rather than something the repository works out for itself
  /// because **consent cannot be re-derived**. The first implementation replayed
  /// the screen's own `creditBalance + total > creditLimit` test against the
  /// cached mechanic row on a 409, and treated a trip as proof the dialog had
  /// been answered. It is not: the screen tests the `MechanicRow` it captured
  /// when the list loaded, while the repository would re-read the live row, so a
  /// balance that moved in between (a prior bill on the same screen already
  /// patches it) makes the repository override a limit the counter was never
  /// shown a dialog for — and the server then records an override that never
  /// happened. Carry the answer; never infer it.
  final bool overrideCreditLimit;

  const SaleInput({
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethod,
    this.customerId,
    this.customerName,
    this.mechanicId,
    this.mechanicName,
    this.mechanicDelta,
    this.overrideCreditLimit = false,
    required this.items,
  });
}

/// One refund line passed to [ReturnsRepository.createReturn].
/// Mirrors db.js createReturn items: { productId, name, qty, price, originalQty? }.
/// `qty` = how many units of this product to refund.
class ReturnLineInput {
  final String productId;
  final String name;
  final int qty;
  final double price;
  final int? originalQty;
  const ReturnLineInput({
    required this.productId,
    required this.name,
    required this.qty,
    required this.price,
    this.originalQty,
  });
}

/// Payload for [ReturnsRepository.createReturn]. Mirrors the destructured arg in
/// db.js: { saleId, items, refundMethod, reason }.
/// refundMethod is one of: 'เงินสด' | 'หักจากเครดิต' | 'โอน'.
class ReturnInput {
  final String saleId;
  final List<ReturnLineInput> items;
  final String refundMethod;
  final String? reason;
  const ReturnInput({
    required this.saleId,
    required this.items,
    required this.refundMethod,
    this.reason,
  });
}

/// One purchase-order line passed to [PurchaseOrdersRepository.savePO].
/// Mirrors a PO item in db.js: { partNo, name, qty, cost }.
class PoLineInput {
  final String partNo;
  final String name;
  final int qty;
  final double cost;
  const PoLineInput({
    required this.partNo,
    required this.name,
    required this.qty,
    required this.cost,
  });
}

/// Payload for [PurchaseOrdersRepository.savePO]. Mirrors the `po` object in
/// db.js savePO: { supplier, items }. The service assigns id, poNo, createdAt,
/// status='open'.
class PoInput {
  final String supplier;
  final List<PoLineInput> items;
  const PoInput({required this.supplier, required this.items});
}

/// One quote line passed to [QuotesRepository.saveQuote].
/// Mirrors a quote item in db.js: { productId?, name, qty, price }.
class QuoteLineInput {
  final String? productId;
  final String name;
  final int qty;
  final double price;
  const QuoteLineInput({
    this.productId,
    required this.name,
    required this.qty,
    required this.price,
  });
}

/// Payload for [QuotesRepository.saveQuote]. Mirrors the `q` object db.js
/// receives: subtotal/discount/total, optional customerName/customerPhone/notes,
/// optional validDays (defaults to 30 → validUntil), optional status (defaults
/// 'open'). The service assigns id, quoteNo, date, validUntil.
class QuoteInput {
  final double? subtotal;
  final double? discount;
  final double? total;
  final String? customerName;
  final String? customerPhone;
  final String? notes;
  final int? validDays;
  final String? status;
  final List<QuoteLineInput> items;
  const QuoteInput({
    this.subtotal,
    this.discount,
    this.total,
    this.customerName,
    this.customerPhone,
    this.notes,
    this.validDays,
    this.status,
    required this.items,
  });
}

/// Payload for [ParkedRepository.parkSale]. A parked bill is a cart snapshot
/// only — it NEVER touches stock. db.js stores `{ ...data, id, parkedAt }`; the
/// whole cart/customer/mechanic/discount blob is opaque and serialized into the
/// ParkedSales.payload JSON column. We model the known fields plus a free-form
/// [extra] map for forward-compatibility; services may instead serialize the
/// entire DTO to JSON.
class ParkedInput {
  final List<SaleLineInput> items;
  final String? customerId;
  final String? customerName;
  final String? mechanicId;
  final String? mechanicName;
  final double? discount;

  /// Any additional cart-state fields not modeled above (kept verbatim).
  final Map<String, dynamic> extra;

  const ParkedInput({
    required this.items,
    this.customerId,
    this.customerName,
    this.mechanicId,
    this.mechanicName,
    this.discount,
    this.extra = const {},
  });
}
