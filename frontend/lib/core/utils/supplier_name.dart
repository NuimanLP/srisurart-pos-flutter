// supplier_name.dart — one rule for "is this the same supplier?".
//
// A supplier is not its own record: each `suppliers` row is one product's
// quote that carries a free-text name. Screens group those rows (and match a
// purchase order's supplier text) by this key, so the Suppliers tab and the
// create-PO dialog can never disagree about who is who. Trimmed and
// case-insensitive only — no Unicode normalisation.

String supplierKey(String name) => name.trim().toLowerCase();
