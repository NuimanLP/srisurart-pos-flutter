// supplier_groups.dart — the Suppliers tab's supplier-first view model (pure,
// no widgets; owner request 2026-10-12, docs/research/supplier-first-plan-2026-10-12.md).
//
// There is no supplier record: each `suppliers` row is one product's quote
// with a free-text name. [groupSuppliers] folds those rows into one entry per
// supplier ([supplierKey]: trimmed, case-insensitive), joined to the live
// products, with each quote compared against the best quote any OTHER
// supplier gives for the same product (a supplier with two quotes for one
// product is never "cheaper than itself"). Money is compared in whole satang
// (cost and freight rounded separately) so float noise can never break a tie.

import '../../core/utils/supplier_name.dart';
import '../../data/db/database.dart';
import 'low_stock_alert.dart' show StockLevel, stockLevel;

int _satang(double baht) => (baht * 100).round();

int _totalSatang(SupplierRow r) => _satang(r.unitCost) + _satang(r.freight);

/// One supplier's quote for one product.
class SupplierQuote {
  SupplierQuote._(
    this.row,
    this.product,
    this.totalSatang,
    this.ownBestSatang,
    this.bestOtherSatang,
    this.bestOtherName,
  );

  final SupplierRow row;
  final ProductRow product;

  /// unitCost + freight, in satang.
  final int totalSatang;

  /// This supplier's own lowest total for the product (it may hold several).
  final int ownBestSatang;

  /// The lowest total any OTHER supplier quotes for this product, or null
  /// when no other supplier quotes it.
  final int? bestOtherSatang;

  /// The other supplier quoting [bestOtherSatang] (trimmed name).
  final String? bestOtherName;

  /// This supplier's best quote and no other supplier is cheaper (ties count).
  /// A product only this supplier quotes has no "cheapest".
  bool get cheapest =>
      bestOtherSatang != null &&
      totalSatang == ownBestSatang &&
      totalSatang <= bestOtherSatang!;

  /// Another supplier quotes this product for less.
  bool get dearer => bestOtherSatang != null && totalSatang > bestOtherSatang!;

  /// How much dearer than [bestOtherName], in baht (0 unless [dearer]).
  double get overBaht => dearer ? (totalSatang - bestOtherSatang!) / 100 : 0;

  double get total => totalSatang / 100;

  StockLevel get level => stockLevel(product);
}

/// One supplier: every quote whose name has the same [supplierKey].
class SupplierGroup {
  SupplierGroup._({
    required this.key,
    required this.name,
    required this.quotes,
    required this.productIds,
    required this.reorderCount,
    required this.cheapestCount,
    required this.searchText,
  });

  final String key;

  /// The most used trimmed spelling (ties: the first row's).
  final String name;

  /// Most urgent first: out of stock, then low, then the rest; by product name.
  final List<SupplierQuote> quotes;

  /// The products this supplier quotes.
  final Set<String> productIds;

  int get productCount => productIds.length;

  /// Products of this supplier that are out of stock or low ([stockLevel]).
  final int reorderCount;

  /// Products for which this supplier gives the cheapest total.
  final int cheapestCount;

  /// Lower-cased supplier name + its products' names and part numbers.
  final String searchText;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || searchText.contains(q);
  }
}

/// Groups [rows] by supplier. Rows with a blank name, or for a product not in
/// [products] (deleted), are left out. Suppliers with something to reorder come
/// first, then by name.
List<SupplierGroup> groupSuppliers(
  List<ProductRow> products,
  List<SupplierRow> rows,
) {
  final byId = {for (final p in products) p.id: p};
  final live = [
    for (final r in rows)
      if (r.name.trim().isNotEmpty && byId.containsKey(r.productId)) r,
  ];

  // product → supplier key → that supplier's best (satang, trimmed name).
  final bestBy = <String, Map<String, (int, String)>>{};
  for (final r in live) {
    final t = _totalSatang(r);
    final perKey = bestBy.putIfAbsent(r.productId, () => {});
    final k = supplierKey(r.name);
    final cur = perKey[k];
    if (cur == null || t < cur.$1) perKey[k] = (t, r.name.trim());
  }

  final byKey = <String, List<SupplierRow>>{};
  for (final r in live) {
    byKey.putIfAbsent(supplierKey(r.name), () => []).add(r);
  }

  final groups = <SupplierGroup>[];
  byKey.forEach((key, groupRows) {
    // Most used spelling; the first row's on a tie (a later one must be MORE used).
    final uses = <String, int>{};
    for (final r in groupRows) {
      final n = r.name.trim();
      uses[n] = (uses[n] ?? 0) + 1;
    }
    var name = groupRows.first.name.trim();
    uses.forEach((n, c) {
      if (c > uses[name]!) name = n;
    });

    SupplierQuote quoteOf(SupplierRow r) {
      final perKey = bestBy[r.productId]!;
      (int, String)? other;
      perKey.forEach((k, v) {
        if (k != key && (other == null || v.$1 < other!.$1)) other = v;
      });
      return SupplierQuote._(
        r,
        byId[r.productId]!,
        _totalSatang(r),
        perKey[key]!.$1,
        other?.$1,
        other?.$2,
      );
    }

    final quotes = [for (final r in groupRows) quoteOf(r)]
      ..sort((a, b) {
        final byLevel = a.level.index.compareTo(b.level.index);
        if (byLevel != 0) return byLevel;
        return a.product.name.toLowerCase().compareTo(
          b.product.name.toLowerCase(),
        );
      });

    final productIds = <String>{};
    final reorder = <String>{};
    final cheapest = <String>{};
    final search = StringBuffer(key);
    for (final q in quotes) {
      final p = q.product;
      if (productIds.add(p.id)) {
        search
          ..write('\n')
          ..write(p.name.toLowerCase())
          ..write('\n')
          ..write(p.nameTH.toLowerCase())
          ..write('\n')
          ..write(p.partNo.toLowerCase());
      }
      if (q.level != StockLevel.ok) reorder.add(p.id);
      if (q.cheapest) cheapest.add(p.id);
    }

    groups.add(
      SupplierGroup._(
        key: key,
        name: name,
        quotes: quotes,
        productIds: productIds,
        reorderCount: reorder.length,
        cheapestCount: cheapest.length,
        searchText: search.toString(),
      ),
    );
  });

  groups.sort((a, b) {
    final aNeeds = a.reorderCount > 0 ? 0 : 1;
    final bNeeds = b.reorderCount > 0 ? 0 : 1;
    if (aNeeds != bNeeds) return aNeeds.compareTo(bNeeds);
    return a.key.compareTo(b.key);
  });
  return groups;
}
