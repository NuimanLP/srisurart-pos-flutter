// flutter_bloc RepositoryProvider tree — the 13 repository providers, all
// reading the same AppDatabase. Ported off Riverpod's providers.dart +
// shift_providers.dart (see docs/plans/riverpod-to-bloc.md).

import 'package:flutter_bloc/flutter_bloc.dart';

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
import '../../data/repositories/shifts_repository.dart';
import '../../data/repositories/snapshot_repository.dart';
import '../../data/repositories/suppliers_repository.dart';

/// The 13 repository providers, mirroring providers.dart + shift_providers.dart.
/// Wired via `MultiRepositoryProvider` in main.dart, alongside (not instead of)
/// the existing `ProviderScope`.
List<RepositoryProvider> repositoryProviders(AppDatabase db) => [
      RepositoryProvider<ProductsRepository>.value(
          value: ProductsRepository(db)),
      RepositoryProvider<CustomersRepository>.value(
          value: CustomersRepository(db)),
      RepositoryProvider<MechanicsRepository>.value(
          value: MechanicsRepository(db)),
      RepositoryProvider<SalesRepository>.value(value: SalesRepository(db)),
      RepositoryProvider<ReturnsRepository>.value(
          value: ReturnsRepository(db)),
      RepositoryProvider<PurchaseOrdersRepository>.value(
          value: PurchaseOrdersRepository(db)),
      RepositoryProvider<QuotesRepository>.value(value: QuotesRepository(db)),
      RepositoryProvider<ParkedRepository>.value(value: ParkedRepository(db)),
      RepositoryProvider<MovementsRepository>.value(
          value: MovementsRepository(db)),
      RepositoryProvider<SuppliersRepository>.value(
          value: SuppliersRepository(db)),
      RepositoryProvider<SettingsRepository>.value(
          value: SettingsRepository(db)),
      RepositoryProvider<SnapshotRepository>.value(
          value: SnapshotRepository(db)),
      RepositoryProvider<ShiftsRepository>.value(value: ShiftsRepository(db)),
    ];
