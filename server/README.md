# Srisurart POS — server (phase 1)

> **2026-09-08 — CouchDB was proposed and rejected the same day**
> (`../docs/Backend_design/adr/0012-couchdb-replaces-postgres.md`). PostgreSQL stays; the
> #15 migrations and `test/schema.e2e-spec.ts` are current; #4 `p3` is next.

NestJS multi-tenant backend. Design lives in `../docs/Backend_design/` (ADRs win over
prose); work items live in GitHub issues (#2 is the brief). Landed so far: **#14 `p1`**
(compose stack, Nginx, health probes) and **#15 `p2`** (the 27-table schema as migrations,
RLS, grants, category seed). No auth or business endpoints yet — #4 is next.

## Run

```
cd server
cp .env.example .env     # required: compose enforces that secrets are present
docker compose up -d --build
curl -k https://localhost/health/live     # → {"status":"success","data":{"status":"up"}}
curl -k https://localhost/health/ready    # checks Postgres + both Redis
```

That is the whole stack: Nginx (TLS, self-signed) → `api-1..3` → PostgreSQL, `redis-cache`,
`redis-queue`, plus the BullMQ `worker` and `bull-board` (http://127.0.0.1:3100, basic auth).
The one-shot `migrate` job applies the schema as the owner role before any `api-*` starts.
Secrets are required via `server/.env` (see `.env.example`); `docker-compose.yml` fails fast
if `POSTGRES_PASSWORD`, `POS_APP_PASSWORD`, `REDIS_PASSWORD` or `BULL_BOARD_PASSWORD` is unset.

**Only Nginx (80/443) and Bull-Board (loopback 3100) are reachable from the host.** Postgres
and both Redis publish no port at all in `docker-compose.yml` — they are reachable only over
the compose network, and both Redis require `AUTH` (`--requirepass`, password carried in
`REDIS_*_URL`). Tools that run outside Docker need the dev overlay, which publishes
5432 / 6379 / 6380 on `127.0.0.1`:

```
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --wait postgres redis-cache redis-queue
```

🔴 The overlay is for a laptop or a CI runner. **Never use it on the faculty VM or any shared
host** — a second user or an SSRF bug on that host would then reach the datastores directly.

Local development without Docker for the app itself:

```
corepack pnpm install
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --wait postgres redis-cache redis-queue
corepack pnpm build
DATABASE_URL=postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos corepack pnpm db:migrate
DATABASE_URL=postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos \
REDIS_CACHE_URL=redis://:dev-only-redis@127.0.0.1:6379 \
REDIS_QUEUE_URL=redis://:dev-only-redis@127.0.0.1:6380 \
corepack pnpm start:dev
```

## Checks

```
corepack pnpm typecheck && corepack pnpm lint && corepack pnpm test   # pure unit tests
corepack pnpm test:e2e      # against the compose Postgres/Redis — no mocks; the schema
                            # suite re-runs the real migrations on a scratch database
```

`.github/workflows/server.yml` (#38) runs the same three as separate jobs — lint, unit,
integration — on every push/PR touching `server/**`, starting the compose Postgres + both
Redis (with the dev overlay, so the runner can reach them) and applying the migrations first.

## Schema and migrations (#15)

- Schema exists **only** through `src/db/migrations/*` — `synchronize` is never true, in any
  environment including tests. `node dist/db/migrate.js up|down|status` (`pnpm db:migrate*`)
  runs them; the compose `migrate` service runs `up` once, as `postgres`, before `api-*` start.
- 27 tables (01_DATABASE §5). `change_log` is phase 2 and does not exist. Every tenant-scoped
  table has `tenant_id` in its primary key, composite FKs, and indexes that start with `tenant_id`.
- **RLS is enabled and forced** on all 25 tenant-scoped tables with one fail-closed policy:
  `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid`. With the GUC unset
  `pos_app` reads zero rows (no error) and cannot insert. `SET LOCAL app.tenant_id` inside the
  request transaction is the only way in (TenantGuard, #4). `pos_app` cannot `SET row_security = off`.
- Grants: `pos_app` has `SELECT/INSERT/UPDATE/DELETE` on every table except `movements`
  (`SELECT/INSERT` — it is a ledger) and nothing on `migrations`.
- Product search is `pg_trgm` + `ILIKE '%…%'` over `lower(part_no||' '||name||' '||name_th||' '||compat)`
  (`idx_products_search`). `to_tsvector` cannot find "เบรก" inside "ผ้าเบรกหน้า".
- `src/db/seed.ts` — `seedCategories(db, tenantId)` inserts the five categories (ADR-0001) and
  nothing else; provisioning (#5) calls it inside its transaction.

**Adding a migration:** create `src/db/migrations/<epoch-ms>-Name.ts` implementing `up` and
`down`, append the class to `MIGRATIONS` in `src/db/data-source.ts`, and if it adds a table put
the name in `TENANT_SCOPED_TABLES` (RLS + grants are asserted per table by `test/schema.e2e-spec.ts`,
so a missing entry fails the suite). Run `pnpm build && pnpm db:migrate`, then rebuild the image.

## Layout

```
src/main.ts              api entrypoint (HTTP)          → node dist/main.js
src/worker.ts            BullMQ worker (no HTTP)        → node dist/worker.js
src/bull-board.ts        Bull-Board behind basic auth   → node dist/bull-board.js
src/app.module.ts        CoreModule (config, logger, Postgres, Redis) / AppModule / WorkerModule
src/app.setup.ts         global prefix /api/v1 (health excluded), envelope, filter, JSON 404
src/common/              response envelope, error envelope, pino logger + correlation id
src/infra/               DataSource (pos_app role, synchronize=false), REDIS_CACHE / REDIS_QUEUE
src/db/migrations/       the schema (27 tables, indexes, pg_trgm) + RLS/grants — the only source of DDL
src/db/data-source.ts    owner-role DataSource with the static MIGRATIONS list
src/db/migrate.ts        up | down | status                → node dist/db/migrate.js (compose `migrate` job)
src/db/seed.ts           SEED_CATEGORIES + seedCategories(db, tenantId) for provisioning (#5)
src/health/              /health/live (touches nothing) · /health/ready (Postgres + both Redis)
docker/nginx/nginx.conf  least_conn, TLS, per-IP limit_req, timeouts, /platform/ allowlist
docker/postgres/init/    creates the non-superuser pos_app role on first boot
```

## Invariants this stack enforces (from #14 / #2)

- `redis-cache` = `allkeys-lru`, no persistence. `redis-queue` = `noeviction` + AOF. Two processes.
- Both Redis run with `--requirepass`; an unauthenticated client cannot read a cache entry or
  `FLUSHALL` the queue even from inside the compose network.
- Postgres and both Redis publish **no** host port; only `docker-compose.dev.yml` (dev/CI) does.
- Bull-Board requires basic auth and is bound to host loopback only (Nginx does not proxy it —
  on the VM reach it over an SSH tunnel); `/platform/*` is refused by Nginx from any non-private
  source address.
- `/health/live` does no I/O. `/health/ready` returns `503 NOT_READY` naming the failed
  dependency. Nginx fails over only on connection errors, never on the app's own 5xx.
- `SIGTERM` drains: Nest closes the listener, in-flight requests finish, then pools close.
  Nginx retries idempotent requests on the next instance (`proxy_next_upstream error timeout`).
- Every request carries `X-Correlation-ID` (client's, else Nginx `$request_id`) into the JSON
  log line and back out in the response. Request bodies are never logged.
- `mem_limit` per container totals ≈ 3.0 GB; `max_connections=100`, pools 3×15 + 5 = 50.
- The app connects as `pos_app` (`NOSUPERUSER NOBYPASSRLS`, not the table owner) so RLS
  cannot be bypassed by accident. Migrations run as `postgres`, once, before the app starts.

## The image CI builds (#40)

A green push to `main` uploads the server image as a GitHub Actions artefact — there is no
registry and no deploy step until a production host is picked (`03_ARCHITECTURE.md §8`):

```
gh run download <run-id> -n pos-server-image-<sha>
docker load < pos-server-<sha>.tar.gz
docker tag srisurart-pos/server:<sha> srisurart-pos/server:local   # the tag compose expects
```

The same image runs api, worker and bull-board; compose overrides `command`.

## Deploying a new image without a full outage

`docker compose up -d --build` recreates all three instances at once. For a rolling restart:

```
docker compose build api-1
for s in api-1 api-2 api-3; do docker compose up -d --no-deps $s; sleep 5; done
```

Each instance keeps its static address (`172.30.0.11–13`), so Nginx needs no reload.
