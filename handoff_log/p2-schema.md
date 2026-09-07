# Handoff: #15 `p2` — schema migrations, RLS, seed · #38 `ci.1` — backend CI

**Date:** 2026-09-06 (second server session)
**Project path:** `D:\Beestation\Sri_POS\Flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch **`feat/p2-schema`** (stacked on
`feat/p1-compose-stack`, PR #41 — still open at the time of writing)
**Previous handoff:** [`p1-compose-stack.md`](p1-compose-stack.md)

## What this session was

Picked up from the p1 handoff: pushed `feat/p1-compose-stack` and opened **PR #41** for #14, then
built **#15 `p2`** (next on the critical path #14 → #15 → #4 → #6) and **#38 `ci.1`** (its ticket
says to start as soon as the schema exists). `karpathy-guidelines` was loaded first; #2, #3, #15,
#38, `01_DATABASE.md` and ADR-0001 were read in full before any code.

## What exists now

```
server/src/db/migrations/1788652800000-InitialSchema.ts    27 tables, indexes, pg_trgm — 01_DATABASE §5 transcribed
server/src/db/migrations/1788652800001-RowLevelSecurity.ts RLS ENABLE+FORCE loop, fail-closed policy, grants to pos_app
server/src/db/data-source.ts                                owner-role DataSource, static MIGRATIONS list (no glob)
server/src/db/migrate.ts                                    node dist/db/migrate.js up|down|status — exit 1 on failure
server/src/db/seed.ts                                       SEED_CATEGORIES + seedCategories(db, tenantId)
server/test/schema.e2e-spec.ts                              12 tests = the #15 acceptance list, on a scratch database
server/docker-compose.yml                                   + `migrate` one-shot job; api-*/worker depend on it completing
.github/workflows/server.yml                                lint / unit / integration jobs, paths: server/**
```

Table lists live in **one place** — `TENANT_SCOPED_TABLES` / `GLOBAL_TABLES` in the RLS migration —
and both the RLS loop, the grant loop and the test suite iterate them.

## Verified (not speculative)

| Criterion (#15) | How | Result |
|---|---|---|
| Migrations run from an empty volume to current | compose `migrate` job on the live stack; `pos` went 0 → 27 tables | ✅ `applied: InitialSchema…, RowLevelSecurity…`; second run `up to date` |
| Every migration has a written, tested `down()` | test undoes both, asserts 0 tables + no `pg_trgm`, re-applies | ✅ |
| Raw query as `pos_app` with `app.tenant_id` unset returns **zero rows, not an error** | `SELECT count(*) FROM products` → 0; INSERT → `42501` | ✅ |
| `pos_app` cannot bypass RLS, proven by a test | `SET row_security = off` then SELECT → `42501`; also `rolsuper=f`, `rolbypassrls=f`, owns 0 tables | ✅ |
| Thai substring against the trigram index | `ILIKE '%เบรก%'` finds `ผ้าเบรกหน้า`; EXPLAIN with seqscan off uses `idx_products_search` | ✅ |
| `change_log` does not exist | table list assertion | ✅ |
| 27 tables, `tenant_id` in every tenant-scoped PK | `pg_constraint` walk over the 25 scoped tables | ✅ |
| `SET LOCAL` scope | value visible inside the transaction, gone after COMMIT on the same connection | ✅ |
| movements guard | two `adjustment-in` rows with `ref_id NULL` coexist; replayed `(sale, s1, p1)` → `23505 uq_movements_ref`; `DELETE` → `42501` | ✅ |
| Grants | `has_table_privilege` per table: full DML everywhere, `movements` SELECT/INSERT only, nothing on `migrations` | ✅ |
| Seed | five rows, `position` 0..4 in `database.dart` order, no products added | ✅ |
| Gate | `pnpm typecheck && pnpm lint && pnpm test (3) && pnpm test:e2e (16)` | ✅ |
| Runner exit codes | bad password → exit 1; `status` → exit 0 when up to date | ✅ |

#38's acceptance list: three separate jobs, path filter, migrations applied by `pnpm db:migrate`
before `test:e2e`, a failing migration exits non-zero and stops the job — and **`Server CI` was
green on GitHub on the first run** (PR #42, run 34038859839: lint + typecheck ✅, unit ✅,
integration ✅). Only annotation: `actions/checkout@v4` / `setup-node@v4` still target Node 20 —
bump to v5 when convenient, not urgent.

## Judgment calls beyond the ticket text

| Call | Why |
|---|---|
| `audit_log` PK is `(tenant_id, id)`, not `id` alone | #2 rule 2 and #15's acceptance ("every business table carries `tenant_id` in its PK") outrank the doc's DDL. `id` stays `BIGSERIAL`. |
| CHECKs added: `tenants.plan IN (basic,demo,loadtest)`, `devices.device_no BETWEEN 1 AND 99`, `drawer_entries.type IN (in,out)`, `movements.type` enum | Each is stated in prose (#2, ADR-0007, doc comments) but missing from the DDL block. |
| `idx_idem_created (created_at)` kept as in the doc, although it does not start with `tenant_id` | The 24-hour cleanup job is cross-tenant; a `(tenant_id, created_at)` index would not serve it. Noted, not "fixed". |
| `movements`: `pos_app` gets SELECT/INSERT only | The doc calls it append-only; one grant line enforces it. Every other table has full DML. |
| Grants are per explicit table, no `ALTER DEFAULT PRIVILEGES` | Forgetting a grant on a future table fails `schema.e2e-spec.ts` loudly instead of silently working via defaults. |
| `GRANT CONNECT ON DATABASE current_database()` inside the migration | Lets the migration stand alone on any database name (the scratch test DB, CI). |
| Seed is a function for provisioning, not a script run at migrate time | Categories are per tenant (ADR-0001 step 4); there is no tenant at migrate time. |
| Own runner (`migrate.ts`) instead of the TypeORM CLI | ESM + `.js` import specifiers + no ts-node in the image; 30 lines, one dependency fewer. |
| CI integration job uses `docker compose up postgres redis-cache redis-queue`, not GitHub service containers | Service containers cannot set a container `command`, so `allkeys-lru` / `noeviction`+AOF could not be reproduced; the compose file is the real thing and includes the `pos_app` init script. |
| `@types/pg` added as a devDependency | The schema test talks to Postgres through `pg` directly (the app's DataSource has no entities). |

## Traps for the next tickets

- **No `BYPASSRLS` role exists yet.** #5 (platform plane) must create it (in the init script,
  alongside `pos_app`) and give `/platform/*` its own DataSource (ADR-0002). Until then only
  `postgres` can read across tenants.
- **Provisioning inserts hit `WITH CHECK`.** `seedCategories()` and every other insert in #5's
  transaction need `app.tenant_id` set (or the BYPASSRLS role), or they are rejected with 42501.
- **Adding a table = three edits:** the migration, `MIGRATIONS` in `data-source.ts`, and
  `TENANT_SCOPED_TABLES`. The suite catches a missing third edit.
- **`pg` returns `name[]` as a string** (`'{id}'`) — cast `attname::text` before `array_agg`.
  Cost me one red run.
- With only a few rows the planner will never choose the trigram index while an RLS predicate on
  `tenant_id` exists; the EXPLAIN assertion therefore runs as the owner with `enable_seqscan = off`.
- The e2e suite drops and recreates `pos_schema_test` on the compose Postgres. Never point
  `DATABASE_ADMIN_URL` at a database you care about.

## Environment notes

- Docker Desktop was already running from the p1 session; the stack was rebuilt in place with
  `docker compose up -d --build --wait` and left running with the schema applied.
- Node 24 locally, image is `node:22-alpine`. pnpm 10.34 via corepack. No `psql` on the host —
  use `docker exec srisurart-pos-postgres-1 psql -U postgres -d pos`.
- The Bash tool still cannot parse long heredocs on this machine; files were written with Write.

## State

Committed on `feat/p2-schema` and pushed; **PR #42** opened against `feat/p1-compose-stack`
(GitHub re-targets it to `main` once **PR #41** merges). `Server CI` green on #42. Flutter gate
untouched (`server/**` is ignored there).

## Next

1. Merge **PR #41** (#14) then the #15/#38 PR — both are the project owner's call; watch
   `Server CI` go green on the second one first.
2. **#4 `p3`** (team/3) — auth, `TenantGuard` with `SET LOCAL app.tenant_id` inside the request
   transaction, aud check, `tenants.status` check before `SET LOCAL`. The RLS side is ready and tested.
3. **#5 `p3b`** — create the BYPASSRLS role + separate DataSource; call `seedCategories` inside
   the provisioning transaction.
4. **#39 `ci.2`** — the always-runs job so server-only PRs can satisfy required checks.
5. Still open from before: #11 / #12 / #13 need a human; frontend tickets are not cut yet.

## Suggested skills for the next session

- `karpathy-guidelines` — before any code.
- `scrutinize` — on #4's guard: the order *status check → SET LOCAL* and "every DB-touching
  request runs in a transaction" are exactly what passes tests while being wrong.
- `debug-mantra` — if `Server CI` is red on GitHub: reproduce with `act` or read the compose logs
  step before changing the workflow.
