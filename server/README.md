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
src/common/              response envelope, error envelope, pino logger + correlation id,
                         request-context.ts (the per-request tenant + transaction seam)
src/infra/               DataSource (pos_app role, synchronize=false), REDIS_CACHE / REDIS_QUEUE
src/idempotency/         Idempotency-Key: claim, replay, 409 on a changed request (#18)
src/db/migrations/       the schema (27 tables, indexes, pg_trgm) + RLS/grants — the only source of DDL
src/db/data-source.ts    owner-role DataSource with the static MIGRATIONS list
src/db/migrate.ts        up | down | status                → node dist/db/migrate.js (compose `migrate` job)
src/db/seed.ts           SEED_CATEGORIES + seedCategories(db, tenantId) for provisioning (#5)
src/health/              /health/live (touches nothing) · /health/ready (Postgres + both Redis)
docker/nginx/nginx.conf  least_conn, TLS, per-IP limit_req, timeouts, /platform/ allowlist
docker/postgres/init/    creates the non-superuser pos_app role on first boot
```

## Idempotency (#18)

Every write that touches money or stock carries `Idempotency-Key`
(`02_API_SCREENS.md §1.4`). Apply `IdempotencyInterceptor` to those routes — never
globally: it must run inside the request transaction, and a global copy would wrap
routes that have no tenant and no key at all.

- **Postgres is the authority.** `idempotency_keys`'s primary key `(tenant_id, key)` is
  the whole concurrency mechanism: a second request carrying a live key blocks on the
  first transaction's row lock, then finds its `ON CONFLICT DO NOTHING` inserted nothing
  and replays the committed row. No advisory lock, no application-level mutex. The wait
  is bounded by `SET LOCAL lock_timeout = '5s'`, so a wedged original cannot pin a pool
  connection indefinitely; past that the retry gets `503 IDEMPOTENCY_KEY_IN_FLIGHT`.
- **The record is written in the same transaction as the work.** A crash anywhere before
  COMMIT leaves neither, and the retry does the work; a crash after COMMIT leaves both,
  and the retry replays. There is no window that bills twice. `complete()` fails the
  request if it updated no row, because committing work with no record is that window.
- **Key + body + endpoint must all match** to replay. `request_hash` covers the body
  (that is what `01_DATABASE.md` defines it as), and the `endpoint` column is compared
  alongside it — the same key and body against `POST /sales` and then `POST /returns`
  must not replay the sale and quietly perform no return. Any mismatch is
  `409 IDEMPOTENCY_KEY_REUSED`; a missing or over-long key is `400
  IDEMPOTENCY_KEY_INVALID`.
- **A replay equals the original as JSON, not byte for byte.** `response_body` is
  `jsonb`, which does not preserve object key order, and a handler returning nothing
  comes back as `null`. Clients may compare values; nothing may compare bytes or hash
  the response.
- **Redis (`t:{tid}:idem:{key}`) is an accelerator, never an authority.** It is read only
  once the primary key has already shown the request to be a repeat, so a first request
  never waits on it; it is written only after Postgres has committed the row, and only
  for that row's remaining life, so it can neither invent a success nor outlive a key
  Lane C has deleted. Every call is bounded at 200 ms and falls through on failure.
- Keys live 24h; deleting them is Lane C's `idem.cleanup` job, not this module's.

Three decisions the design docs do not cover, made here and recorded in
`02_API_SCREENS.md §8`: `IDEMPOTENCY_KEY_INVALID`, `IDEMPOTENCY_KEY_IN_FLIGHT`, and the
200-character key bound (`(tenant_id, key)` is a btree index; an unbounded key is a 500).

### The request-context seam

`src/common/request-context.ts` holds the request's `{ tenantId, manager }`. **ADR-0003
makes `TenantGuard` (#4) the one component allowed to check tenant status and
`SET LOCAL app.tenant_id`** — but a guard cannot be the whole story, because
`canActivate` returns before the handler runs, so it can neither hold that scope open
across the handler nor commit afterwards. The wiring #4 has to build is a split, and
ADR-0003 survives it intact because only the guard still touches the tenant:

| stage | does |
|---|---|
| middleware | `runInRequestContext({ tenantId, manager }, next)` — opens the transaction and the scope |
| `TenantGuard` | checks `tenants.status` and `SET LOCAL app.tenant_id` on that manager |
| interceptor | commits on success, rolls back on error, before the response is sent |

Nothing in `src/` populates it yet, and `currentRequestContext()` throws rather than
defaulting — a route without the guard fails closed instead of reading someone's data.
`test/idempotency.e2e-spec.ts` stands in for the whole chain so the module can be proved
today; that stand-in lives in the test, deliberately, so `src/` ships no route that could
run without a tenant.

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

## The image CI builds (#61)

A green push to `main` pushes the server image to GHCR, tagged with the commit SHA and with
`main`. There is still no deploy step until a production host is picked
(`03_ARCHITECTURE.md §8`), so a human pulls it:

```
docker pull ghcr.io/nuimanlp/srisurart-pos-server:<sha>          # or :main
docker tag ghcr.io/nuimanlp/srisurart-pos-server:<sha> srisurart-pos/server:local
```

`srisurart-pos/server:local` is the tag compose expects. The same image runs api, worker and
bull-board; compose overrides `command`.

The push is gated: Trivy scans the built image for **fixable** HIGH/CRITICAL and the job exits
non-zero before the push, so a vulnerable image never reaches the registry. The image is kept
clean by `Dockerfile` (base pinned by digest, `apk upgrade`, npm/npx deleted from the runtime
stage), never by an ignore file — there is no `.trivyignore` in this repo and adding one is
forbidden (ADR-0013).

**Visibility.** The package is pushed by `GITHUB_TOKEN` from this public repository, so it is
linked to the repo and **public from the first push** — verified 2026-09-10 by an anonymous
`docker pull` of both images minutes after the first run. No manual step. If the repository is
ever made private the package follows and the VM would need a pull token (07 §7).

**Bumping the base image.** The base is pinned by digest and Dependabot here is restricted to
security updates, so nothing bumps it on a schedule. A CVE published *after* the pin turns this
gate red on the next push to `main` — usually a push that has nothing to do with the image, so
whoever meets the red build did not cause it. The fix is to bump the digest
(`docker buildx imagetools inspect node:22-alpine`, paste the index digest into both `FROM`
lines in `Dockerfile`), never a suppression file.

## Deploying a new image without a full outage

`docker compose up -d --build` recreates all three instances at once. For a rolling restart:

```
docker compose build api-1
for s in api-1 api-2 api-3; do docker compose up -d --no-deps $s; sleep 5; done
```

Each instance keeps its static address (`172.30.0.11–13`), so Nginx needs no reload.
