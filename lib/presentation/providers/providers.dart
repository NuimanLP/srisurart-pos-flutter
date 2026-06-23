// Riverpod providers (plain, NOT codegen).
//
// databaseProvider throws by default — it MUST be overridden in main.dart with
// the real AppDatabase via `databaseProvider.overrideWithValue(db)`. Every
// repository provider reads databaseProvider, so overriding the one DB wires
// the whole graph.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repositories/customers_repository.dart';
import '../../data/repositories/mechanics_repository.dart';
import '../../data/repositories/movements_repository.dart';
import '../../data/repositories/parked_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/purchase_orders_repository.dart';
import '../../data/repositories/quotes_repository.dart';
import '../../data/repositories/returns_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/snapshot_repository.dart';
import '../../data/repositories/suppliers_repository.dart';

/// The app database. Throws unless overridden in main.dart with the real DB.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError(
    'databaseProvider must be overridden in main.dart with AppDatabase.open()',
  );
});

final productsRepoProvider = Provider<ProductsRepository>(
    (ref) => ProductsRepository(ref.watch(databaseProvider)));

final customersRepoProvider = Provider<CustomersRepository>(
    (ref) => CustomersRepository(ref.watch(databaseProvider)));

final mechanicsRepoProvider = Provider<MechanicsRepository>(
    (ref) => MechanicsRepository(ref.watch(databaseProvider)));

final salesRepoProvider = Provider<SalesRepository>(
    (ref) => SalesRepository(ref.watch(databaseProvider)));

final returnsRepoProvider = Provider<ReturnsRepository>(
    (ref) => ReturnsRepository(ref.watch(databaseProvider)));

final purchaseOrdersRepoProvider = Provider<PurchaseOrdersRepository>(
    (ref) => PurchaseOrdersRepository(ref.watch(databaseProvider)));

final quotesRepoProvider = Provider<QuotesRepository>(
    (ref) => QuotesRepository(ref.watch(databaseProvider)));

final parkedRepoProvider = Provider<ParkedRepository>(
    (ref) => ParkedRepository(ref.watch(databaseProvider)));

final movementsRepoProvider = Provider<MovementsRepository>(
    (ref) => MovementsRepository(ref.watch(databaseProvider)));

final suppliersRepoProvider = Provider<SuppliersRepository>(
    (ref) => SuppliersRepository(ref.watch(databaseProvider)));

final settingsRepoProvider = Provider<SettingsRepository>(
    (ref) => SettingsRepository(ref.watch(databaseProvider)));

final snapshotRepoProvider = Provider<SnapshotRepository>(
    (ref) => SnapshotRepository(ref.watch(databaseProvider)));
