# Srisurart Autopart POS

POS for a Thai auto-parts shop (ร้านศรีสุราษฎร์อะไหล่ยนต์). Flutter client, Thai-first UI,
ported from an earlier React-in-browser + `localStorage` app.

The repo is moving from a **single-shop offline app** to a **multi-tenant client + backend**
platform (NestJS + PostgreSQL + Redis + BullMQ + Nginx), with CI/CD in the same repo.

## Branches

| Branch | What it is |
|---|---|
| **`main`** | **Active line** — multi-tenant: Flutter client + NestJS backend + CI/CD |
| **`POC_sample_offline_first`** | Frozen snapshot of the offline-first, Drift-only build (the version the shop runs today) |

The offline-first design is not dropped — it comes back as **phase 2** (outbox + `offlineOk`,
one `role='pos'` writer per shop). Phase 1 does **not** cut the shop over; it ships against a
demo tenant while the shop keeps running the build preserved on the POC branch.

## Layout

```
lib/          Flutter app — core/ (router, theme, utils), data/ (Drift tables + repositories),
              domain/models, presentation/ (blocs, 11 screens, widgets)
test/         repository unit tests + route smoke tests
web/          Flutter Web assets, incl. sqlite3.wasm + drift_worker.js for the web DB
server/       NestJS backend (phase 1) — compose stack, Nginx, health probes, schema migrations + RLS; see server/README.md
docs/         Backend_design/ (the binding backend spec + adr/), Summary_backend/
handoff_log/      per-session detail records; HANDOFF.md links to them
.github/      workflows/flutter.yml — analyze, test, drift codegen check, web artifact
              workflows/server.yml  — lint, unit, integration on real Postgres/Redis with migrations
CONTRACT.md   the binding client spec: tables, repo signatures, routes, Thai-string rules
CLAUDE.md     project knowledge base — read this first
HANDOFF.md    dated log of what changed and why
```

`server/` (NestJS) lives in this repo ([ADR-0011](docs/Backend_design/adr/0011-monorepo.md)).
As of 2026-09-07 it holds issues **#14 `p1`** and **#15 `p2`** — `docker compose up` brings up
the full phase-1 topology with health probes and applies the 27-table schema (TypeORM
migrations, RLS forced on every tenant-scoped table). No auth or business endpoints yet — **#4**
is next on the critical path. Phase-1 backend/CI tickets are assigned by lane: `NuimanLP`
(Lane A — transaction path), `LomerAlloys` (Lane B — schema/catalogue/reports),
`PattaraponKitcharoen` (Lane C — platform/infra/ops); see
`handoff_log/merge-p1-p2-lane-assignments.md`.

## Commands

```bash
dart analyze                              # NOT flutter analyze (see CLAUDE.md)
flutter test                              # unit + repository + smoke tests
flutter build web --no-tree-shake-icons   # web build for the shop PC
dart run build_runner build               # ONLY after Drift schema changes — ASCII path only
```

⚠️ `build_runner` and `flutter analyze` fail on a filesystem path containing non-ASCII
characters. Generated `*.g.dart` files are committed so the repo still builds and tests
anywhere; regenerate them from an ASCII path. Details in `CLAUDE.md`.

CI runs the same gate on every push and PR, plus a job that regenerates the Drift code and
fails if it differs from what is committed — GitHub runners use ASCII paths, so that check
can only happen there.

## Where to start reading

1. `CLAUDE.md` — conventions, constraints, current status
2. `CONTRACT.md` — the client spec
3. `docs/Backend_design/00_INDEX.md` — the backend package (start at `00_BASICS.md` if backend
   is new to you); **`docs/Backend_design/adr/` is binding — where a doc contradicts an ADR,
   the ADR wins**
4. `handoff_log/grill-round2-ci.md` — the current ordered checklist and what is still undecided
5. `handoff_log/merge-p1-p2-lane-assignments.md` — latest session: merge state, lane→handle
   assignment, a pending force-push that needs sign-off
