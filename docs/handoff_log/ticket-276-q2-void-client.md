# Handoff Log: Ticket #276 (Slice 11-c — `q2.void-client`)

**Date**: 2026-09-20  
**Lane**: C (`team/3`, `PattaraponKitcharoen`)  
**Branch**: `feat/276-q2-void-client`  
**Spec References**: [`08_PHASE2_SPEC.md §12, §18`](../Backend_design/08_PHASE2_SPEC.md), [`09_PHASE2_LANES.md §3, §6`](../Backend_design/09_PHASE2_LANES.md), [`ADR-0010`](../Backend_design/adr/0010-client-write-through-cache.md)

---

## 1. Overview of Changes

Implemented client-side offline void handling for POS sales bills during Degraded mode under Slice 11-c (#276):

1. **Drift Schema Bump (v9 → v10)**:
   - Added `soldOffline` (`boolean().withDefault(const Constant(false))()`) and `voidReason` (`text().nullable()()`) columns to `Sales` table in `frontend/lib/data/db/tables.dart`.
   - Bumped `schemaVersion => 10` in `frontend/lib/data/db/database.dart` with `from < 10` migration adding the two columns.
   - Regenerated `database.g.dart` via `dart run build_runner build`.

2. **Repository Layer (`SalesRepository` & `ApiSalesRepository`)**:
   - `ApiSalesRepository._patchFromResponse`: Explicitly sets `soldOffline: false` for bills confirmed and answered by the server.
   - `ApiSalesRepository._saveOffline`: Explicitly sets `soldOffline: true` for bills created during Degraded/offline mode.
   - `SalesRepository.voidSaleOffline(String saleId, String reason)`:
     - Pre-validates non-empty mandatory reason, sale existence, not already voided, and no prior returns.
     - Atomically marks `sales.voided = true`, `voidedAt = now`, `voidReason = reason`.
     - Restores stock for all line items in `products`.
     - Reverses customer ledger (spend and points) and mechanic ledger (credit balance, sales, discount, markup).
   - `ApiSalesRepository.voidSaleOffline(String saleId, String reason)`:
     - Enforces `soldOffline == true`; rejecting online bills with `PosException('VOID_NEEDS_ONLINE', 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น')`.
     - Atomically updates Drift tables and inserts `sale.void_offline` op into `outbox_ops` with aggregates `['sale:<saleId>', if (shiftId != null) 'shift:<shiftId>']` and payload `{'saleId': saleId, 'reason': reason}`.
     - Triggers `syncService.refreshOutbox()`.

3. **Presentation Layer (`ReturnsScreen`)**:
   - Uses `SyncFacade` to reactively observe Degraded mode.
   - During `Degraded` mode:
     - Shows `'✕ ยกเลิกบิลออฟไลน์'` button **only** on bills where `soldOffline == true` and `!voided`.
     - Clicking `'✕ ยกเลิกบิลออฟไลน์'` prompts confirmation dialog with mandatory reason text field (validation error: `'กรุณาระบุเหตุผลในการยกเลิกบิล'`).
     - Online bills (`soldOffline == false`) do **not** display the offline void button during Degraded mode (`VOID_NEEDS_ONLINE`).
   - During `Online` mode:
     - Preserves standard `'✕ ยกเลิกบิลทั้งบิล'` behaviour.

4. **Automated Tests (`frontend/test/offline_void_test.dart`)**:
   - 9 comprehensive unit and widget test cases covering:
     - Full ledger and stock reversal on `SalesRepository.voidSaleOffline`.
     - Validation guards (empty reason, missing sale, already voided, has returns).
     - `ApiSalesRepository.voidSaleOffline` rejection of online bills with `VOID_NEEDS_ONLINE`.
     - `ApiSalesRepository.voidSaleOffline` writing `sale.void_offline` outbox op with payload and aggregates.
     - `ReturnsScreen` widget tests verifying button visibility across online vs degraded mode and soldOffline flags, as well as the mandatory reason dialog flow.

---

## 2. Verification Results

- `dart analyze`: Clean (0 issues).
- `flutter test test/offline_void_test.dart`: 9/9 tests passed.
- Regression test suite (`test/returns_repository_test.dart`, `test/api_returns_repository_test.dart`, `test/sales_repository_test.dart`, `test/api_sales_repository_test.dart`, `test/sync_service_test.dart`): 68/68 tests passed.
