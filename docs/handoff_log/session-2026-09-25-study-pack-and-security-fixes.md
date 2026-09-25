# Handoff — 2026-09-25: study pack + slide deck + security/bug-fix PRs

Read the root `CLAUDE.md` first (binding rules). The owner wants reports **extremely concise**, and writes in Thai.

## State
- **Study pack:** a 19-chapter Thai study pack and a 103-slide deck were built.
- **Review findings:** reviewing the pack surfaced security gaps and HIGH bugs. They were filed as issues and fixed in separate PRs.
- **Merged:** only **#407** (fixes #398), merge commit `39e86c4`.
- **Why merging stopped:** the Claude Code auto-mode permission classifier blocked further merges ("Merge Without Review"). The remaining PRs need a human merge.
- **Local cleanup:** all local agent worktrees and temp branches were deleted. Every PR branch now lives only on GitHub.

## Artifacts (reference — don't duplicate)
- **Study pack:** `docs/study/00_index.md` … `18_capstone.md`, in PR #397. The PR body lists everything found while writing.
- **Slide deck:** https://claude.ai/artifact/HaUsgrPsfhuULnAs9zojpQ (private, v3). Only `c02-big-picture` and `c15-pipeline` were hand-adjusted. The other diagram slides were never visually checked.
- **Issues opened this session:** #398 (closed by #407), #399–#402, #409–#411.

## PRs still open
| PR | Fixes | Status / notes |
|---|---|---|
| #406 | #399 | ready — new migration revokes UPDATE/DELETE on `audit_log` from `pos_app` |
| #408 | #402 | ready — closing report uses `costAtSale` |
| #413 | #409 | ready — push replays an online-committed bill by client id; narrowed `catch (_)` (`isTransportFailure`) |
| #414 | #411 | ready — online routes use server `now()` |
| #405 | — | ready — CLAUDE.md drift, stale comments, dead code; **rebase after #413** (conflict in the `api_sales_repository.dart` catch comment — keep #413's side) |
| #403 | #401 | ready — compose image digests; **rebase after #405** (comment conflict in `deploy/compose/monitoring.yml` — keep both) |
| #397 | docs | ready — study pack (merge last) |
| #404 | Refs #400 | **not ready** — bug below + owner decision |
| #412 | #410 | **not ready** — rework below; base already retargeted to `main` |

**Merge order:** 406 → 408 → 413 → 414 → 405 (rebase) → 403 (rebase) → 397, then #404 and #412 after their fixes.
- Branch protection is not strict; the required checks are `flutter-ci-status` and `server-ci-status`.
- Merging to `main` queues `Deploy (demo)`, which waits for reviewer approval.
- The 2nd cross-PR review merged all of these together locally: typecheck, lint, unit, `dart analyze` and `flutter test` passed. Full e2e was **not** run on the merged tree.

## Unfinished work (agents stopped; nothing pushed — start from each PR branch)

### 1. #412 — rework (blocker)
The refusal is keyed off `NODE_ENV=production`, but `server/Dockerfile` sets that unconditionally.
- **Symptom:** the documented quickstart (`cp .env.example .env && docker compose up`) crash-loops `api`/`worker`, because dev `.env` files keep `dev-only-*` values (`docs/handoff_log/ticket-336-env-secrets.md:80-99`).
- **Fix:** use an explicit opt-out instead.
  - Add `ALLOW_DEV_SECRETS=true` to `server/.env.example`, with a "never on a real host" comment.
  - Pass it through `x-app-env` as `${ALLOW_DEV_SECRETS:-}`.
  - Refuse `dev-only-*` values unless it is exactly `true`.
- **Also refuse:**
  - the public dummy `JWT_PRIVATE_KEY`/`JWT_PUBLIC_KEYS` from `.env.example` (they let anyone forge tenant tokens);
  - `BULL_BOARD_PASSWORD`, read in `server/src/bull-board.ts`.
- **Note:** `build-image`/smoke runs on `main` only, so PR CI does not exercise the image.

### 2. #404 — IndexedDB migration bug
Sequence that triggers it:
1. A partial migration writes the IndexedDB copy, but the `auth_tokens_in_store` marker is still unset.
2. A later run in fallback mode logs out or unbinds, which clears localStorage only.
3. The next good run revives the stale IndexedDB token.

**Fix** (in `frontend/lib/data/storage/token_storage.dart`): while the marker is unset, make IndexedDB mirror localStorage. Delete IndexedDB keys that are absent from localStorage before setting the marker. Keep the rule that localStorage is never deleted before a verified IndexedDB write. Add fake-store tests.

**Owner decision:** keep or remove the localStorage fallback that applies before the first successful migration. Keeping it contradicts ADR-0009:101, so it needs an ADR addendum.

### 3. #413 — extension
- **Same bug elsewhere:** the broad `catch (_) → offline` pattern also exists in `frontend/lib/data/repositories/api/api_customers_repository.dart` (~:262, ~:338) and `api_mechanics_repository.dart` (~:173, ~:374). Apply `isTransportFailure` there.
- **Typed exceptions:** let `PosException` (and `TokenStoreUnavailableException` from #404) pass through instead of becoming the generic unreadable-response message.
- **Where to do it:** in a new PR if #413 is already merged.

## Owner decisions pending
- The #404 fallback (above).
- `docs/Backend_design/08_PHASE2_SPEC.md §11`: its `POST /shifts/open` row lists `openedAt` in the body, which contradicts §10. #414 followed §10.
- PR follow-ups:
  - The client never patches its local `receiptNo` from an `applied` push (#413).
  - `clampOpDate` maps an invalid device date to `now()` silently, and push `shift.open` has no clamp or `date_flag` (#414).
  - `02_API_SCREENS.md:856` still lists `OFFLINE_NOT_ALLOWED` (#405).

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
