# Session 2026-09-23 — README rewritten for an outside reader

**Branch:** `docs/2026-09-23-readme-rewrite` · **Base:** `main` at `616c187`
**Scope:** `README.md` only. No code, no config, no VM access.

## Why

The top-level README had gone stale in the way that matters most: it told a reader
*"No auth or business endpoints yet — **#4** is next on the critical path."* That sentence
describes the repo as it was before the entire phase-1 backend landed. Anyone arriving from
GitHub — a reviewer, a recruiter, a new team member — would have formed a wrong picture of the
project in the first thirty seconds.

The rewrite targets the structure a README is expected to carry: overview and features,
installation, environment, specific deployment steps, and — the part that carries the weight —
a section naming the system's own bottlenecks and how it would scale.

## What the README now claims, and how each claim was checked

Every load-bearing number was read out of the source, not carried over from a doc. Two
research agents gathered the facts, and the claims were then re-verified independently before
and after review. Verified this session:

- 25 Drift tables (`frontend/lib/data/db/tables.dart`), 14 TypeORM migrations, 13 routes plus
  `/login`, 12 nav destinations with Thai labels matching `app_shell.dart` character for
  character.
- 64 Flutter test files · 49 server unit specs (`pnpm test` includes `**/*.spec.ts`) · 53 e2e
  specs (`pnpm test:e2e`).
- Nginx `rate=30r/s burst=60`, `max_connections=100` against a budget of 62, the 25 s commit
  ceiling with `statement_timeout 25s` / `idle_in_transaction 5s`.
- Flutter 3.44.3, Dart `^3.12.2`, `sqlite3=3.4.0`, `drift=2.34.1`.

## Findings from `/scrutinize` and `/code-review`, and what was done

Both reviews ran against the finished draft. Seven findings were accepted and fixed; one was
rejected on evidence.

| Finding | Verdict |
|---|---|
| **"Backups run nightly at 03:00"** stated a running operation | **Fixed — this was the serious one.** `ticket-346-backup-script-install.md` records `crontab -l` → `no crontab for deploy` and `/opt/pos/backups` missing. The cron exists in `provision.yml` but has never been applied. README now says no backup runs on the VM, and bottleneck #8 was rewritten from "no *offsite* backup" to "no backup at all". |
| Deployment section read as a live pipeline | **Fixed.** A status callout now states the runner is not installed, the VM cannot pull from `ghcr.io`, and no release has ever been delivered through the path. |
| "9 architecture specs" | **Fixed.** Fabricated category: those 9 files are tooling/infra specs in `server/test/`. The real architecture specs are 3 (`tenant-door`, `tenant-wrapper`, `idempotency-routes`), and they already sit inside the unit count. Row removed, the 3 described in prose. |
| "16 of 17 DoD" conflated with the deploy blocker | **Fixed.** The k6 box is the single open DoD item; the unproven delivery path is separate and larger, and is now stated as such. |
| Set-but-empty `CORS_ORIGINS` "throws at boot" | **Fixed.** `config.ts:66-77` returns `undefined` for an empty value — empty is the documented way to disable. The throw fires only for a value with content that yields no entry (`,`). |
| Lock order omitted `doc_counters` and the `shifts` `FOR SHARE` read | Fixed. |
| Bottleneck #9 understated the firewall | Fixed — it blocks both delivery paths, and trusting the Fortinet CA does not help. |
| `DB_POOL_SIZE` default | Fixed — 15 is the compose value; the code default with the variable absent is 5. |
| k6 table implied 1,000-VU capacity | Fixed. The sanctioned three-machine method caps near **72 r/s** aggregate (3 × `SAFE_RATE_PER_SHARD` 24 r/s, `server/test/k6/lib/shard.js:26`). The table now reads as tail latency under load, not a capacity claim. |
| **"The screenshots are of the old React app"** | **Rejected on evidence.** The review's `git log` omitted `--follow`, so it saw only the 2026-09-07 folder move. With `--follow`, `docs/tutorial/flutter/img/checkout.png` traces to `bca4dc1` (2026-06-26) *"add Flutter-version user manual with real app screenshots"*, and the files differ byte-for-byte from `docs/tutorial/JS/img/`. CLAUDE.md's "re-capture screenshots" note refers to the **JS** tutorial. Screenshots kept. |

## Known weakness, not fixed

The README hard-codes counts (tests, tables, migrations) — the same class of fact that made the
old README wrong. The reviewer's suggestion was to assert them in CI so a stale README fails the
build. That is a workflow change beyond this ticket's scope and is **not** done. If those numbers
are cited later, re-derive them rather than trusting this file.

## Corrections this session makes to CLAUDE.md's own figures

Verified against source, not reconciled into `CLAUDE.md` here:

- CLAUDE.md line 106 says **21 Drift tables**; the current count is **25**.
- CLAUDE.md line 115 says **13 repos** in the provider tree; the tree now registers more.
- `CONTRACT.md` §5's screen table and `app_shell.dart`'s "11-destination nav" comment both
  predate `owner_review`, `devices` and `login`.

These are recorded rather than silently corrected, because changing `CLAUDE.md` was not in scope
for a README ticket.
