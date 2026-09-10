// The one place the product sync-stamp rule lives.
//
// This is a separate file on purpose: `ProductsCompanion` is declared in
// `database.g.dart`, and a top-level declaration referring to it from inside
// `database.dart` — the library that *owns* that part — cannot be analysed on a
// cold build, when the part does not exist yet. drift_dev then emits nothing
// for the library and `database.g.dart` is never written. Keep this here.

import 'package:drift/drift.dart';

import 'database.dart';

/// ADR-0010: the client fetches products with `?updatedSince=`, so every write
/// that changes a product row has to move `updatedAt`. Route product writes
/// through this rather than stamping by hand, or a write path added later
/// silently drops out of the sync cursor.
///
/// A companion that already carries a stamp keeps it: once `ApiRepository`
/// patches rows from a server response, the server's timestamp must not be
/// overwritten with the local clock (ADR-0010 decision 3).
extension ProductWriteStamp on ProductsCompanion {
  ProductsCompanion get stamped =>
      updatedAt.present ? this : copyWith(updatedAt: Value(DateTime.now()));
}
