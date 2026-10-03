# Session 2026-10-03 (evening) — live UX test on mob04, cash drawer, CI quality gates

Follows the morning handoff `session-2026-10-03-apk-private-ca-backup-upload.md` (PR #557,
which covers #551–#556); this file does not repeat it. Orchestrated session: live UX testing
on `mob04` (`https://172.30.58.20`) found the bugs, sub-agents fixed them in PRs.

**Verification note.** PR numbers, SHAs, merge times, CI results, the Deploy run and its
approval were checked against GitHub (`gh pr view`, `gh run view`, approvals API) and
`origin/main` while writing this. The **on-VM** facts — `.current_sha`, `/health/ready` and
the server rows behind the live drawer check — were verified by the orchestrating session
over ssh (`deploy@mob04`) / `psql`. The UI messages seen in the browser and the test-data
cleanup are as reported by that session; the writer of this file had no VPN to `mob04`.

## Merged this session

| PR | Merge | What |
|---|---|---|
| #578 | `55cf34a` | `DELETE /mechanics/:id` refused with `409 MECHANIC_HAS_BALANCE` while the mechanic owes credit; screen refuses before the confirm dialog. Thai string ratified (02 §8/§8.1) |
| #579 | `1835bca` | Flutter CI: silent-failure guard (`frontend/test/silent_failure_guard_test.dart`), coverage ratchet (`frontend/coverage_baseline.txt` = 71, `tool/coverage_check.sh`), `unawaited_futures`/`avoid_void_async` lints |
| #580 | `2411ebf` | A cash-out larger than the drawer's expected cash is refused: `409 DRAWER_INSUFFICIENT_CASH` computed under the shift lock (`server/src/reports/drawer-cash.sql.ts`); `/sync/push` `drawer.entry` replays are never refused; shared fixture `docs/Backend_design/fixtures/drawer-cash/agreement.json` |
| #581 | `a8a8080` | Server contract gates: client-request fixtures (`docs/Backend_design/fixtures/client-requests/`, recorded by `frontend/test/contract/client_requests_contract_test.dart`, replayed by `server/test/client-request-fixtures.e2e-spec.ts`), `deploy/scripts/check-migrations-immutable.sh`, actionlint + shellcheck in new job `ci-guards`, server coverage ratchet (`server/coverage-baseline.json`, `lines: 44`) |
| #582 | `da17ef9` | `flutter.yml` frontend filter also watches `fixtures/client-requests/**`; guard treats `drawerCash*` as reads — **unbroke `main`** (below) |
| #583 | `bffd3c3` | `AuthCubit` login / offline-PIN errors always end in a Thai error state |
| #584 | `48099f4` | Expected drawer cash counted **by shift** (owner decision 2026-10-03, replaces #452's time window); `cashCountFrom`/`drawerCashBetween` deleted; `DRAWER_INSUFFICIENT_CASH` strings ratified. Re-lands `4a5bfb6` |
| #585 | `11265b4` | Offline cash-out over the drawer, when replayed, creates owner review item `drawer_overdrawn_offline` (migration `1788652804800`, one item per entry). Label `เงินออกจากลิ้นชักเกินยอดตอนออฟไลน์` ratified by the owner 2026-10-03; `main` still carries the **agent ร่าง** marker until PR #587 flips it |

Also merged on 2026-10-03 between the two handoffs, by work not recorded in either file
(titles only, not reviewed here): #559 (CA cert commit), #560 (file_picker 13.1.0 for the
APK), #561/#567 (#476 device replace + pos-role banner), #562 (#558 enrol/session),
#563/#564/#570 (platform-ui / audit, #443), #565 (add-mechanic 400 hang), #566 (block
restore on API build), #568, #569/#571/#577 (reports net of returns/voids), #572 (PO
screen errors), #573/#574/#575/#576 (quotes → `POST /sales quoteId`, offline quote sync,
`quote_conflict`), #545 (CI failure research doc).

## Main went red — two green PRs, red together

#579 and #580 merged 29 s apart (14:21:21Z / 14:21:50Z). Each was green alone; together the
new guard read #580's `await shiftsRepo.drawerCash(...)` in `closing_report.dart` as an
unguarded **write**. Flutter CI failed on `main` at `2411ebf` and `a8a8080`; #582 (adds
`drawerCash` to `_readPrefixes`) made it green again at `da17ef9`. Lesson now in CLAUDE.md
and `07_CICD_DEPLOY.md §2c`: after a gate lands, rebase open PRs before merging.

## Merge-timing trap, again

- #580 merged at head `512c570`; `4a5bfb6` (by-shift rule + ratified string) was pushed to
  the branch afterwards and missed `main` → re-landed as `8c46b11` in #584.
- #579 merged at head `1124dd0`; `173c1d3` (fixture path filter) missed → re-landed in #582.

The rule (`gh pr view N --json headRefOid` at merge time) is already in CLAUDE.md; this
session only added these instances to it.

## Deploy

- Stale waiting Deploy run `37130734516` (`bffd3c3`) cancelled first.
- Deploy run `37132624209` for `11265b4` — approved by `NuimanLP`, `resolve release` and
  `deploy to demo` both `success` (verified via `gh`).
- Verified on the VM (orchestrator, ssh) right after that run: `/opt/pos/.current_sha` =
  `11265b4a33c7f815723d25e51953c4437d908413`, `/health/ready` 200.

## Live check on mob04 after the deploy

- Shift `shmusjiw4v_dd97e5ea_1`, opened 2026-10-03 15:22:12Z with starting cash ฿500.
- Cash-out ฿600 refused in the UI with `เงินในลิ้นชักไม่พอ (มี ฿500)`; ฿100 out accepted.
  **Verified (psql):** `drawer_entries` for that shift has exactly one row — `out`, `100.00`,
  `UX test เกินยอด` — so the refused ฿600 left nothing behind.
- Closing report drawer expected ฿400 (by shift; earlier shifts' cash not counted).
  **Verified (psql):** the shift was closed at 22:24 Bangkok (15:24Z) with counted ฿400 (the UI
  showed `ตรงยอด`).
- The UI pre-check stops an over-limit cash-out before any request, so the server's 409 path
  was **not** exercised live; it is proven by the e2e tests in #580/#584
  (`server/test/shifts.e2e-spec.ts`).

## Open

0. **PR #586** (open) — staff manual (`docs/tutorial/sri-pos-manual/`) synced with #578,
   #580, #583, #584, #585; owned by another agent, not touched here.
1. **Counted-cash field accepts non-digits.** On close, `a400` → `double.tryParse` gives
   `null`; the preview (`cash_drawer_screen.dart:745`, `?? 0`) shows `เงินขาด −฿400`, and
   `_handleClose` (`?? -1`, line 186) silently does nothing. Fix: **PR #587** (`fix/drawer-cash-input-and-ratify-overdrawn`,
   **open, not merged**) — money inputs reject letters. The owner **already ratified**
   `drawer_overdrawn_offline`'s label `เงินออกจากลิ้นชักเกินยอดตอนออฟไลน์` on 2026-10-03;
   #587 also carries that marker flip in 02/08 and `review_item.dart`. Until it merges,
   `main` still shows **agent ร่าง** — a stale marker, not a pending owner question; do not
   flip the docs separately.
2. **Owner question — a shift open past midnight.** Counting is by shift, but the drawer
   screen and the closing report only show a shift whose `dateStr` is today
   (`cash_drawer_screen.dart:93-96`, `closing_report.dart:104`), so after midnight the shift
   disappears from both. Not answered; recorded in `08_PHASE2_SPEC.md §11`.
3. **Out-of-order offline replay.** An op re-sent after the next shift opened counts in the
   new shift on the server but in its original shift on the client (already in 08 §11).
4. **Cosmetic, not fixed:** the park-bill message is a red warning banner
   (`checkout_screen.dart:377`, `_warn('⏸ พักบิลแล้ว…')`); opening a shift with float ฿0 is
   refused (`_handleOpen`, `!(v > 0)` → `กรุณากรอกเงินตั้งต้นให้ถูกต้อง`); a Thai name shown
   twice on some screen (reported; screen not identified).
5. **CI gap:** `flutter.yml` does not watch `docs/Backend_design/fixtures/drawer-cash/**`
   (`07 §2c`).
6. **Windows-only e2e failures** reported by sub-agents (platform-cli, backup-restore,
   stock-race-three-writers); green on Linux CI. Not investigated.

## Test data left on mob04 (reported)

Test shifts closed; test customers/mechanics deleted (M002 was soft-deleted while owing ฿150,
before #578 existed); a converted quote and a received PO cannot be deleted by design;
RC/CN documents remain as history.

## Docs changed by this handoff PR

- `CLAUDE.md`: CI quality-gate rule block; offline over-draw review item on the cash-out
  rule; the 2026-10-03 merge-timing instances. The by-shift drawer rule was already updated
  by #584.
- `07_CICD_DEPLOY.md`: new §2c (gate table, `ci-guards` trigger, the drawer-cash filter gap,
  the red-together lesson).
- `08_PHASE2_SPEC.md §11`: the past-midnight open question.
- 01/02 already matched `main` (review kind 8 + migration `…4800`, `MECHANIC_HAS_BALANCE`,
  `DRAWER_INSUFFICIENT_CASH`).
