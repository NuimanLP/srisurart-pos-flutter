// supplier_groups.dart — the Suppliers tab's supplier-first view model (pure,
// no widgets; owner request 2026-10-12, docs/research/supplier-first-plan-2026-10-12.md).
//
// There is no supplier record: each `suppliers` row is one product's quote
// with a free-text name. [groupSuppliers] folds those rows into one entry per
// supplier ([supplierKey]: trimmed, case-insensitive), joined to the live
// products, with each quote compared against the cheapest quote any supplier
// gives for the same product. Totals are compared in whole satang so 0.1+0.2
// style float noise can never break a tie.

import '../../core/utils/supplier_name.dart';
import '../../data/db/database.dart';
import 'low_stock_alert.dart' show StockLevel, stockLevel;

int _satang(double baht) => (baht * 100).round();

/// One supplier's quote for one product.
class SupplierQuote {
  SupplierQuote._(
    this.row,
    this.product,
    this.totalSatang,
    this.bestSatang,
    this.quotesForProduct,
    this.bestName,
  );

  final SupplierRow row;
  final ProductRow product;

  /// unitCost + freight, in satang.
  final int totalSatang;

  /// The lowest total any supplier quotes for this product, in satang.
  final int bestSatang;

  /// How many quotes this product has across all suppliers.
  final int quotesForProduct;

  /// A supplier quoting [bestSatang] for this product (trimmed name).
  final String bestName;

  /// The lowest total among two or more quotes ("cheapest of one" says nothing).
  bool get cheapest => quotesForProduct > 1 && totalSatang == bestSatang;

  /// How much dearer than the cheapest quote, in baht (0 when cheapest).
  double get overBaht => (totalSatang - bestSatang) / 100;

  double get total => totalSatang / 100;

  StockLevel get level => stockLevel(product);
}

/// One supplier: every quote whose name has the same [supplierKey].
class SupplierGroup {
  SupplierGroup._({
    required this.key,
    required this.name,
    required this.quotes,
    required this.productCount,
    required this.reorderCount,
    required this.cheapestCount,
    required this.searchText,
  });

  final String key;

  /// The most used trimmed spelling (ties: the first row's).
  final String name;

  /// Most urgent first: out of stock, then low, then the rest; by product name.
  final List<SupplierQuote> quotes;

  final int productCount;

  /// Products of this supplier that are out of stock or low.
  final int reorderCount;

  /// Products for which this supplier gives the cheapest total.
  final int cheapestCount;

  /// Lower-cased supplier name + its products' names and part numbers.
  final String searchText;

  Set<String> get productIds => {for (final q in quotes) q.product.id};

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

  final best = <String, int>{};
  final bestName = <String, String>{};
  final count = <String, int>{};
  for (final r in live) {
    final t = _satang(r.unitCost + r.freight);
    count[r.productId] = (count[r.productId] ?? 0) + 1;
    final b = best[r.productId];
    if (b == null || t < b) {
      best[r.productId] = t;
      bestName[r.productId] = r.name.trim();
    }
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

    final quotes = [
      for (final r in groupRows)
        SupplierQuote._(
          r,
          byId[r.productId]!,
          _satang(r.unitCost + r.freight),
          best[r.productId]!,
          count[r.productId]!,
          bestName[r.productId]!,
        ),
    ]..sort((a, b) {
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
        productCount: productIds.length,
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
