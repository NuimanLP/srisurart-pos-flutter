# Idempotency and the client write path

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `server/src/idempotency/`, `frontend/lib/data/repositories/api*`, outbox, PendingWrites, drawer cash, returns, settings writes, doc numbers.

**Idempotency & the client write path (`server/src/idempotency/`, `frontend/lib/data/repositories/api*`):**
- The idempotency fingerprint is the **concrete request path**, never `req.route.path`
  (the pattern) — a reused key on two different bills must not collide.
- Only a **4xx is a verdict** (`isVerdict`); a 5xx, a 429, or a lost/timed-out reply
  means the write's fate is unknown — never fall back to a local write on anything but a
  genuine transport failure (`ApiTimeoutException` included). `api_repository_contract_test.dart`
  enforces this over both `data/repositories/api/` and `data/repositories/api_*.dart`.
- An `ApiRepository` never calls a Drift transactional service (double stock decrement).
- An `ApiException` must never reach a screen — convert via `rethrowThai` /
  `rethrowServerRefusal` to a plain Thai-string `Exception`/`PosException`. Enforced since
  2026-10-06 by `presentation_no_api_exception_test.dart` (no import in `presentation/`) and
  `api_exception_never_escapes_test.dart` (no repository lets one out at runtime).
- The bill id and `Idempotency-Key` are minted **once per cart**, not once per call
  (`PendingWrites` parks the attempt); a fresh id+key on retry defeats both server
  defences and double-rings the sale.
- Consent (e.g. `overrideCreditLimit`) is carried explicitly from a dialog the counter
  was actually shown — never inferred by re-running a stale local check.
- Money crosses the wire as the string `"1234.50"`; a field the response omits leaves
  its row alone — the online customer/mechanic patch and the `/sync/push` reply patch
  share `patchCustomerAfter`/`patchMechanicAfter` (`api_wire.dart`, #455) for this.
- **Closing a shift needs the whole outbox empty** (08 §11, #456): `ApiShiftsRepository.closeShift`
  first sends what it can (the outbox via `SyncService` when wired, else only queued credit
  payments), then refuses with `OUTBOX_NOT_EMPTY` while **any** `outbox_ops`
  row remains — `pending`, `stuck` or `rejected`, of any type — and the close button is
  disabled while `outboxRemaining > 0`. The server cannot see the outbox, so this check is
  client-only; never narrow it back to one op type (it replaced the cash-credit-only
  `CASH_CREDIT_PAYMENTS_UNSENT`). Its Thai string was ratified by the owner 2026-09-27.
- **Expected drawer cash is counted BY SHIFT** (owner decision 2026-10-03, PR #580;
  history: #452/PR #469 counted a time window — the day's first shift from midnight, a
  later one from its opening — via `cashCountFrom`, now deleted). Every baht taken or paid
  while a shift is open belongs to that shift, even past midnight — the server's
  `shift_id` rule (`server/src/reports/drawer-cash.sql.ts`, shared by `GET /reports/closing`
  and the cash-out refusal). Client: `ShiftsRepository.drawerCash` is the only rule — the
  cash-drawer screen, the closing report's drawer check and `assertCashOutFits` all use it.
  Attribution: drawer entries by `shiftId`; sales by `Sales.shiftId`, or (no `shiftId`, the
  Drift build) by `date` in the shift's `[openedAt, closedAt]`; returns and credit payments
  (no local shift column) by `date` in that interval; credit payments only when
  `isCashCreditPayment()`. Both sides must keep passing
  `docs/Backend_design/fixtures/drawer-cash/agreement.json`. Never compute expected cash a
  second way; the report's revenue/payment/top-item sections stay whole-day.
- **A cash-out larger than the drawer's expected cash is refused** (owner 2026-10-03,
  PR #580): `409 DRAWER_INSUFFICIENT_CASH` online, `PosException` on the Drift build and the
  API build's offline queue; a `/sync/push` `drawer.entry` replay is never refused (the cash
  already left) — one that takes the shift's expected cash below zero files one owner review
  item `drawer_overdrawn_offline` per entry (PR #585, migration `1788652804800`).
- **Returns share one pure rule set:** `planReturn()` + `refundedQtyOf()`
  (`return_plan.dart`) are used by both `ReturnsRepository` and `ApiReturnsRepository`;
  the offline `return.create` numbers its CN inside the local transaction, after every
  guard, and refuses `OFFLINE_SEED_REQUIRED` rather than guess a `device_no` (#469).
- **Settings writes are online-only on the API build** (#460, PR #467):
  `ApiSettingsRepository.updateSettings` is `PATCH /settings` with an `Idempotency-Key`,
  refuses when Degraded, and writes Drift **only** from the server's accepted reply —
  never a local-first write, never on a failure; `pullFromServer` (`GET
  /settings`) runs on app open/login and again from `triggerEntityPull`
  (`SyncService.onPull`) on reconnect (#474, fixed).
  🔴 **Do not wire `BootstrapService.bootstrap()` as it stands** — its product upsert
  skips the pending-outbox stock guard (08 §15), nulls `zone`, and its settings mapping
  reads `shopNameEN` where the server sends `shopNameEn` and ignores `quoteValidDays`
  (the `bootstrap_service.dart` header names the stock guard; all three are in PR #467's
  body).


## From the phase-1 "Still open" log (binding rules)

- **5xx does not queue — owner decision 2026-09-27, `08 §5` amended (PR #469).** On the
  API build a 5xx/429 leaves the attempt parked (same id + key) and shows the error, for
  sales, shifts and returns alike — and since PR #645 (2026-10-06) customers and credit payments,
  since PR #657 (2026-10-07) `adjustStock` too (parked with `PendingWrites`, no offline queue); only a
  transport failure queues to the outbox. Two rules came with #657 (`08 §5`, owner 2026-10-07): a
  parked attempt closes **only after the local apply succeeded** (a failed apply keeps it parked,
  else the next press mints a new key = a duplicate), and a **new, different edit of a record
  supersedes that record's older parked edits at send time** (`PendingWrites.closeWhere`; a PATCH
  replaces whole values, so the older edit gets a fresh key instead of replaying a stale reply).
  A credit-payment retry re-sends its parked body and skips the local overpayment check.
  `PendingWrites` TTL = 10 min by design — past that a repeat is a new action.
- **#489/#490 fixed 2026-09-28** (PR #491, PR #492) — an online-issued `receiptNo`/`cnNo`
  was never written to the local `DocCounters`, so an offline sale/CN after an online one
  could reissue a number the server had already given out. **Rule: any RC/CN number the
  server issues — the online reply *and* a `/sync/push` replay — must be committed into the
  local `DocCounters` via `DocNumberService.commitServerIssued`** before offline issuing can
  trust its own high-water mark (offline issuing depends on it) — `ApiSalesRepository
  ._patchFromResponse` and `ApiReturnsRepository`'s equivalent do this today. 🔴 **The
  `/sync/push` replay half of that rule (`SyncService._patchDocNo`) was pushed as commit
  `dbaa7e5` *after* PR #491/#492 had already merged, so it never reached `main` from those
  two PRs** — verified 2026-09-28 by diffing `main` against `dbaa7e5`: `sync_service.dart`
  on `main` had no reference to `DocNumberService` at all. Cherry-picked into **PR #494**
  (`fix/489-push-replay-counter`, open, not merged) — its own replay tests fail without the
  commit. 🔴 **Lesson: check a PR's head SHA at merge time
  (`gh pr view N --json headRefOid`) — a review-fix pushed after the merge button is
  clicked silently misses `main`, and the PR body describing it reads as done when it
  isn't.** Recurred 2026-10-03 (#551/#552, #579, #580, #587 — see
  `handoff_log/session-2026-10-03-ux-test-drawer-ci.md`) 2026-10-05 (#611 auto-squashed
  at `03eb17a`, review fixes `49cd4c0` pushed 12 min later; recovered by PR #613) and 2026-10-07
  (#654 auto-merged 07:56Z at head `3b251a0`, its k6 review-fix commit pushed after; recovered by
  PR #655) — so no auto-merge while an agent is still pushing review fixes. 🔴 **Same trap on the branch side (found 2026-09-30):** before deleting a
  merged-PR branch, compare its tip with the PR's `headRefOid` — a mismatch means commits
  pushed after the merge that may exist nowhere else. That is how PR #486's review fix
  (`_writeGen` guard against a stale `GET /settings` clobbering a newer `PATCH`, commits
  `47653b1`/`c57019a`, pushed after the 2026-09-28 01:21:43Z merge) was found and recovered by PR #521
  (`ca2fef1`). This unblocked #490: `ensureSeedMarker`
  now accepts a seed from **any** period, so an offline sale after a month rollover starts
  at `0001` instead of refusing with
  `ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์` (08 §9 E8).
  #488 (discard exactness / `void_offline` follow-up) closed 2026-09-28.
