# Session 2026-09-24 — whole-codebase review, ER diagram fix, docs wrap-up

**Base:** `main` at `2c2dd6f` → ends at the merge of this PR.
**Merged this session:** PR #390 (`630574a`, Backend_design re-sync) · PR #393 (`3152a84`, ER
diagram) · PR #394 (`85e9b3a`, testing tutorial) · this wrap-up PR.
**No code changed.** Every finding below is recorded, **none is fixed, none has a GitHub issue yet.**

## 1. Ultrareview cannot review a whole repo

`/code-review ultra` (and the deprecated `/ultrareview`) reviews a **diff** — the current branch
against `main`, or one PR. Run on `main` it has nothing to review and cancels. A whole-codebase
review was done instead with the local `/code-review` skill, using git's empty tree
(`4b825dc642cb6eb9a060e54bf8d69288fbc4f7d0`) as the fixed point: ~115k lines of Dart + TS,
excluding `*.g.dart` and `docs/`. Two sub-agents (Standards / Spec), each capped at ~400 words —
so this is a **sampled** review, not an audit. A clean area here is not proof of no bugs.

## 2. Spec findings (vs `08_PHASE2_SPEC.md`, ADRs, `CONTRACT.md`)

Items 1–2 re-verified by reading the code after the review.

1. 🔴 **HIGH — `/sync/push` fingerprint ≠ online route's.** 08 §8.3 step 1 requires the same
   fingerprint as the online route. `sync.service.ts:201-229` (`endpointForOp`) stores
   `'POST /sales'`; the online runner (`idempotency.runner.ts:40`,
   `${req.method} ${req.baseUrl}${req.path}`) stores `POST /api/v1/sales`. `decide()` treats an
   endpoint mismatch as `reused` → a bill committed online whose reply was lost, then pushed,
   gets `IDEMPOTENCY_KEY_REUSED` instead of `applied`. That is 08 §8.4 AC **B1**; the existing
   test (`sync-push.e2e-spec.ts:~1238`) only covers push→push.
2. 🔴 **HIGH — online routes trust client `date` / `soldOffline`.** 08 §10: online route uses
   `now()`, never the body's `date`. `sales.service.ts:777` stores `COALESCE($18, now())`;
   returns (`returns.dto.ts:73`) and shifts (`openedAt`, `createdAt`) do the same, and the client
   does send `date` online (`api_sales_repository.dart:233`). A body with `soldOffline:true` also
   skips the online `SALE_VOIDED` refusal and becomes voidable via `sale.void_offline` (§12
   `VOID_NEEDS_ONLINE`).
3. MED — push reply for `sale.create` (`sync.service.ts:548-554`, `:276-282`) omits
   `costAtSale`, `movements`, `shiftId`, `date`, customer/mechanic balances that 08 §8.2 says it
   carries. The fixture `fixtures/sync-push/sale-create.applied.json` has the same thin shape —
   **spec vs contract disagree; owner call** which one is right.
4. MED — the client only queues `sale.create`, credit payments and customer ops; 08 §6.1 also
   lists `shift.open`, `return.create`, `drawer.entry`. `api_shifts_repository.dart:80-87` sends
   no client `id`/`openedAt`; shift close checks only queued credit payments (§11 wants the whole
   outbox).
5. MED — Drift `openShift` still returns the same-day shift (`shifts_repository.dart:69-83`),
   removed by 08 §11.
6. LOW — online `POST /shifts/open` with an existing `id` does not compare `startingCash`
   (`shifts.service.ts:170-180`); the push path does.

Still unfixed from before: the two `1788652803002-OwnerReviewItems.ts` bugs (`NULLIF`, FK
`SET NULL`) — see `CLAUDE.md` "Still open".

## 3. Standards findings (vs `CLAUDE.md` binding rules + Conventions)

1. Validate-then-clamp broken: `quotes.controller.ts:113`
   `Math.max(1, Number(dto?.olderThanDays ?? 90))` on an unvalidated TS-interface body — `-30`
   silently purges nearly all quotes. Same clamp in `maintenance.processor.ts:100`.
2. `ApiException` reaches a screen: `offline_pin_setup_dialog.dart:134-139` shows `e.toString()`.
3. Private `DateFormat('dd/MM/yyyy HH:mm')` → Gregorian year, not พ.ศ.: `devices_screen.dart:27`,
   `owner_review_screen.dart:307,651` (+ missing `.toLocal()` at `:385`, `:704`).
4. Inline ฿: `cart_cubit.dart:114`, `quote_a4_view.dart:574` (`_money` duplicates `baht()`),
   `label_printer.dart:42-50`.
5. Judgement calls: API repos split across `repositories/api/` and `repositories/api_*.dart`;
   `catch (_) {}` in `api_mechanics_repository.dart:~287` can inflate projected credit;
   `GREATEST(0, …)` on void reversals (`void.service.ts:218-240`) hides corruption; Thai strings as
   status enums; platform endpoints return English errors.

Checked and in line: `runTx` has no tenant arg, concrete-path idempotency fingerprint, lock order
on void/returns, `db.js` sale/return invariants, void = reason only, device-token push auth,
doc numbering.

## 4. ER diagram (`01_DATABASE.md §3`) — PR #393

The warning above the diagram was not enough: `tenant_id PK` + `id PK` on two rows still read as
two primary keys. Multi-column keys now carry **no** `PK`/`UK` label; the columns get a comment
`"PK ร่วม (tenant_id, id)"` / `"UNIQUE (tenant_id, receipt_no)"` and `tenant_id` is labelled `FK`.
Only `TENANTS` keeps `PK`/`UK` (single-column keys). Checked against `InitialSchema`; all three
diagrams render in mermaid-cli. The matching `CLAUDE.md` rule was rewritten.

## 5. Housekeeping

- Deleted merged branches `docs/01-database-sync-migrations`, `docs/er-diagram-composite-pk`,
  `docs/testing-tutorial` (each checked with `git merge-base --is-ancestor` first).
- `experiment/quality-gate` (a worktree under another session's scratchpad) was fast-forwarded to
  `main`. It holds **uncommitted** CI changes (`flutter.yml`, `server.yml`, `server/package.json`,
  `vitest.config.ts`, new `nightly.yml`, `scripts/`) — untouched, not reviewed, not merged.
- `.claude/settings.local.json` has a local uncommitted edit — left alone (personal settings).

## Next

- Open GitHub issues for spec findings 1 and 2 (owner-facing; not done this session).
- Owner decides spec finding 3 (spec vs fixture).
