// FavoritesRepository — the POS sell screen's starred products (owner request
// 2026-10-08).
//
// THIS DEVICE ONLY: the set of favorite product ids is one JSON array in the
// AppMeta key [favoritesKey]. No table, no server, no outbox — so the Drift
// build and the API build (USE_API_WRITES) use this same class unchanged.
//
// A tenant switch (`AppDatabase.resetTenantCache`) deletes the key with every
// other non-device AppMeta key — deliberate: the old shop's product ids mean
// nothing to the new one. `resetAfterServerImport` keeps it (AppMeta stays);
// ids that no longer match a product are simply ignored by the screen.

import 'dart:convert';

import '../db/database.dart';

class FavoritesRepository {
  final AppDatabase db;
  FavoritesRepository(this.db);

  static const favoritesKey = 'pos_favorite_product_ids';

  /// The starred product ids (empty when none, or the stored value is unreadable).
  Future<Set<String>> getFavorites() async {
    final row = await (db.select(
      db.appMeta,
    )..where((t) => t.key.equals(favoritesKey))).getSingleOrNull();
    if (row == null) return <String>{};
    try {
      final decoded = jsonDecode(row.value);
      if (decoded is List) return decoded.whereType<String>().toSet();
    } on FormatException {
      // Corrupt value: start over rather than break the sell screen.
    }
    return <String>{};
  }

  /// Stars [productId] if it is not starred, unstars it if it is. Returns the
  /// new set.
  Future<Set<String>> toggle(String productId) => db.transaction(() async {
    final favs = await getFavorites();
    if (!favs.remove(productId)) favs.add(productId);
    await db
        .into(db.appMeta)
        .insertOnConflictUpdate(
          AppMetaCompanion.insert(
            key: favoritesKey,
            value: jsonEncode(favs.toList()),
          ),
        );
    return favs;
  });
}

/// The sell-screen grid order: starred products first, everything else after,
/// each group keeping its incoming order (stable). With [onlyFavorites], only
/// the starred ones.
List<ProductRow> favoritesFirst(
  List<ProductRow> products,
  Set<String> favorites, {
  bool onlyFavorites = false,
}) {
  final starred = products.where((p) => favorites.contains(p.id));
  if (onlyFavorites) return starred.toList();
  return [...starred, ...products.where((p) => !favorites.contains(p.id))];
}
