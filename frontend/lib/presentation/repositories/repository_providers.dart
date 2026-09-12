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

import '../../core/network/api_client.dart';
import '../../data/repositories/api/api_returns_repository.dart';
import '../../data/repositories/api/api_sales_repository.dart';
import '../../data/repositories/api/api_shifts_repository.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/storage/token_storage.dart';

import '../../data/repositories/api_customers_repository.dart';
import '../../data/repositories/api_mechanics_repository.dart';
import '../../data/repositories/api_products_repository.dart';
import '../../data/repositories/api_purchase_orders_repository.dart';
import '../../data/repositories/api_quotes_repository.dart';
import '../../data/services/bootstrap_service.dart';

/// The repository providers, mirroring providers.dart + shift_providers.dart,
/// plus AuthRepository, ApiClient, and ApiRepositories (Ticket #55 / ADR-0010).
/// Wired via `MultiRepositoryProvider` in main.dart.
///
/// [useApi] switches the #56 API-backed WRITE repositories (sales, returns,
/// shifts) in behind the same interfaces (ADR-0010) instead of the Drift-only
/// ones. It defaults to `false` — CLAUDE.md: "the shop keeps running the Drift
/// build, no cutover" for phase 1 — and is flipped only via
/// `--dart-define=USE_API_WRITES=true`.
///
/// [useApiRepositories] is #55's separate switch for the API-backed READ
/// repositories (products, customers, mechanics, purchase orders, quotes).
List<RepositoryProvider> repositoryProviders(
  AppDatabase db, {
  AuthRepository? authRepository,
  ApiClient? apiClient,
  bool useApi = const bool.fromEnvironment('USE_API_WRITES'),
  bool useApiRepositories = true,
}) {
  final storage = SharedPrefsTokenStorage();
  final client = apiClient ?? ApiClient(tokenStorage: storage);
  final authRepo = authRepository ??
      AuthRepository(
        apiClient: client,
        tokenStorage: storage,
      );

  // The three write paths of #56. Each API implementation keeps a Drift
  // instance of the same repository to delegate its READS to — those belong to
  // #55 and are untouched here — so the Drift object is constructed either way.
  final driftSales = SalesRepository(db);
  final driftReturns = ReturnsRepository(db);
  final driftShifts = ShiftsRepository(db);

  final salesRepository = useApi
      ? ApiSalesRepository(api: client, db: db, drift: driftSales)
      : driftSales;
  final returnsRepository = useApi
      ? ApiReturnsRepository(api: client, db: db, drift: driftReturns)
      : driftReturns;
  final shiftsRepository = useApi
      ? ApiShiftsRepository(api: client, db: db, drift: driftShifts)
      : driftShifts;

  // The five read paths of #55, switched by their own flag.
  final productsRepo = useApiRepositories
      ? ApiProductsRepository(db, client)
      : ProductsRepository(db);
  final customersRepo = useApiRepositories
      ? ApiCustomersRepository(db, client)
      : CustomersRepository(db);
  final mechanicsRepo = useApiRepositories
      ? ApiMechanicsRepository(db, client)
      : MechanicsRepository(db);
  final poRepo = useApiRepositories
      ? ApiPurchaseOrdersRepository(db, client)
      : PurchaseOrdersRepository(db);
  final quotesRepo = useApiRepositories
      ? ApiQuotesRepository(db, client)
      : QuotesRepository(db);
  final bootstrapService = BootstrapService(db: db, apiClient: client);

  return [
    RepositoryProvider<ProductsRepository>.value(value: productsRepo),
    RepositoryProvider<CustomersRepository>.value(value: customersRepo),
    RepositoryProvider<MechanicsRepository>.value(value: mechanicsRepo),
    RepositoryProvider<SalesRepository>.value(value: salesRepository),
    RepositoryProvider<ReturnsRepository>.value(value: returnsRepository),
    RepositoryProvider<PurchaseOrdersRepository>.value(value: poRepo),
    RepositoryProvider<QuotesRepository>.value(value: quotesRepo),
    RepositoryProvider<ParkedRepository>.value(value: ParkedRepository(db)),
    RepositoryProvider<MovementsRepository>.value(value: MovementsRepository(db)),
    RepositoryProvider<SuppliersRepository>.value(value: SuppliersRepository(db)),
    RepositoryProvider<SettingsRepository>.value(value: SettingsRepository(db)),
    RepositoryProvider<SnapshotRepository>.value(value: SnapshotRepository(db)),
    RepositoryProvider<ShiftsRepository>.value(value: shiftsRepository),
    RepositoryProvider<AuthRepository>.value(value: authRepo),
    RepositoryProvider<ApiClient>.value(value: client),
    RepositoryProvider<BootstrapService>.value(value: bootstrapService),
  ];
}
