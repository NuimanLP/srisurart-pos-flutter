# Handoff: merge #41/#42 into `main`, lane → GitHub-handle assignment, doc reorg fixes

**Date:** 2026-09-07
**Project path:** `/Users/chav_sir/Downloads/srisurart-pos-flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch `main`
**Previous handoff:** [`p2-schema.md`](p2-schema.md)

## What this session was

Four things, in order: merge PR #41 into `main`; attempt to merge PR #42 (blocked, see below);
assign all 31 phase-1 backend/CI issues to real GitHub handles, replacing the `team/1|2|3`
placeholders; fix a doc/directory reorg that happened on disk mid-session, outside this agent's
control. No application or server code was written.

## What happened, in order

1. **PR #41 (`feat/p1-compose-stack` → `main`) squash-merged.** CI was green
   (`analyze + test`, `drift codegen`, both required). Merge commit `c47c74e`.
2. **PR #42 (`feat/p2-schema`, stacked on #41) could not merge as-is.** Its base was still
   `feat/p1-compose-stack` (GitHub only auto-retargets a stacked PR when the base branch is
   *deleted*, and it wasn't). Retargeting the base to `main` via the API worked, but then the
   PR turned `CONFLICTING` — the squash-merge produced a new commit hash for #41's content, so
   #42's branch (which still carries the original pre-squash `p1` commit `73c6f5d` as its first
   commit) diverges from `main` at the git-history level even though the file content is
   identical.
   - **Fix in progress:** `git rebase --onto origin/main 73c6f5d origin/feat/p2-schema` on a
     local branch (`feat/p2-schema-rebase`) replays only the two real `p2` commits
     (`1c546af`, `d6fc7dd`) on top of the new `main`. Diff verified identical to the original
     PR #42 diff (1411 insertions / 20 deletions across the same 16 files).
   - **Blocked:** pushing that rebased history to `origin/feat/p2-schema` requires
     `--force-with-lease` (history rewrite of a PR branch), which the permission classifier
     refused. **Needs the project owner to approve the force-push before #42 can merge.**
   - Local branch `feat/p2-schema-rebase` still exists with the rebased commits, ready to push
     the moment that's approved.
3. **Lesson for next time (see below, §7):** stacked PRs + squash-merge is a bad combination.
   Either merge-commit stacked PRs (preserves the shared history so the second PR never
   diverges), or don't stack — land each ticket's PR against `main` directly and rebase small
   before opening it.
4. **Lane → handle assignment.** `handoff_log/to-tickets-backend.md` left `team/1|2|3` as
   placeholders with "remap to GitHub handles" as an open item. The repo has exactly 3
   collaborators, matching the 3 lanes 1:1 by elimination:

   | Lane label used by the user | Matches team split | GitHub login |
   |---|---|---|
   | Lane A (NuiGates) | `team/1` — transaction path | `NuimanLP` |
   | Lane B (Lomeralloy) | `team/2` — schema/catalogue/reports | `LomerAlloys` |
   | Lane C (Peternas) | `team/3` — platform/infra/ops | `PattaraponKitcharoen` |

   All 31 issues assigned via `gh issue edit <n> --add-assignee <login>` (see the full number
   list in the commit). `team/1|2|3` **labels were left as-is** — only `assignee` changed. The
   9 parent issues (#2/#3/#7/#8/#9/#10) and the not-yet-cut frontend slice stay unassigned.

## Decisions made, and why

- **Squash-merge for #41**, matching the repo's only prior precedent (PR #1, a single-parent
  merge commit under a squash). Turned out to be the wrong call for a *stacked* PR — see §7.
- **Assignee, not a relabel, for the lane→handle mapping.** `team/1|2|3` labels stay so the
  existing team-table/doc cross-references (`docs/Backend_design/adr/README.md`,
  `handoff_log/to-tickets-backend.md`) don't need renumbering; `assignee` is the layer that
  changes per person.
- **Adopted the concurrent doc reorg as intentional** (user confirmed): `handoff/` →
  `handoff_log/` (git-detected as renames, 5 files), `docs/plans/riverpod-to-bloc.md` +
  `.draft.html` removed (migration long complete, content superseded by
  `handoff_log/riverpod-to-bloc.md`). Fixed every dead reference this broke: `README.md`,
  `HANDOFF.md` (multiple), `CONTRACT.md`, `CLAUDE.md`, `docs/Backend_design/05_HOW_WE_GOT_HERE.md`,
  `docs/Backend_design/adr/README.md`, `.claude/agents/riverpod-to-bloc.md` (also marked that
  agent definition as historical/complete since its source-of-truth plan file no longer exists).

## Tried and reverted / did not do

- **First force-push attempt was blocked by the permission classifier** — did not retry or work
  around it; surfaced the ask to the user instead (per the destructive-action rule for
  history-rewriting pushes to a shared branch). Still pending approval as of this handoff.
- Did **not** rename the `team/1|2|3` GitHub labels to the people's names — see decision above.
- Did **not** touch the frontend backlog (still doesn't exist — confirmed to the user this
  session; still task `q1` + Drift schema v3, no issues cut).

## Not sure / unverified

- Whether the `handoff/` → `handoff_log/` reorg and the `handoff-prompt-template.md` drop-in
  came from a specific tool the user runs, or something else — the user confirmed intent but
  didn't name the mechanism. One file (`handoff/p1-compose-stack.md`) **reappeared once** after
  its deletion was staged (byte-identical content) while this session was mid-edit, suggesting
  something was still actively touching the directory at the time, not just a one-shot script.
  Worth watching for on the next session if `handoff/` reappears again.
- Whether `PattaraponKitcharoen` = "Peternas" is confirmed by anything other than being the only
  remaining collaborator once the other two names matched cleanly (`NuiGates`↔`NuimanLP` git
  author name, `Lomeralloy`↔`LomerAlloys` spelling). Nobody contradicted the mapping when
  presented, but it was inferred, not stated by the user as a literal handle.

## Next

1. **Get the force-push approved**, then: `git push origin feat/p2-schema-rebase:feat/p2-schema --force-with-lease`, confirm PR #42 turns `MERGEABLE`/`CLEAN`, squash-merge it.
2. After #42 merges, `git pull --ff-only` locally before doing anything else — this session lost
   ~30 minutes to local `main` being one commit behind `origin/main` after the #41 merge (the
   `gh pr merge` API call updates the remote ref, not the local branch; `git fetch` alone doesn't
   fast-forward local `main` either — needs an explicit `git pull --ff-only origin main`).
3. Next ticket per the critical path: **#4** (`p3` auth/tenancy guard, assigned
   `PattaraponKitcharoen`/Lane C) — the only thing blocking #5 → #6 → #28/#30.
4. #11/#12/#13 still need the project owner's decision (unchanged from prior handoffs).
5. Frontend backlog still needs cutting before any lane finishes their backend bundle
   (unchanged — flagged again this session, not acted on).

## Suggested skills for the next session

- Nothing code-specific — next real ticket (#4) is server auth work; `karpathy-guidelines` +
  `scrutinize` before commit, per the pattern in `handoff_log/p1-compose-stack.md` /
  `p2-schema.md`.
