# Handoff — #29 `p7` server-side reports (2026-09-12)

**Branch:** `29-p71-reports-server-side`  
**Current HEAD:** `f08af38` (`ticket 29 ...`) — local branch is one commit ahead of `origin/29-p71-reports-server-side`; nothing was pushed in this session. The commit appeared in the working tree after implementation even though this agent did not run `git commit`.  
**Issue:** [#29](https://github.com/NuimanLP/srisurart-pos-flutter/issues/29), parent [#8](https://github.com/NuimanLP/srisurart-pos-flutter/issues/8); use [#2](https://github.com/NuimanLP/srisurart-pos-flutter/issues/2) for shared invariants.

## Current state

- #29 is implemented in `server/src/reports/` and wired through `server/src/app.module.ts`.
- Added the six requested endpoints: summary, top products, by category, stock value, paginated low stock, and per-product sales.
- Production queries return SQL aggregates or bounded pages; they do not load sales, returns, or products wholesale into application memory.
- Every business-table query has an explicit `tenant_id` predicate in addition to the existing RLS request context.
- Date inputs accept only `yyyy-MM-dd` or `yyyy-MM`. PostgreSQL converts the resulting local calendar boundaries using `tenants.timezone`.
- Credit-note rows are negative item events, so revenue and quantity are netted using each return's own date, matching the client period convention.
- Gross profit and closing-report formulas were intentionally left out for the next slice.

Primary files:

- `server/src/reports/reports.dto.ts`
- `server/src/reports/reports.service.ts`
- `server/src/reports/reports.controller.ts`
- `server/src/reports/reports.module.ts`
- `server/test/reports.e2e-spec.ts`
- `server/src/app.module.ts`

Refer to `docs/Backend_design/02_API_SCREENS.md` §3.2, §3.9 and §9, plus `docs/Backend_design/01_DATABASE.md`; do not duplicate those contracts here.

## Decisions and assumptions

- Response field names follow the current Flutter calculations: `totalRevenue`, `totalTransactions`, `avgTicket`, `totalRefunds`, `netRevenue`, `totalItems`, and item-level `qty`/`revenue`.
- Average ticket remains gross sales divided by bill count and rounded to whole baht, as the current report screen does. Returns affect net revenue and net item quantity, not bill count or average ticket.
- Product/category revenue uses line price × quantity, matching the existing Dart calculation; proportional bill discounts remain represented only by `returns.refund_total` in summary KPIs.
- Historical lines are grouped by stable `product_id`, as required by `02_API_SCREENS.md`. Return labels are recovered from the parent sale line with a bounded lateral lookup.
- Low stock is paginated and ordered out-of-stock first. Top products is capped at the shared maximum limit of 200.
- A manually voided sale with no credit note is not separately subtracted. This matches the existing client calculation, while full returns are represented by credit notes. Revisit only if the owner decides direct voids must change report semantics.
- No report caching was added; that belongs to the later cache-invalidation slice rather than #29.

## Verification status

- Passed: Prettier check, TypeScript typecheck, and oxlint.
- `server/test/reports.e2e-spec.ts` was written to prove calculations, return netting, pagination, date boundaries, cross-tenant isolation, and the §9 p95 read budget over a 5,000-sale demo dataset.
- The user explicitly asked not to start a local test environment, so the PostgreSQL/Redis E2E suite was **not executed**. This is the main remaining verification step.
- No documentation other than this requested handoff was changed.

## Next steps

1. Run `server/test/reports.e2e-spec.ts` against the normal migrated PostgreSQL/Redis test stack or let CI execute it. Fix any SQL/runtime discrepancy before pushing.
2. Review the response shape against the consumer added by the frontend API-read slice; the design document specifies meanings but not a full JSON example.
3. Run the normal server lint, typecheck, unit, and complete E2E gates, remembering the documented single-runner database limitation.
4. Review the local commit, then push/open the PR only when authorised.
5. After #29 merges, #30 can implement gross profit and the closing report without reusing the deliberately excluded formulas here.

## Suggested skills

- `review` — run a focused correctness review of the SQL, tenant isolation, and diff before the PR.
- `review-security` — useful for a second pass on RLS plus explicit tenant predicates because report leakage is the highest-risk failure mode.
- `handoff` — update this record if runtime verification changes assumptions or response fields.

