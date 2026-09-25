# Handoff — 2026-09-25: study pack + slide deck + security/bug-fix PRs

Read the root `CLAUDE.md` first (binding rules). The owner wants reports **extremely concise**, and writes in Thai.

## Round 3 (2026-09-25, late) — read this first
**Merged (round 2):** #415 docs sync · #416 dev-only passwords inside connection URLs ·
#418 customer non-Map responses + reload→init test · #419 web localStorage token fallback
removed, **closes #400** (owner decision 2026-09-25, ADR-0009 addendum; Thai text of
`TokenStoreUnavailableException` ratified) · #420 OwnerReviewItems RLS/FK fix migration
`…4200` + quotes purge validate-first · #421 login releases the pool connection before argon2, admin
pool = 2 (budget 70 ≤ 80) · #422 `TokenStoreUnavailableException` passes through the API repos ·
#423 targeted Drift queries (`saveSale`/`receivePO`/partNo dup) · #424 backup export
written to a file + `GET /backup/jobs/:id/download` (no longer in `redis-queue`).

**Open — merge next (all agent-reviewed: karpathy → scrutinize → code-review):**
| PR | What | Note |
|---|---|---|
| #426 | login timing: dummy argon2 for unknown username (closes #425) | still leaks via inactive/suspended/ambiguous messages + legacy PBKDF2 admin hashes — owner/UX call |
| #427 | Reports / Closing / Cash drawer load only the date range (Refs #417) | parity tests prove identical numbers |
| #428 | `docs/study/*` factual sync | docs only |
| #429 | server: no `count(*)` on sync pages, products `(tenant_id, updated_at, id)` index `…4300`, shift-history N+1 | `meta.total` dropped on sync pages (client never read it) |
| #430 | Drift schema **v12**: 10 indexes (Refs #417) | CLAUDE.md says lane B owns Drift bumps → lane-B review; may conflict with #427 in `CONTRACT.md` |

**#417** was taken over by lane A (`team/1`, NuimanLP) on 2026-09-25. After #427/#429/#430 merge,
the only part left is tenant-import row-by-row INSERTs (one-time job, deliberately skipped) and
a `movements.date` index (not added). Close #417 then, or split those two out.

**Still on the owner / humans:**
- Post the `ALLOW_DEV_SECRETS` lane announcement (draft at the end of this file). Check that
  `DEMO_ENV_FILE` for mob04 has no `dev-only-*` or dummy JWT pair — #412/#416 refuse to boot on them.
- Owner decisions still open: `08 §11` `POST /shifts/open` `openedAt` vs §10; the client never
  patches `receiptNo` from an `applied` push (#413); `clampOpDate` is silent and `shift.open`
  has no `date_flag` (#414); unify the login error messages (#426).
- Merge is manual: the auto-mode classifier refuses `gh pr merge`, even when asked. Add a Bash
  allow rule `Bash(gh pr merge:*)` to let an agent merge.

## State (updated 2026-09-25, post-merge sync — round 1, historical)
- **Study pack:** a 19-chapter Thai study pack and a 103-slide deck were built.
- **Review findings:** reviewing the pack surfaced security gaps and HIGH bugs. They were filed as issues and fixed in separate PRs.
- **All 9 PRs below are now merged to `main`** (UTC times via `gh pr view N --json mergedAt`):

  | PR | Fixes | Merged (UTC) |
  |---|---|---|
  | #405 | — (CLAUDE.md drift, stale comments, dead code) | 2026-09-25T09:26:21Z |
  | #406 | #399 | 2026-09-25T09:15:00Z |
  | #408 | #402 | 2026-09-25T09:16:04Z |
  | #413 | #409 | 2026-09-25T09:16:29Z |
  | #414 | #411 | 2026-09-25T09:17:01Z |
  | #403 | #401 | 2026-09-25T09:32:31Z |
  | #397 | docs (study pack) | 2026-09-25T09:33:01Z |
  | #404 | refs #400 | 2026-09-25T09:36:00Z |
  | #412 | #410 | 2026-09-25T09:38:46Z |

  (#407, fixing #398, merged earlier the same day at `39e86c4` — see original note below.)
- **What remains:**
  - **#400 stays open** — the localStorage-fallback owner decision is still pending (see
    "Owner decisions pending" below); PR #404 shipped the fix but did not close the issue.
  - **#412's pre-merge announcement was never posted** — see the "Lane announcement" section
    at the end of this file (draft only).
  - The "Follow-ups found by the review agents (not done)" and "Owner decisions pending"
    sections below are still open as written, except `02_API_SCREENS.md:856` (`OFFLINE_NOT_ALLOWED`
    still listed live) — struck through 2026-09-25 in the post-merge-sync docs pass.
- **Local cleanup:** all local agent worktrees and temp branches were deleted. Every PR branch now lives only on GitHub.

## Artifacts (reference — don't duplicate)
- **Study pack:** `docs/study/00_index.md` … `18_capstone.md`, in PR #397. The PR body lists everything found while writing.
- **Slide deck:** https://claude.ai/artifact/HaUsgrPsfhuULnAs9zojpQ (private, v3). Only `c02-big-picture` and `c15-pipeline` were hand-adjusted. The other diagram slides were never visually checked.
- **Issues opened this session:** #398 (closed by #407), #399–#402, #409–#411.

## Update 2 (same day, later session) — unfinished work done, still unmerged
- The three items below were finished by agents (karpathy-guidelines → scrutinize → tests → code-review) and **pushed to their PR branches**. Nothing was merged: the auto-mode classifier blocked `gh pr merge` again, **even with an explicit owner request**. A human must merge, or add a Bash allow rule for `gh pr merge`.
- **All 9 open PRs: `CLEAN`, `flutter-ci-status` + `server-ci-status` pass** (checked 2026-09-25).

## PRs still open (historical — all 9 merged 2026-09-25; see State above)
| PR | Fixes | Head | Status / notes |
|---|---|---|---|
| #406 | #399 | `deebc50` | ready — revokes UPDATE/DELETE on `audit_log` from `pos_app` |
| #408 | #402 | `c64dfab` | ready — closing report uses `costAtSale` |
| #413 | #409 | `9f5df27` | ready — push replays online-committed bill; `isTransportFailure` now also in customers (`addCustomer`/`updateCustomer`) + mechanics (`addCreditPayment`); `PosException` passes through. `syncFromServer` `catch (_)` left alone on purpose (read-path cache fallback, not a write) |
| #414 | #411 | `5ecab04` | ready — online routes use server `now()` |
| #405 | — | `f2d91c5` | ready — **rebase after #413**; #413 grew, so expect more than the one catch-comment conflict (keep #413's side) |
| #403 | #401 | `ca3dd20` | ready — **rebase after #405** (`deploy/compose/monitoring.yml` comment — keep both) |
| #397 | docs | this branch | ready — study pack + this handoff |
| #404 | Refs #400 | `2312c7b` | bug fixed (IndexedDB mirrors localStorage while marker unset; 2 fail-first tests). **Owner decisions still open** (below) |
| #412 | #410 | `d96b896` | reworked: gate = `ALLOW_DEV_SECRETS === 'true'` (not `NODE_ENV`); also refuses public dummy JWT pair (sha256 match) + dev `BULL_BOARD_PASSWORD`; `vm.override.yml` forces it empty on mob04 |

**Merge order:** 406 → 408 → 413 → 414 → 405 (rebase) → 403 (rebase) → 397 → 404 → 412.
- Branch protection is not strict; required checks are `flutter-ci-status` and `server-ci-status`.
- Merging to `main` queues `Deploy (demo)`, which waits for reviewer approval.

### 🔴 Before merging #412
- **Announce to all lanes:** every existing `server/.env` lacks the flag → api/worker/bull-board refuse to boot until `echo 'ALLOW_DEV_SECRETS=true' >> server/.env`.
- **Verify mob04's `DEMO_ENV_FILE`** has no `dev-only-*` value and not the dummy JWT pair (handoff says randomized; unverified).
- Full e2e not run locally (compose subnet clash); CI `integration` passed.
- Not covered (deferred): `POS_APP_PASSWORD`/`REDIS_PASSWORD` (only inside connection URLs), `DATABASE_ADMIN_URL` carrying `dev-only-postgres`. #410's "decision per secret" AC is recorded only in code comment + PR body.

### Follow-ups found by the review agents (not done)
- #404: `auth_cubit.dart:150/:257/:278` duplicate `_pinRepo` device-role fallback now done by `AuthRepository`; no reload → `AuthCubit.init` → logged-in test; two-tab (normal + fallback) logout only clears localStorage.
- #413: `updateCustomer` silently ignores a non-Map PATCH response; `api_mechanics_repository.dart:505` `catch (_) { break; }` in flush loop (not a write-fallback bug); narrowing block now duplicated 4×.

## Owner decisions pending
- #404: keep or remove the localStorage fallback before first successful migration (keeping contradicts ADR-0009:101 → needs ADR addendum). Kept as-is for now.
- #404: approve Thai text of `TokenStoreUnavailableException` (agent draft, not in `02_API_SCREENS.md §8`).
- `docs/Backend_design/08_PHASE2_SPEC.md §11`: its `POST /shifts/open` row lists `openedAt` in the body, which contradicts §10. #414 followed §10.
- PR follow-ups:
  - The client never patches its local `receiptNo` from an `applied` push (#413).
  - `clampOpDate` maps an invalid device date to `now()` silently, and push `shift.open` has no clamp or `date_flag` (#414).
  - ~~`02_API_SCREENS.md:856` still lists `OFFLINE_NOT_ALLOWED` (#405).~~ — struck through
    in the post-merge-sync docs pass, 2026-09-25.

## Gotchas learned
- **`gh pr edit`** fails with a Projects (classic) GraphQL error. Use `gh api -X PATCH repos/NuimanLP/srisurart-pos-flutter/pulls/<n> -F body=@file` (or `-f base=main`).
- **Parallel e2e:**
  - The compose file pins subnet `172.30.0.0/24`, which an old stopped network already holds (don't delete it).
  - Use a unique `-p`, an override subnet and distinct host ports, and tear down only your own project.
  - `--wait` exits 1 because the one-shot jobs exit.
- **Flaky under a shared Docker host:** `import-snapshot` and `stock-race-three-writers` e2e time out when other stacks share Docker. They pass when run alone.
- **Review sub-agents:** those spawned by a sub-agent notify the orchestrator, not their parent, so relay their results with SendMessage.
- **Empty CI logs:** `gh run view --log` can come back empty. Use `gh api repos/.../actions/jobs/<id>/logs`.

## Suggested skills
- **`scrutinize`:** before redoing the #412 design and before merging.
- **`andrej-karpathy-skills:karpathy-guidelines`:** for the three unfinished fixes (minimal diffs).
- **`tdd`:** for the #404 migration bug and the #413 extension (tests that fail first).
- **`code-review`:** on each branch vs `origin/main` before merging.

## Lane announcement (draft — not posted)

_Written 2026-09-25 during the post-merge docs sync, per PR #412's "Announce to all lanes"
requirement. Not sent to any channel — the owner/lane leads decide where and when to post it._

> 📢 **แจ้งทุก lane: ต้องเพิ่ม `ALLOW_DEV_SECRETS=true` ใน `server/.env` (dev เท่านั้น)**
>
> PR #412 (แก้ #410) เพิ่มการเช็ค: ถ้า `server/.env` ของเครื่อง dev ยังมี secret แบบ
> `dev-only-*` หรือคู่ JWT ตัวอย่างสาธารณะ ระบบจะ **ไม่ยอมให้ api / worker / bull-board
> เริ่มทำงาน** จนกว่าจะตั้ง flag ยืนยันว่ารู้ตัวแล้ว
>
> **ต้องทำ (เฉพาะเครื่อง dev):**
> ```
> echo 'ALLOW_DEV_SECRETS=true' >> server/.env
> ```
>
> 🔴 **ห้ามตั้งค่านี้บนเครื่องจริง (VM/production) เด็ดขาด** — `vm.override.yml` บังคับ
> ค่านี้เป็นค่าว่างบน `mob04` อยู่แล้ว เพื่อกันไม่ให้ secret ตัวอย่างหลุดขึ้นเครื่องจริงโดยไม่ตั้งใจ
>
> มีคำถามทักในช่องทีมได้เลยครับ/ค่ะ
