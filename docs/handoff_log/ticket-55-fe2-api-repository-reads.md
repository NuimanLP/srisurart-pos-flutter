# Ticket #55 `fe.2` — ApiRepository Reads & Write-Through Cache

**Date:** 2026-09-12  
**Branch:** `feat/fe2-api-repository-reads`  
**Status:** Ready for Review / PR  
**PR:** Against `main`

---

## 1. Context & Motivation
Per **ADR-0010** (*Client write-through cache & degraded offline mode*) and Course Architecture:
- PostgreSQL is the single source of truth for tenancy, stock, and sales invariants.
- Local Drift database acts as a read cache and offline fallback shell.
- **Rule 1 (ADR-0010):** `ApiRepository` write-through never invokes local Drift transactional services (e.g. `adjustStock` clamping, `receivePO` weighted-average cost computation, `saveSale` decrementing). It patches Drift rows directly using the server's authoritative response.
- **Rule 2 (ADR-0010):** Soft deletes (`deletedAt`) ensure `?updatedSince=` sync cursor does not resurrect deleted records.
- **Acceptance Criterion 1:** Zero modifications to `lib/presentation/screens/` — UI screens remain unchanged as repositories conform to the existing domain interfaces.

---

## 2. Changes Made

### A. Drift Schema v4 Migration
1. **`frontend/lib/data/db/tables.dart`**:
   - Added nullable `deletedAt` (`DateTimeColumn`) to `Products`.
2. **`frontend/lib/data/db/database.dart`**:
   - Bumped `schemaVersion => 4`.
   - Added migration step `if (from < 4) await m.addColumn(products, products.deletedAt)`.
3. **`frontend/lib/data/db/database.g.dart`**:
   - Codegen regenerated via `dart run build_runner build` (+75 lines).
4. **Schema Migration Tests**:
   - Updated `test/schema_v1_to_v3_migration_test.dart` and `test/schema_v3_migration_test.dart`.
   - Added `test/schema_v4_migration_test.dart` verifying v3 ➡️ v4 migration on real SQLite file.

### B. Network & Repository Layer
1. **`frontend/lib/core/network/api_client.dart`**:
   - Added `patch(path, body, ...)` method with standard retry, token refresh, and envelope handling.
2. **`frontend/lib/data/repositories/api_products_repository.dart`**:
   - Implements `ProductsRepository`.
   - `syncFromServer`: queries `/api/v1/products?updatedSince=...` based on latest local `updatedAt`.
   - Filters out rows where `deletedAt != null`.
   - `adjustStock`: posts to `/api/v1/products/:id/adjust-stock` and patches `stock` with server `stockAfter` without local clamping.
   - Transparent offline fallback to Drift.
3. **`frontend/lib/data/repositories/api_customers_repository.dart`**:
   - Implements `CustomersRepository`.
   - `addCustomer`: posts to `/api/v1/customers` and applies server-generated `code` (e.g., `CUS###`).
   - Soft-delete with `deletedAt`.
4. **`frontend/lib/data/repositories/api_mechanics_repository.dart`**:
   - Implements `MechanicsRepository`.
   - `addCreditPayment`: posts to `/api/v1/mechanics/:id/credit-payments`, records payment row, and updates mechanic `creditBalance` directly from server's `mechanicCreditBalanceAfter`.
5. **`frontend/lib/data/repositories/api_purchase_orders_repository.dart`**:
   - Implements `PurchaseOrdersRepository`.
   - `receivePO`: posts to `/api/v1/purchase-orders/:id/receive`. Server returns new `stockAfter` and `costAfter`. Directly patches Drift products without client weighted-average cost calculation.
6. **`frontend/lib/data/repositories/api_quotes_repository.dart`**:
   - Implements `QuotesRepository`.
   - Implements server-backed `saveQuote`, `duplicateQuote`, `purgeOldQuotes`, and `deleteQuote`.
7. **`frontend/lib/data/services/bootstrap_service.dart`**:
   - Implements `GET /api/v1/bootstrap` bulk warm-up sync for categories, products, customers, mechanics, settings.
   - Falls back gracefully to individual endpoints when `/api/v1/bootstrap` returns 404.
8. **`frontend/lib/presentation/repositories/repository_providers.dart`**:
   - Wired `ApiRepository` implementations into `RepositoryProvider` tree with default `useApiRepositories: true`.
   - Exposed `BootstrapService` via `RepositoryProvider<BootstrapService>`.

---

## 3. Verification Results

- **Analyzer:**
  ```bash
  dart analyze --fatal-infos
  # Output: Analyzing frontend... No issues found! (0 errors, 0 warnings)
  ```
- **Automated Tests:**
  ```bash
  flutter test
  # 188 tests passed! (All unit, repository, migration, smoke, and route tests pass)
  ```
- **Screen Boundary Check:**
  ```bash
  git diff --stat frontend/lib/presentation/screens/
  # Output: empty (0 files changed)
  ```
- **Web Build:**
  ```bash
  flutter build web --no-tree-shake-icons
  # Output: Built build/web (exit code 0)
  ```
