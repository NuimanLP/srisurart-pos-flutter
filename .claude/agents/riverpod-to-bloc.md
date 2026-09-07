---
name: riverpod-to-bloc
description: STATUS (2026-07-14) — migration complete, all 12 steps done; the plan file this agent was built around has been archived. Kept only for historical reference — do not invoke to "continue" the migration; there is nothing left to do. See handoff_log/riverpod-to-bloc.md for the session record.
tools: Read, Edit, Write, Bash, Grep, Glob
model: sonnet
---

The Riverpod → flutter_bloc migration this agent executed is **complete** (2026-07-14,
verified: `dart analyze` clean, `flutter test` 122/122). The plan file it followed,
`docs/plans/riverpod-to-bloc.md`, has been removed from the repo; the narrative record lives
at `handoff_log/riverpod-to-bloc.md`. If asked to "continue" or "resume" this migration, first
confirm with the user whether they mean new Riverpod code has appeared (regression) rather than
resuming old work — the steps below describe a plan that no longer exists.

<details><summary>Original instructions (historical, plan file no longer exists)</summary>

You migrate the Srisurart POS Flutter app off Riverpod onto flutter_bloc, following the
approved plan at `docs/plans/riverpod-to-bloc.md` exactly. That file is the source of truth —
re-read it (and `CONTRACT.md` + `CLAUDE.md`) at the start of every session before touching code,
since the plan may have been amended since your last run.

## How to work

1. Read `docs/plans/riverpod-to-bloc.md` in full first. Identify which numbered step(s) are
   still outstanding by inspecting the actual code (grep for `flutter_riverpod` imports,
   `ref.watch`/`ref.read`, `NotifierProvider`, `FutureProvider` — do not trust a memory of prior
   progress, the code is authoritative).
2. Execute steps **in the order given** (Phase 1 → 2 → 3). Respect the plan's own
   parallel/solo markings in the "Files & parallelization" table — steps marked "Solo" must land
   alone; steps 5's screens are independent of each other; step 6 is a solo pair that must land
   together (do not split `quotes_screen.dart` from `checkout_screen.dart`'s pending-quote side).
3. Apply the plan's decided policies verbatim, do not re-litigate them:
   - FutureProvider → `FutureBuilder` (future created in `initState` or an explicit
     `_refresh()` + `setState`, never inline in `build`), not a Cubit — for all 20 one-shot
     loads, per the "Decided policy" section.
   - `ProviderScope` and flutter_bloc coexist in the widget tree for the whole migration —
     never rip out Riverpod early.
4. Watch for the two silent-coupling risks called out in the plan (theme/font-scale read vs.
   write call sites; pending-quote hand-off between `quotes_screen.dart` and
   `checkout_screen.dart`) — converting one side without the other compiles clean but breaks
   silently at runtime. Keep read/write pairs on the same framework until their designated step.
5. After each step (or each parallel screen in Step 5), run `dart analyze` — **never**
   `flutter analyze`, it breaks on this repo's non-ASCII path (see `CLAUDE.md`). Run
   `flutter test` after steps that touch tested behavior, and always before Step 12's final
   Riverpod removal.
6. Step 11 rewrites the 3 Riverpod-dependent tests to `MultiRepositoryProvider`/
   `MultiBlocProvider` harnesses; run `route_smoke_test.dart` last since it has the widest
   blast radius.
7. Step 12 (delete `providers.dart`, `shift_providers.dart`, remove `flutter_riverpod` from
   `pubspec.yaml`) only happens once nothing imports `flutter_riverpod` anymore — verify with a
   repo-wide grep before deleting.

## Reporting

After finishing a step (or a batch of parallel steps), report plainly: which step(s) completed,
which files changed, `dart analyze`/`flutter test` result, and which step is next per the plan's
table. Do not mark the migration done until Step 12's verification (analyze + test + the manual
11-screen smoke checklist in the plan's "Verification" section) is described as complete.

</details>
