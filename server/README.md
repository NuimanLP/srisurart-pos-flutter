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
`redis-queue`, `etcd`, plus the BullMQ `worker` and `bull-board` (http://127.0.0.1:3100, basic
auth). The one-shot `migrate` job applies the schema as the owner role before any `api-*`
starts. Secrets are required via `server/.env` (see `.env.example`); `docker-compose.yml` fails
fast if `POSTGRES_PASSWORD`, `POS_APP_PASSWORD`, `REDIS_PASSWORD`, `BULL_BOARD_PASSWORD` or
`ETCD_ROOT_PASSWORD` is unset.

**Only Nginx (80/443) and Bull-Board (loopback 3100) are reachable from the host.** Postgres,
both Redis and `etcd` publish no port at all in `docker-compose.yml` — they are reachable only
over the compose network, and both Redis and `etcd` require auth (Redis: `--requirepass`,
password carried in `REDIS_*_URL`; etcd: RBAC with a root user, password in
`ETCD_ROOT_PASSWORD` — see *Dynamic config (etcd, #64/#66)* below). Tools that run outside
Docker need the dev overlay, which publishes 5432 / 6379 / 6380 on `127.0.0.1`:

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
integration — starting the compose Postgres + both Redis (with the dev overlay, so the runner
can reach them) and applying the migrations first. Since #39 (`ci.2`), path filtering happens
*inside* the workflow, not on the trigger: a `changes` job (pull_request only, `dorny/paths-filter`
with job-level `permissions: pull-requests: read` since it calls the PR-files API) gates `lint`,
`audit` and `unit` on `server/**` having changed via `if: ${{ !cancelled() && (github.event_name
!= 'pull_request' || needs.changes.outputs.server == 'true') }}` — the `!cancelled()` half matters
because plain `needs: [changes]` would implicitly require `changes` to have *succeeded*, and on a
push it's skipped (not failed) by its own `if:`, which would otherwise skip every gated job on
every push too. **`integration` is never path-gated** — it carries the cross-tenant isolation
tests in `test/security.e2e-spec.ts`, which must run on every PR regardless of what changed (the
sixth multi-tenant rule). A push to `main` never filters at all, so every commit on main runs the
full workflow (and `concurrency.group` on main is keyed by commit SHA, so two quick merges don't
have the second evict the first's in-progress image build). The one required GitHub check is
`server-ci-status`, appended at the end of the workflow — it `needs` every job including `changes`
itself, uses `if: always()` (not `!cancelled()`, which GitHub would skip — and treat as passing —
if the whole run were cancelled) paired with an explicit loop over every `needs.<job>.result` that
passes only `success`/`skipped` and fails on anything else. `flutter.yml` has the mirror-image
`flutter-ci-status`. Branch protection on `main` should require exactly those two checks — see
`docs/Backend_design/07_CICD_DEPLOY.md` §4 for the table and the exact `gh api` command to set it
(not run by this repo's CI work — it's a repo-settings change for the project owner).

## Schema and migrations (#15)

- Schema exists **only** through `src/db/migrations/*` — `synchronize` is never true, in any
  environment including tests. `node dist/db/migrate.js up|down|status` (`pnpm db:migrate*`)
  runs them; the compose `migrate` service runs `up` once, as `postgres`, before `api-*` start.
- 28 tables (01_DATABASE §5 + `import_jobs`, #239). `change_log` is phase 2 and does not exist.
  Every tenant-scoped table has `tenant_id` in its primary key, composite FKs, and indexes that
  start with `tenant_id`.
- **RLS is enabled and forced** on all 25 tenant-scoped tables with one fail-closed policy:
  `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid`. With the GUC unset
  `pos_app` reads zero rows (no error) and cannot insert. `set_config('app.tenant_id', …, true)` inside a
  `TenantService.runTx` transaction, under the tenant `TenantGuard` named, is the only way in (#4, tx.4 #153). `pos_app` cannot `SET row_security = off`.
- Grants: `pos_app` has `SELECT/INSERT/UPDATE/DELETE` on every table except `movements`
  (`SELECT/INSERT` — it is a ledger) and nothing on `migrations` or `import_jobs` (#239 — only
  `ADMIN_DATA_SOURCE` ever touches that one; it carries `tenant_id` but no RLS policy, since a
  policy would guard a role that never queries it).
- Product search is `pg_trgm` + `ILIKE '%…%'` over `lower(part_no||' '||name||' '||name_th||' '||compat)`
  (`idx_products_search`). `to_tsvector` cannot find "เบรก" inside "ผ้าเบรกหน้า".
- `src/db/seed.ts` — `seedCategories(db, tenantId)` inserts the five categories (ADR-0001) and
  nothing else; provisioning (#5) calls it inside its transaction.

**Adding a migration:** create `src/db/migrations/<epoch-ms>-Name.ts` implementing `up` and
`down`, append the class to `MIGRATIONS` in `src/db/data-source.ts`, and if it adds a
**tenant-facing** table (one `pos_app`/tenant requests will read or write) put the name in
`TENANT_SCOPED_TABLES` (RLS + grants are asserted per table by `test/schema.e2e-spec.ts`, so a
missing entry fails the suite). 🔴 That array lives in `RowLevelSecurity1788652800001`, which
already ran by the time a later migration's table exists — **never append to it directly**; its
`up()`/`down()` would then try to `ALTER TABLE` a table that does not exist yet on a from-empty
run. `import_jobs` (#239) is the precedent for an admin-only table that needs neither RLS nor a
`TENANT_SCOPED_TABLES` entry: its own migration explains the reasoning, and
`test/schema.e2e-spec.ts` asserts its no-RLS, no-grant shape by name instead. Run
`pnpm build && pnpm db:migrate`, then rebuild the image.

## Dynamic config (etcd, #64/#66)

One key, `/pos/config/log_level`, and nothing else — no business data, no secrets. PostgreSQL
stays the source of truth for anything a shop's day depends on (ADR-0013, `07_CICD_DEPLOY.md`
§8). This is the store side (#64); `src/config/runtime-config.service.ts` (#66, merged first)
is the consumer that reads it at boot and watches it live.

- `etcd` runs on the compose network only — no `ports:`, same as Postgres/Redis. `x-app-env`
  gives every api/worker instance `ETCD_URL=http://etcd:2379` (not a secret — an internal
  compose DNS name) and `ETCD_ROOT_PASSWORD` (from `.env`, fails fast if unset, exactly like
  the other datastore passwords) so `RuntimeConfigService` can authenticate.
- **The app must boot without etcd.** `RuntimeConfigService` logs one warning and keeps the
  `LOG_LEVEL` environment value if etcd is unreachable — there is no `depends_on` from any
  `api-*`/`worker` service onto `etcd` or `etcd-init`, deliberately, so a slow or crashed store
  can never hold up the app.
- Image: `gcr.io/etcd-development/etcd:v3.6.12` — the etcd project's own official image, tag-
  pinned like every other image in this file, so a CVE is answered by bumping the tag (the
  repo's "bump, never suppress" rule) rather than by a frozen vendor rebuild with nothing to
  bump to. It still serves the v3 gRPC-gateway HTTP API `RuntimeConfigService` talks to with
  plain `fetch` (`/v3/kv/range`, `/v3/watch`; ADR-0013 rules out the `etcd3` package — CJS +
  grpc-js on an ESM build) — verified directly against this exact tag with `curl`, since the
  gateway's removal only affects some later etcd releases and guessing which ones from a
  changelog is exactly how this file got it wrong once already.
- This official image ships no shell — just the `etcd`/`etcdctl`/`etcdutl` binaries — and etcd
  has no `docker-entrypoint-initdb.d`-style hook the way `docker/postgres/init/` uses, so
  bootstrapping the root user and enabling RBAC is a separate one-shot `etcd-init` job
  (`docker/etcd/etcd-init.sh`, image `curlimages/curl`), the same shape as `certgen`
  bootstrapping the TLS cert. It drives etcd's HTTP API directly (`/v3/auth/user/add`,
  `/v3/auth/role/add`, `/v3/auth/user/grant`, `/v3/auth/enable`), then **asserts** the result —
  root authenticates, an anonymous request is refused — rather than trusting the bootstrap
  calls succeeded. It is idempotent: re-run against an already-bootstrapped volume (a restart,
  not a fresh one) short-circuits at the first authenticate call. It then seeds
  `/pos/config/log_level` with `LOG_LEVEL` (default `info`) in a txn guarded by
  `create_revision == 0`, so a value changed later is never overwritten (#67). Locally it still
  runs from `up`; the VM deploy runs it with `run --rm`, so there a failure fails the deploy.
- `etcdctl endpoint health` needs credentials once auth is enabled (it performs a linearizable
  read) — the healthcheck sets `ETCDCTL_USER=root:$ETCD_ROOT_PASSWORD` as an environment
  variable so the password never lands in a process argument, same reasoning as
  `REDISCLI_AUTH` for Redis. This is harmless before `etcd-init` has run (auth disabled: etcd
  does not check credentials it isn't enforcing yet).
- 🔴 **The root password is applied only once, when `etcd-init` first bootstraps the volume.**
  `ETCD_ROOT_PASSWORD` in `.env` is not kept in sync with what etcd actually holds — changing
  it later does **not** rotate the stored password. Tested directly: with a changed
  `ETCD_ROOT_PASSWORD` and the same `etcd-data` volume, `etcd`'s own healthcheck starts failing
  auth (`"authentication failed, invalid user ID or password"` in its health log) since the
  healthcheck now presents the new value against the old stored one, and a subsequent
  `etcd-init` run correctly fails loud (`root cannot authenticate`, exit 1) rather than
  papering over it — but nothing depends on `etcd-init` succeeding, so this is visible in
  `docker compose ps`/logs, never in the API's own health check. Meanwhile
  `RuntimeConfigService` also cannot authenticate with the new value and fails open exactly as
  it does with no etcd at all: one warning, `LOG_LEVEL` from the environment, then retries with
  backoff (1–30 s, logged at debug after the first warning — #120) that keep failing until the password matches.
  To actually rotate it: `etcdctl user passwd root` against the running store (out of scope
  here — no ticket owns it yet), or reset the `etcd-data` volume and let `etcd-init` re-bootstrap.
- Verify by hand — write and read with root credentials **on the etcd container** (its
  environment already carries `ETCDCTL_USER`), then prove the refusal from a **separate**
  container on the compose network so it starts with no credentials of its own (`docker compose
  exec etcd etcdctl …` would inherit the first container's `ETCDCTL_USER` and wrongly succeed):
  ```
  docker compose exec etcd etcdctl --endpoints=http://127.0.0.1:2379 put /pos/config/log_level debug
  docker compose exec etcd etcdctl --endpoints=http://127.0.0.1:2379 get /pos/config/log_level

  docker run --rm --network <project>_default --entrypoint etcdctl \
    gcr.io/etcd-development/etcd:v3.6.12 --endpoints=http://etcd:2379 get /pos/config/log_level
  # → refused: "rpc error: code = InvalidArgument desc = etcdserver: user name is empty"
  ```
  (`<project>_default` is `srisurart-pos_default` for this stack's own network; `docker compose
  exec -e ETCDCTL_USER= etcd etcdctl …` is an equivalent one-liner if a second container isn't
  convenient — both were verified to refuse identically.) Then watch the running API's logs
  pick up the change within a few seconds (#66).
- Seeding the key on a fresh deploy is `cd.2`'s job, not this one's — this ships an empty,
  working store; `RuntimeConfigService` simply keeps the environment `LOG_LEVEL` until a value
  is written.

## Layout

```
src/main.ts              api entrypoint (HTTP)          → node dist/main.js
src/worker.ts            BullMQ worker (no HTTP)        → node dist/worker.js
src/bull-board.ts        Bull-Board behind basic auth   → node dist/bull-board.js
src/app.module.ts        CoreModule (config, logger, Postgres, Redis) / AppModule / WorkerModule
src/app.setup.ts         global prefix /api/v1 (health excluded), envelope, filter, JSON 404
src/common/              response envelope, error envelope, pino logger + correlation id,
                         request-context.ts (the per-request tenant + transaction seam)
src/infra/               DataSource (pos_app role, synchronize=false), ADMIN_DATA_SOURCE (owner),
                         AUDIT_DATA_SOURCE (pos_app, pool of 2, off the request pool),
                         HEALTH_DATA_SOURCE (pos_app, pool of 1, /health/ready only — #248),
                         REDIS_CACHE / REDIS_QUEUE
src/idempotency/         Idempotency-Key: claim, replay, 409 on a changed request (#18)
src/documents/           document numbers: RC01-2569-08-0042, per device per month (#19)
src/sales/               POST /sales — the sale transaction (#20)
src/returns/             POST /returns — the credit note (#22)
src/shifts/              the cash drawer: shifts, entries, the shift_id stamp (#28)
src/devices/             /devices: enrol (code), list, retire — closes the drawer (#144)
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
(`02_API_SCREENS.md §1.4`). Since `tx.3` (#152) it is explicit in the handler — there is no
interceptor. The controller's whole body becomes the work callback:

```ts
@Post(':id/void')
@HttpCode(200)
voidSale(@Param('id') id: string, @Body() body: unknown, @Req() req: AuthenticatedRequest,
         @Res({ passthrough: true }) res: Response) {
  return this.idempotency.runIdempotent(idempotencyParamsOf(req, 200), res, () => {
    /* the handler body, unchanged */
  });
}
```

- `idempotencyParamsOf(req, successCode)` (`idempotency/idempotency.runner.ts`) refuses a
  missing or over-long key (`400 IDEMPOTENCY_KEY_INVALID`) and fingerprints the request: the
  **concrete** `METHOD baseUrl+path` (never `req.route.path` — two bills' `/void` would share
  one fingerprint, #75) and the body hash.
- 🔴 `IdempotencyService.runIdempotent(params, res, work)` opens `TenantService.runTx` itself and
  runs claim → `work` → complete **on that one manager**; the claim is the first statement of the
  handler body (parameter pipes would run before it — none exist today). Every service
  `runTx` inside `work` joins it, so nothing a service reads or locks comes before the claim,
  a refused write rolls the claim back with it (the `409 CREDIT_LIMIT_EXCEEDED` → same key +
  `overrideCreditLimit` counter path depends on that), and a service that calls another write
  path (`QuotesService.convert → SalesService.create`) never claims twice — only controllers call
  `runIdempotent`. Since `tx.4` (#153) its `runTx` **is** the transaction — claim, work,
  complete and commit all happen there, and the response goes out after the commit.
  `test/idempotency-money.e2e-spec.ts` pins that against the tables, over HTTP and called
  directly. A replay, `409 IDEMPOTENCY_KEY_REUSED` or `503 IDEMPOTENCY_KEY_IN_FLIGHT` opens a
  transaction just for the claim; a retry waiting on a live key holds a connection for up to
  `lock_timeout` (5 s).
- A replay sets the stored status on `res` (hence `@Res({ passthrough: true })` — a plain
  `@Res()` would leave the response unsent and hang the request) and returns the stored body;
  the global `EnvelopeInterceptor` wraps it exactly like the original. The stored
  `response_code` **is** what goes on the wire: Nest sets the route's status before the handler
  and sends with none, so `res.status(stored)` wins. That was measured, not read —
  `test/idempotency.e2e-spec.ts` › *the stored status reaches the wire on replay* patches a
  record to 201 under a `@HttpCode(202)` route and sees 201; without the `res.status` call it
  sees 202.
- 🔴 `successCode` must equal the route's `@HttpCode` (else 201 for POST, 200 otherwise).
  `src/idempotency/idempotency-routes.spec.ts` checks every call site against its decorators,
  checks the claim is the handler's first statement, requires `passthrough: true` on `@Res`, and
  pins the list of idempotent routes, so a route that loses its claim fails there (a brand-new
  write that never had one does not). What changed from the interceptor is only *where the code
  comes from*: it read `@HttpCode` metadata when the original request ran, a call site now passes
  a literal. Both store the code of the original request and replay it, so a deploy that changes
  a route's `@HttpCode` between a request and its retry replays the old code either way; the new
  risk is a literal drifting from its decorator, which the scan catches.
- 🔴 **Everything in `work` runs inside the transaction holding the claim row**, and a nested
  `runTx` only joins it — so slow work that is not the write belongs *before* `runIdempotent`.
  **`POST /sales/:id/void` is the one route that does that (tx.5, #154):**
  `idempotencyParamsOf` (a bad key is still a 400 first) → `VoidService.authorise` (a short
  `runTx` reads `pin_hash` and commits; then role, PIN rate limit and missing-PIN refusals in
  their old order; then argon2 `verifyPassword` with **no transaction and no connection held**)
  → `runIdempotent(… VoidService.void …)`. Strictly sequential, never `Promise.all`; `authorise`
  throws if called with a transaction open. `void` takes the `AuthorisedVoid` that only
  `authorise` can build, bound to that bill and tenant (checked at the top of the void).
  🔴 **The PIN lockout is `consumeAttempt`** (one atomic Redis INCR, counted before argon2), not
  check-then-increment: with argon2 out of the transaction nothing else bounds concurrent guesses —
  the review measured 60 of 60 concurrent wrong PINs reaching argon2 before the fix, 5 after
  (`test/void-pin-burst.e2e-spec.ts`). A no-PIN refusal refunds its attempt, so it is never a lockout.
  The PIN is an authorisation, not an invariant: nothing about the bill is read before the claim,
  and the lock order inside the void is unchanged. `idempotency-routes.spec.ts` allows this
  whole-body shape for `SalesController.voidSale` alone. **Consequence:** a done key no longer
  skips the PIN — a resend whose PIN no longer verifies (the manager changed it) answers 403 plus
  a `sale.void.denied` row instead of the stored 200, and the same key with a different wrong PIN
  answers 403 instead of `409 IDEMPOTENCY_KEY_REUSED`; a correct-PIN replay spends one argon2 verify.
  Measured with `test/tx-hold-measure.e2e-spec.ts` (4 voids, pool 2): longest transaction
  ~101–131 ms → ~14–22 ms, latency 102/108/199/205 ms (a staircase) → ~115/121/127/133 ms.

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
  With no `tenantId` the job lists `tenants` and fans out one tenant-scoped job each (#169): a
  DELETE on the `pos_app` pool with no `app.tenant_id` matches 0 rows under forced RLS and still
  "succeeds". `queue/job-scheduler.service.ts` (#182) registers the global job as a repeatable
  BullMQ job scheduler — `upsertJobScheduler(IDEM_CLEANUP_SCHEDULER_ID, { every: 1h }, …)` — on
  worker boot; the id makes re-registering (a restart, or a future second worker replica) an
  upsert of the same schedule, never a duplicate. Against real Redis/BullMQ 6.3.4 the first run
  fires immediately on first registration (`every` with no prior run is not epoch-aligned), then
  every hour after that. 🔴 Renaming `IDEM_CLEANUP_SCHEDULER_ID` orphans the old scheduler under
  its old id in Redis — remove it (`queue.removeJobScheduler(oldId)`) before changing the
  constant, or it keeps firing forever with nothing watching it.
  It lives in its own `QueueSchedulerModule`, imported only by `WorkerModule` — **not**
  `QueueProcessorsModule`, which several e2e suites (`test/backup.e2e-spec.ts`,
  `test/worker-jobs.e2e-spec.ts`) mount on its own to exercise one processor, and must not also
  register (and fan out) the global schedule by booting. The API imports plain `QueueModule` to
  enqueue jobs but never `QueueProcessorsModule` or `QueueSchedulerModule`, so the three API
  replicas never call it either.

Three decisions the design docs do not cover, made here and recorded in
`02_API_SCREENS.md §8`: `IDEMPOTENCY_KEY_INVALID`, `IDEMPOTENCY_KEY_IN_FLIGHT`, and the
200-character key bound (`(tenant_id, key)` is a btree index; an unbounded key is a 500).

### The request-context seam

`src/common/request-context.ts` holds the request's `{ tenantId, manager }`, and ADR-0003
makes `TenantGuard` the one component that decides which tenant a request acts as, after
checking `tenants.status`. Since `tx.4` (#153, 2026-09-14) the ADR-0003 addendum
*"ใครตัดสิน กับ ใครลงมือ"* is **Accepted and in force**: the transaction lives in the
handler, not around the request. The migration that got here is recorded in
`docs/Backend_design/adr/0003-handler-scoped-migration-plan.md` (#149 → #154, parent #142);
its last slice, `tx.5` (#154), moved the void's manager-PIN check ahead of the transaction
(see *Idempotency* above).

| stage | does |
|---|---|
| `TenantScopeMiddleware` (global, `forRoutes('*')`) | opens an empty scope — no tenant, no transaction — with `runInTenantScope()`. **Touches no database.** |
| `TenantGuard` | checks `tenants.status` (Redis `t:{tid}:status` first; on a miss a plain pool read — `tenants` has no RLS), then `setRequestTenant()`. It runs no `set_config`. |
| `TenantService.runTx(fn)` | reads the tenant from the scope, opens a transaction, `set_config('app.tenant_id', …, true)`, runs `fn` with the manager published, commits or rolls back, releases, then runs the `onTransactionCommit` hooks |
| `EnvelopeInterceptor` | the only global interceptor: wraps whatever the handler returned, which is already committed |

- 🔴 **`runTx(fn)` never takes a `tid`.** It reads the tenant the guard put in scope and
  throws if there is none. A `runTx(tid, fn)` shape lets any call site name another shop's
  uuid and get its rows back with no error, which is the one thing ADR-0003 exists to
  prevent. Since `tx.1` (#150) `src/common/database/tenant.service.ts` has only `runTx(fn)`.
- **Every public method that reads `currentRequestContext()` wraps itself in `runTx`**
  ("public wrapper + private `*In`", `tx.2` #151), and every idempotent write route claims
  through `IdempotencyService.runIdempotent`, which opens the `runTx` the handler's services
  join (`tx.3` #152). A method that skips the wrapper 500s — there is no request transaction
  to fall back on — and `src/common/tenant-wrapper.spec.ts` fails on it before it ships.
- **A new controller needs no config entry.** There is no `TENANT_ROUTES` list any more: the
  scope is global and the transaction is the handler's. `test/tenant-scope.e2e-spec.ts` mounts
  a guarded controller from a test module and proves it answers under its tenant.
- **`runTx` joins, it does not nest.** A `runTx` inside an outer `runTx` reuses its manager,
  which stops `closeForRetirement → close()` or `VoidService → SaleReadsService.byId()` from
  asking for a second connection (`test/runtx-join.e2e-spec.ts`). A joined `runTx` never rolls
  back on its own: catching its error does not undo its writes (a Postgres error leaves the
  owner aborted, 25P02). 🔴 Siblings do **not** join each other:
  `Promise.all([runTx(a), runTx(b)])` takes two connections at once — the #162 deadlock shape
  under a burst. No call site does this today (`Promise.all` in `src/` is only the health probe
  and Redis/BullMQ shutdown); fold any future one into a single `runTx`.
- **A suspended tenant is never named.** The guard refuses before `setRequestTenant()`, so
  `runTx` has no tenant to `set_config` and cannot open a transaction for that shop. There is
  still no separate `TenantInterceptor`.
- **`onTransactionCommit` needs an open transaction.** Outside any scope, or in a request scope
  outside `runTx`, it throws — there is no commit to wait for, and running the hook at once (the
  old outside-a-request behaviour) or parking it on a scope nothing ends would be silently wrong.
  `TenantCache.invalidateAfterCommit` checks the same thing with its own message.
- **A guard-refused request opens no transaction.** A 401 (no or bad token) takes no
  connection at all. A 403 on a cold cache takes at most two short pool reads (the rate
  limiter's `SELECT plan`, the guard's `SELECT status`), each returned at once, and never a
  `runTx` or a `set_config` (`test/tenant-scope.e2e-spec.ts` counts them exactly).
  `/health/live` takes no connection and `/health/ready` one (`SELECT 1`) — from
  `HEALTH_DATA_SOURCE`, never the request pool (#248).
- **The footgun that is easier to reach for is an injected `DataSource`.** Forgetting `runTx`
  and calling `currentRequestContext()` throws (a loud 500). Querying through a bare
  `DataSource` answers **200 with zero rows**, and an `UPDATE` reports success having changed
  nothing. `src/common/tenant-door.spec.ts` is a source scan that fails when a file outside an
  allowlist reaches for a pool, with a reason on each allowlist line (the guard is on it for
  its status read), and it polices who may call `setRequestTenant` (the guard),
  `runInTransaction` (`runTx`) and `runInRequestContext` (no production code — a unit-test seam).
- Known leftovers, noted rather than changed in `tx.4`: the owner-role checks in
  `BackupController.exportTenantData` / `getJobStatus` and `QuotesController.purgeQuotes` run
  inside `runTx` although those handlers touch no table (BullMQ only), so a 403 there opens and
  rolls back a transaction; and `purgeQuotes` enqueues its job inside the transaction, so a
  rollback after the enqueue (a failed idempotency `complete`) still leaves the job queued —
  harmless because the job id is deterministic and the purge is idempotent, whereas moving it to
  `onTransactionCommit` would make a lost enqueue after a committed 202 silent. And the cached
  reads (`ProductsService.list`, `CategoriesService.listCached`, `SettingsService.getSettingsCached`)
  open their `runTx` before checking Redis, so a hit still costs a transaction and a
  `singleFlight` waiter idles in one — #173.

**How the tenant is named: `SELECT set_config('app.tenant_id', $1, true)`, never
`SET LOCAL app.tenant_id = $1`.** `SET` is a utility statement — Postgres does not plan
it, so it takes no bind parameter and that second spelling is a flat `42601` syntax
error that also aborts the enclosing transaction. It is invisible to unit tests, because
a mocked `query` accepts any string, and it reached `main` three separate times: the
login audit write, `refreshTokenPayload` (where it 500'd every `POST /auth/refresh`
until it was covered by `test/auth-refresh.e2e-spec.ts`) and `TenantService.runTx`. The
`SET LOCAL` wording elsewhere in this file and in ADR-0003 means *transaction-scoped*,
which `set_config(..., true)` is; `src/common/tenant-scope.spec.ts` scans `src/` so the
literal form cannot come back.

`currentRequestContext()` throws rather than defaulting, so a route without the guard
fails closed instead of reading someone's data. It fails closed three times: outside the
scope, before the guard has named a tenant, and outside `runTx`. `/auth/*` carries no
`TenantGuard` except `GET /auth/me`, because ADR-0009 requires a failed login's audit row to
survive a rollback (and `/auth/token` must not hold a transaction across its argon2 verify):
`AuthService` sets `app.tenant_id` on its own runners.

🔴 **Two rules for anything that runs inside a request:**

1. **Never take a second connection from the request pool while holding one.** Under load
   every in-flight request holding one and waiting for another is a pool deadlock — they all
   sit there until `connectionTimeoutMillis` fires and all return 500, and the 500s are
   *other people's requests*, not the one that misbehaved. Inside `runTx`, read through its
   manager (`currentRequestContext().manager`). Before a handler's `runTx` — in a guard — a
   plain pool read is the request's first connection and is returned before `runTx` asks for
   one, which is why `TenantGuard` (status) and `RateLimitService.readPlan` (plan) read on the
   pool. Never call either from inside a `runTx`.

   Work that genuinely cannot run in the handler's transaction — today that is exactly one
   call site, `VoidService`'s refusal audit, which must survive the rollback the 403
   causes — takes its connection from **`AUDIT_DATA_SOURCE`** (`src/infra/db.module.ts`):
   a separate pool of 2, same `pos_app` role, so RLS still applies and the write still has
   to name its tenant with `set_config('app.tenant_id', …)` of its own. Never
   `ADMIN_DATA_SOURCE` — that connects as the owner, and an audit row written as the owner
   is tenant data that RLS never checked.

   🔴 This *was* written as a deliberate exception taking a second request-pool
   connection, and it was measured as an availability bug. Same app, same tenant,
   `DB_POOL_SIZE=2`, four concurrent denials plus four unrelated reads:

   | | before | after |
   |---|---|---|
   | four concurrent denials | `403,403,500,500` in 5013 ms | `403,403,403,403` in 44 ms |
   | four unrelated reads | `500,500,500,500` | `200,200,200,200` |

   Production runs `DB_POOL_SIZE ?? 5` and the first denial branch is the **role** check,
   so any authenticated cashier could stall every sale in flight for five seconds without
   knowing a PIN. `test/void-denial-pool.e2e-spec.ts` holds the measurement. The next
   denial path to be written follows that shape: its own pool, its own `set_config`, and
   a `catch` that keeps a failed audit from turning a 403 into a 500.

   🔴 **Guards count as "inside a request" (#162).** Before `tx.4` the global
   `TenantRateLimitGuard` ran after the request-wide middleware had taken the request's
   connection, and `RateLimitService` looked up `tenants.plan` on a cold `t:{tid}:plan` cache
   with `DataSource.query` — a second pool connection. Since #75 that read as a "local machine
   limit" of the request-wide transaction: `sales.e2e-spec.ts` › *200 concurrent bills* and
   `shifts.e2e-spec.ts` › *ten simultaneous opens* failed on dev machines and passed in CI. It
   was this deadlock. Its signature is that **successes equal `DB_POOL_SIZE` exactly** (8→8,
   20→20, 50→50 was measured and misread as starvation) after a full
   `connectionTimeoutMillis`. Production's plan cache goes cold every five minutes, so any
   burst of `DB_POOL_SIZE` requests at that moment stalled an instance for ten seconds.

   | clean `main`, cache reset | before | after |
   |---|---|---|
   | ten simultaneous opens, pool 8 | 8 plan lookups fail at 10 000 ms, two `500` | all `200` |
   | 200 concurrent bills, pool 8 | 8 bills in 10.5 s | 50 bills, test body ~1.8 s |
   | 6 opens + 6 reads, pool 2 | `200,200,500×10` in 5065 ms | all `200` |

   #162 fixed it by reading on the request transaction inside a savepoint. `tx.4` removed that
   transaction, so the plan is a plain pool read again — safe now for the reason in rule 1.
   `test/rate-limit-pool.e2e-spec.ts` forces the burst at pool 2 with a cold cache and is the
   gate for both shapes.
2. **An async Express middleware must never reject.** Express does not await it, so a
   rejection is an unhandled rejection, which Node answers by killing the worker.
   `TenantScopeMiddleware` does no I/O at all; keep it that way.

### The transaction ceiling (#213)

🔴 **ADR-0010's phase-2 pull rewinds its `?updatedSince=` cursor by 30 s (#191), and that is
safe only while no write commits more than 30 s after it stamped `updated_at = now()`** (the
transaction's *start*). A later commit lands behind a cursor that has already moved past it, and
the row is never pulled. Change one of these numbers only together with the other.

Postgres here is 16, which has no `transaction_timeout` (added in 17), so the ceiling has two parts:

| part | where | value | what it does |
|---|---|---|---|
| **commit guard** | `TenantService.runTx`, `TenantJobRunner.runWithTenantContext` (`common/database/commit-ceiling.ts`) | **25 s** | takes a monotonic mark just before `BEGIN`; right before `COMMIT`, if the mark is more than 25 s old, rolls back and throws `CommitCeilingExceededError` (a 500) |
| `idle_in_transaction_session_timeout` | role `pos_app` in the app database (migration `1788652802131`) | **5 s** | a transaction the app leaves idle between statements: Postgres ends the session, the transaction rolls back, and pg-pool drops the client |
| `statement_timeout` | same | **25 s** | a runaway statement: `57014`, the transaction can only roll back. It is a safety net that fires before nginx's `proxy_read_timeout 30s`, not the thing that bounds the rewind |

**The guarantee.** `BEGIN` is sent after the mark, so Postgres `now()` is no earlier than the
mark. Every transaction that commits through `runTx` or `TenantJobRunner` therefore commits within
**25 s + one round trip** of its `now()`, whatever number of statements it ran. That stays under
30 s. The guard adds no round trip. It relies on the database host's clock not being stepped
between `now()` and `COMMIT`, since `now()` is wall-clock time and the mark is monotonic.

- **A guard trip means "not committed", and the response is a 500.** The client reads a 5xx as
  "fate unknown" and resends the same key. The idempotency claim rolled back with everything else,
  so the resend is a first attempt.
- **Reads are not cut short at 5 s.** An all-time report over years of data can take longer than
  5 s, and it is only killed if a single statement runs past 25 s. A read that commits late stamps
  nothing, so the guard's 500 on a read older than 25 s costs a retry and no data.
- **Outside the guard, by design:**
  - The owner role (`postgres`): the compose `migrate` job, `ADMIN_DATA_SOURCE`, platform
    provisioning and import. Nothing caps these, so long migrations and imports keep working.
    - 🔴 **A migration that touches pulled rows must commit within 30 s of stamping them.** A
      `now()` stamp that commits later is **never** pulled, not pulled again. `clock_timestamp()`
      alone does not help: `migrationsTransactionMode: 'each'` runs each migration as one
      transaction. So either stamp last, with `clock_timestamp()`, in a short migration, or tell
      clients to reset their cursor.
    - **The tenant import stamps `clock_timestamp()` on imported products (#217).** It does
      not write the snapshot's historic `products.updated_at`. A device that pulled before
      the import (cursor T1) sees imported products because their `updated_at` is stamped
      at import time (> T1).
    - **…and re-stamps them as its last statements before COMMIT** (#185, review of #244).
      The import is one long transaction: 6.4 s for a 2.0 MiB file (4 months, 2,043 bills,
      local dev, `test/import-snapshot.e2e-spec.ts`), and nginx allows 10 MiB. A product
      stamped at the start, or a customer/mechanic defaulting to `now()` (transaction start),
      could therefore commit more than ADR-0010's 30 s rewind behind its stamp. The final
      `UPDATE products|customers|mechanics SET updated_at = clock_timestamp()` puts every
      pulled row's stamp within milliseconds of the commit. `settings` is not re-stamped: it
      is read whole (ETag), not by cursor.
  - `pos_app` writes that do not go through either door, where the role timeouts still apply:
    - `AuthService`'s login, refresh and enrolment audit writes, on the default pool with their own
      transactions. They write only `audit_log`, which no client pulls.
    - `enrolDevice`'s autocommit write to `devices`, which no client pulls.
    - `VoidService`'s refusal audit, on `AUDIT_DATA_SOURCE`.
    - Any plain autocommit `ds.query` statement. Its commit is the statement itself, so
      `statement_timeout` (25 s) bounds it.
- **The one exemption is the tenant export** (`backup.processor.ts`, which passes
  `exemptFromCommitCeiling: true`; `tenant-job-runner.spec.ts` fails if any other file passes it).
  It reads a tenant's whole history unpaged, so it also `SET LOCAL`s both role timeouts to `5min`.
  It used to be unbounded and is now capped at 5 min. The exemption is safe for the rewind only
  because the export writes nothing a client pulls: its one write is `audit_log`. Any new exemption
  needs the same argument.
- **`CLAIM_LOCK_TIMEOUT` (5 s) must stay below `statement_timeout`.** When a resend waits on the
  original's claim, it has to get `55P03`, which becomes `503 IDEMPOTENCY_KEY_IN_FLIGHT`. It must
  not get `57014`, which becomes a plain 500.
- **The role settings are fragile.** A role-in-database setting is lost by a plain `pg_dump` and
  restore unless roles and globals are dumped too. A pooled connection only picks up a new value
  when it reconnects, so after a migrate-only rerun you must **restart the app**. At boot the app
  reads both settings with `SHOW` and logs a loud warning if they differ from `APP_ROLE_TIMEOUTS`.
  It never fails readiness over this.
- `test/tx-ceiling.e2e-spec.ts` pins all of this at `DB_POOL_SIZE=2`:
  - Both `pos_app` pools show `25s` / `5s`, and the owner pool shows `0` / `0`.
  - A 6 s `pg_sleep` read completes.
  - A bill held past a lowered guard answers 500 and commits nothing, claim included; the resend
    with the same key is a 201.
  - Two bills stalled for more than 5 s are both ended. pg-pool drops exactly those two clients
    after their connection errors, and the next burst is all 2xx.
  - A resend during an uncommitted claim answers 503 `IDEMPOTENCY_KEY_IN_FLIGHT` after about 5 s.

## Document numbers (#19)

`RC01-2569-08-0042` — type, two-digit `device_no`, Buddhist year-month, four-digit running
number (ADR-0007). `DocNumberService.issue(manager, …)` allocates from `doc_counters` with
`ON CONFLICT DO UPDATE … RETURNING` inside **the caller's** transaction, so a rolled-back
sale gives its number back and the printed series has no visible hole.

- The series is per `(device_id, doc_type, period)` and resets monthly. `period` is the
  Buddhist year and month **in `tenants.timezone`** — a sale rung up at 00:30 in Bangkok
  belongs to that day's month, not to UTC's.
- `device_no` is resolved here from the token's `did`. It is never read from a request
  body: a client that could choose it could print into another machine's series (ADR-0004).
- `device_no` is zero-padded to two digits without exception — unpadded, machine 1 and
  machine 12 differ only by a separator and parse back wrong.
- The 10,000th document in one month on one device is `409 DOC_NUMBER_EXHAUSTED`, not a
  wrap to `0001` that would re-issue a number already printed on paper. The message is
  English on purpose: inventing a Thai string is the shop owner's call, and the code is
  filed in `02_API_SCREENS.md §8.1` waiting for it.
- Imported legacy documents keep their original `RC12345678ABCD` numbers. The two formats
  cannot collide, so the counter neither reads them nor reconciles against them.
- Phase 2 (the `pos` device issuing RC/CN from its own Drift counter, and
  `GET /doc-counters` to seed it) is **not** built here — in phase 1 the server issues
  every series.

🔴 **Lock order: the mechanic's row, then products, then `doc_counters`.** `POST /sales`
locks the mechanic named on the bill (any bill naming one, not just credit sales — a cash
bill locking products first and the mechanic later would deadlock against a credit bill
for the same mechanic sharing one product), then takes `FOR UPDATE` on every product on
the bill, and only then bumps the counter. Any later path that writes
stock **and** issues a number must take them in that same order. `POST /returns` (#22)
does, with the parent bill's own `FOR UPDATE` ahead of all three: **sale → mechanic →
products → `doc_counters`**. `POST /purchase-orders/:id/receive` (#26) takes the PO row `FOR UPDATE`, then every matched product in id order, and issues no number (the PO number was issued at create) — no other path locks a PO row, so it cannot close a cycle;
`POST /sales/:id/void` (#23) does, taking the mechanic's row before the first product
because it now reverses the tab. The drawer row that `POST /sales` and
`POST /mechanics/:id/credit-payments` read first (before the mechanic on a sale, after it
on a credit payment) is outside this order on purpose: the money path only ever takes it
`FOR SHARE`, shared locks never wait on each other, and the drawer's own exclusive
writers (open, close, entries, retirement) take no other money-path lock. A path that
ever takes the shift row `FOR UPDATE` *and* a mechanic or product must fix an order first. Issuing the number first inverts the order and
the two deadlock under concurrent load, which is the kind of failure that only shows up on
a busy Saturday.

## The sale transaction (#20)

`POST /api/v1/sales` — `pos` device only, `Idempotency-Key` mandatory. Everything runs
inside one transaction (the route's `runIdempotent` → `runTx`), in this order, and the order is the design:

1. the idempotency claim (interceptor, before the handler), then the client-`id` replay
   (`existingSale`), then **the device's open drawer, read `FOR SHARE`** — none open is
   `409 NO_OPEN_SHIFT` on every payment method (see *The cash drawer* below). After both
   replay paths, so a bill committed while the drawer was open still answers once it has
   closed; before every other lock, so a refused bill holds no mechanic or product row
2. lock the mechanic's row if the bill names one; for `'เครดิตช่าง'`, refuse
   `credit_balance + total > credit_limit` with `409 CREDIT_LIMIT_EXCEEDED` unless the
   body carries `overrideCreditLimit: true` (#21). Before the products on purpose: a
   refused bill holds no product locks, and the check and the balance update in step 9
   sit under one lock
3. `SELECT … WHERE id = ANY($ids) ORDER BY id FOR UPDATE` — **the ordering is the
   deadlock guard.** Two bills sharing two products, each locking in its own arrival
   order, deadlock; one order everywhere makes the second wait instead
4. the **complete** Thai error, built from that locked read and thrown once for the
   whole bill. `UPDATE … WHERE stock >= qty` cannot do this — a row count of zero
   cannot tell "not enough" from "no such product" — and fail-fast reports only the
   first bad line, so staff re-submit the bill once per missing item to find out what
   is short
5. deduct, `stock >= qty` kept in the predicate as an assertion against our own bugs.
   A sale never clamps at zero; `adjustStock` is the only path that may
6. issue the receipt number (#19) from the `device_no` of the token's `did`
7. insert the header and the lines, `cost_at_sale` from **the same locked read**
   (ADR-0008) — never re-read outside the transaction, never taken from the client
8. insert `movements` — one row per product, because `uq_movements_ref` is unique on
   `(tenant_id, type, ref_id, product_id)`
9. the ledger, rule for rule from `sales_repository.dart`: customer `points +=
   floor(total/10)`, `total_spend += total`; mechanic `total_sales += total`, a negative
   `mechanic_delta` into `total_discount`, a positive one into `total_markup`,
   `credit_balance += total` only for `'เครดิตช่าง'`. 🔴 `mechanics.total_credit` is
   **never written** — a legacy alias of `total_discount` from the JS app (#11). A bill
   that went past the limit on the flag writes one `audit_log` row
   (`sale.credit_limit_override`); the flag on a bill under the limit writes none
10. commit. Only after commit may anything external happen: no cache call and no
   enqueue inside a transaction that holds locks and can still roll back

**This closes a real race.** `sales_repository.dart` pre-checks stock *outside* its
transaction and then opens one to deduct; it has never bitten only because the shop
has one machine. The suite proves the fix: 200 concurrent bills against 50 units
produce exactly 50 bills, stock exactly zero, 50 distinct receipt numbers.

**Money.** The client owns the numbers — the receipt is printed before the request is
sent — and the server checks the arithmetic: more than `0.01` apart is
`409 TOTAL_MISMATCH`, within tolerance the client's values are stored. A line price is
**never** compared against the catalogue price: haggling is an ordinary day at this
counter. `pointsGranted` is `floor(total/10)`, computed from the persisted total.
Everything in between is integer satang (`src/common/money.ts`), never a float.

**The client's `id` is a natural idempotency key** (§3.1). A retry that lost its
`Idempotency-Key` — a page reload, an app restart — finds the bill already written and is
answered with it, before anything is locked or deducted. It used to be a 500 on the
primary key, which is worse than an error: staff read it as "that did not go through" and
ring the bill up a second time. A repeat carrying a *different* total is
`409 SALE_ID_REUSED`, because silently answering with the old bill would lose the new
one's money.

**The 201 carries back everything the client cannot compute** (§3.1, ADR-0010 §3), so it
patches its cache without waiting for the next `/bootstrap`: `customerAfter
{ id, points, totalSpend }`, `mechanicCreditBalanceAfter`, and — added by #82 — `shiftId`,
`items[] { lineNo, productId, costAtSale }`, `movements[]`, and `mechanicAfter` with all
four running totals. The response carries no `offlineOk`: it has no storage in phase 1.

🔴 **`mechanicAfter` has no `totalCredit`, on either endpoint.** `mechanics.total_credit`
is the JS app's legacy alias of `total_discount` (decision #11); the server never writes
it, and a field on the wire is a field the client will eventually patch.

🔴 **A widened response is a widened *replay*.** Both replay paths have to answer the same
body, field for field and in the same array order: the `Idempotency-Key` path does it for
free (the stored `response_body`), but `existingSale` rebuilds the answer from the rows,
so every new field needs a matching `SELECT` there — `shiftId` came back null for a bill
that really had a shift until that read learned about `shift_id`. `items[]` is ordered by
`line_no` on both paths, and `products[]` / `movements[]` by the order the products appear
on the bill; a replay that agrees on the values but not on their order is still a different
body. `test/sales.e2e-spec.ts` *the write-through fields (#82)* compares the two bodies
whole rather than field by field, which is the only assertion that stays true as the shape
grows. A replayed bill reports the rows as they stand now and moves nothing.

🔴 **`returning()` (`src/common/sql.ts`) is not optional.** TypeORM's Postgres driver
returns rows directly for `SELECT`/`INSERT` but `[rows, affected]` for `UPDATE`/`DELETE`,
so `result[0].stock` reads a number on one and `undefined` on the other — which reaches
Postgres as a NULL several statements later, where nothing points back at the cause.
Every `UPDATE … RETURNING` goes through it.

## The credit note (#22)

`POST /api/v1/returns` — `pos` device only, `Idempotency-Key` mandatory, a port of
`returns_repository.dart` (itself the port of `db.js` `createReturn`). One transaction,
in this order:

1. the idempotency claim (interceptor, before the handler)
2. `SELECT … FROM sales … FOR UPDATE` — `404 SALE_NOT_FOUND` / `409 SALE_VOIDED` come off
   this row, and both messages stay English, as they are in the Dart source
3. the guards, from the locked bill: **`409 RETURN_PRICE_MISMATCH`** for a line priced
   at anything this bill did not charge, then the over-refund guard — per product
   **and price**, `qty ≤ sold − already refunded`, summed across every prior credit
   note. The latter is built whole and thrown once as `409 OVER_REFUND`, whose message
   is `'คืนเกินจำนวนที่ขาย:'` and one line per bad product, so staff see every bad line
   at once instead of one resubmission at a time
4. the money, in integer satang: `refundDiscount = round2(refundSubtotal × discount /
   subtotal)`, `refundTotal = refundSubtotal − refundDiscount`
5. the drawer (#100), read `FOR SHARE` either way: a `'เงินสด'` refund takes
   `ShiftsService.requireOpenShiftIdFor` — `409 NO_OPEN_SHIFT` with no open drawer;
   `'โอน'` and `'หักจากเครดิต'` take `currentShiftIdFor`, null with no drawer
6. lock the mechanic's row, if the bill named one
7. `SELECT … FROM products … ORDER BY id FOR UPDATE`
8. issue the CN number (`CN07-2569-09-0001`)
9. insert the header and the lines — `cost_at_sale` copied from the **parent sale line**,
   never re-read from `products.cost`, which a weighted-average PO receive rewrites
10. stock back, one `movements` row per product, `type='return'`, `ref_id` = the **return**
   id (`uq_movements_ref` is `(tenant_id, type, ref_id, product_id)`, so keying on the bill
   would make the second credit note against it a 500). #82 answers those rows in
   `movements[]`; a **void** writes `type='void'` (migration `1788652800003`) against the
   same goods and the two must never be collapsed — every report groups by that column
11. the ledger, in proportion to `refundTotal / sale.total`: customer `points` and
   `total_spend`; mechanic `total_sales`, `total_discount`, `total_markup`, and
   `credit_balance` **only** for `refundMethod === 'หักจากเครดิต'`. Every accumulator
   clamps with `GREATEST(0, …)` — `total_spend`, `total_sales`, `total_discount` and
   `total_markup` have no CHECK at all, so a missing clamp there fails silently. All four
   come back as `mechanicAfter` (#82), alongside the unchanged `mechanicCreditBalanceAfter`
12. auto-void the parent bill once the cumulative returned quantity reaches what it sold

🔴 **The `FOR UPDATE` on the sale in step 2 is the whole endpoint's serialisation point.**
Without it two concurrent partial returns of one bill both read the same already-refunded
total, both pass step 3, and the shop refunds more than it sold. The Dart reference is
single-process and structurally cannot expose that race.

🔴 **The server decides what a refund is worth, not the client.** The body names a
product and a quantity; the amount comes off `sale_items`. Summing the client's own
`price` let a `pos` token credit 999,999 baht against a bill that sold the part for 85,
and the `GREATEST(0, …)` clamps then absorbed it in silence — `total_spend` and a
mechanic's `credit_balance` floor at 0, so one bogus credit note zeroed a tab and raised
nothing. The Dart reference has the same hole because there the client *is* the
authority. One bill may carry the same product on two lines at two prices, so "the price
of that product on the bill" is a set: a line is matched against that set and **refused**
if it is not in it, never silently corrected, and the quantity is bounded per
product-and-price so `[p1×1@85, p1×1@70]` cannot be credited back as `p1×2@85`.

The money is therefore **arithmetically more exact than the reference, not a verbatim
port of it**: `refundDiscount` is integer satang with half-up rounding where
`returns_repository.dart` does `round2()` on doubles, so the two differ by one satang on
an exact tie (subtotal 200.00, discount 3.00, one 85.00 line refunded: exact 1.275 →
server 1.28, Dart 1.27). The Thai strings are verbatim; the arithmetic is not.

A soft-deleted product is put back on the shelf like any other — the goods physically
exist again, and `POST /sales/:id/void` does the same. It used to be skipped here, with
no `movements` row to say the goods had come back at all. A product that has ever sold
cannot be hard-deleted: `movements` references `products` with no cascade.

`refundMethod = 'หักจากเครดิต'` on a bill with no mechanic is `409
REFUND_METHOD_NOT_ALLOWED`. The DTO whitelists the three methods but cannot see the
bill; without the check the credit note records a deduction from a tab that does not
exist, and the closing report does not count it as cash either.

🔴 **`mechanics.total_credit` is read and never written** (#11): the discount base is
`total_discount` unless it is zero, in which case it is the legacy `total_credit` — the
old app's own `(totalDiscount || totalCredit)` fallback, kept so a mechanic imported from
it reverses against the figure his screen actually shows.

A cash refund on a credit sale deliberately leaves `credit_balance` alone — the shop hands
over cash and the mechanic still owes what he owed. That is why the Returns screen warns
before it lets staff choose cash on a credit bill.

`returns.shift_id` is stamped from the device's own open drawer, never from the body.
🔴 **A cash refund needs an open drawer** (owner's decision on #100, 2026-09-13): with no
shift `closed_at IS NULL` on the calling device, `refundMethod = 'เงินสด'` is `409
NO_OPEN_SHIFT` and nothing is written — no stock, no CN number, no auto-void, no
idempotency claim. ⚠️ `POST /shifts/open` on the same day hands back today's closed
row, so **after today's close a cash refund waits for tomorrow's open** (the owner accepted
this with option A); a transfer refund is still possible. Until #100 it was
stamped null and the cash that left the drawer appeared in no closing report — the route
#94's `SALE_NOT_IN_OPEN_SHIFT` sends the counter down after today's close. The check
follows the bill's guards (a bad body is told so, drawer or not) and a key replay never
reaches it. It reads `FOR SHARE`, so the lock order is **sale → shift (shared) → mechanic
→ products → `doc_counters` → customer**, as on the void; the drawer's exclusive holders
(open, close, entries, retirement) take no other money-path lock, so no cycle. `'โอน'` and
`'หักจากเครดิต'` do not move expected cash, so they are still taken with no drawer and
stamped null — but they net into that shift's `grossProfit`, so they read the drawer
`FOR SHARE` too (`currentShiftIdFor`): a close cannot commit under a refund in flight and
leave it stamped onto an already-counted shift.

`GET /returns?saleId=&from=&to=&page=&limit=` is
newest-first and readable from both device roles; `from`/`to` are the filters
`02_API_SCREENS.md §3.7` defines for the refund history and behave exactly as
`GET /sales` does, with `saleId` the extra one a single bill's notes need.

## Sale reads and the void (#23)

`GET /sales` (filters `search`, `receiptNo`, `from`, `to`, plus `page`/`limit` — never
the whole table), `GET /sales/:id`, `GET /sales/:id/refunded-qty`, all readable from
both device roles. `refunded-qty` sums `return_items` across every credit note against
the bill: it is what makes the over-refund guard visible to staff *before* they submit.

`?receiptNo=` is an exact match, separate from `?search=`, for the same reason the
barcode lookup is separate from product search — what is printed on the paper a
customer brings back is one number, and a LIKE would offer several bills. `%` and `_`
in a search are escaped: they are characters staff typed, not wildcards.

**`POST /sales/:id/void`** — `manager` (or `owner`) plus the PIN, `pos` device only,
idempotent. Restores stock, writes a `movements` row per product (`type='void'`, no
`note` — the ledger row carries the type and the bare sale id as `ref_id`, and nothing
writes a Thai note on this path), reverses the customer and mechanic ledger in full,
marks the bill void and writes an `audit_log` row. Refused when the bill is already void
(`409 SALE_VOIDED`) or already has a credit note against it (`409 SALE_HAS_RETURNS` —
voiding then would restore that stock twice). **#94:** also refused unless the bill's
`shift_id` is the calling device's open drawer — `409 NO_OPEN_SHIFT` with no drawer,
`409 SALE_NOT_IN_OPEN_SHIFT` for a bill from a closed shift, another device's shift, or
with a null `shift_id` — so a closed shift's report never changes afterwards; an older
bill is undone by a credit note. The check runs after `SALE_VOIDED`/`SALE_HAS_RETURNS`
(a key replay is answered by the interceptor first) and reads the drawer `FOR SHARE`
between the sale lock and the mechanic lock, so a close waits for a void in flight.
Not audited: the PIN is already proven, like the other business-rule refusals.

Refusals are audited too (`sale.void.denied`, with the reason). This is a four-digit PIN
with no per-user rate limit until #44; brute-forcing it must not be invisible. That row is
written on its own connection because the 403 rolls `runIdempotent`'s transaction back — an
audit row written on it would vanish along with the attempt it was recording. The
connection comes from `AUDIT_DATA_SOURCE`, a two-connection pool of its own; taking it
from the request pool made a denial a request queuing for a second connection, which
timed out unrelated requests (see *Two rules* above, and
`test/void-denial-pool.e2e-spec.ts`).

🔴 **One thing to know before this ships:** the old app has no void button at all — a
bill is voided only as the automatic consequence of returning every line
(`02_API_SCREENS.md §2` lists the endpoint under "new, not a port", and asks for a
conversation first). #23 specifies it, so it is built — but the shop has never seen
this button.

**The ledger is reversed in full, never in proportion.** #21 made `POST /sales` apply
the customer's points and spend and the mechanic's tab, and `VoidService.reverseLedger`
takes exactly those figures back off, every accumulator clamped with `GREATEST(0, …)`.
In full is safe only because a bill with a credit note against it is already refused
above (`SALE_HAS_RETURNS`), so there is no partial refund to share out the way
`POST /returns` has to. `total_credit` is not written (#11).

## The cash drawer (#28)

`GET /shifts/current` and `/shifts/history` are readable from **both** device roles —
looking at the drawer does not touch it (ADR-0004) — while `POST /shifts/open`,
`/close` and `/current/entries` are `pos` only.

⚠️ **`is_active` does not mean "open."** Closing leaves it true: the shift stays *this
device's current drawer* until the next open archives it, exactly as
`shifts_repository.dart` does, and `uq_shift_active` (unique on
`(tenant_id, device_id) WHERE is_active`) depends on that meaning. "Open" is
`closed_at IS NULL`. Do not repurpose the flag.

- Re-opening on the same day returns the existing shift untouched, starting cash and
  all: staff press the button twice. A new day archives the previous shift **first**,
  flagged `auto_archived` when it was never closed, so a day's takings are never lost.
- A drawer entry after close is `409 DRAWER_CLOSED` with the message verbatim from
  `db.js`; no drawer at all is `409 NO_OPEN_SHIFT`.
- Reads are tenant-wide, writes are per device. In this shop those coincide
  (`one_pos_per_tenant`), but a read filtered by the caller's device would show a
  `backoffice` machine nothing, which is not what "readable from both" means.
- **`shift_id` is stamped on a sale at write time**, from the device's own *open*
  drawer — never from the request body. The closing report is computed by `shift_id`,
  never by a timestamp window: a window breaks across midnight and cannot separate two
  machines.
- 🔴 **No open drawer, no money** (owner's decision, 2026-09-13: "ต้องเปิดกะก่อนรับเงิน
  ทุกกรณี"). `POST /sales` and `POST /mechanics/:id/credit-payments` answer
  `409 NO_OPEN_SHIFT` when the calling device has no shift with `closed_at IS NULL` —
  never opened, or already closed — for every payment method, and write nothing (no
  stock, no ledger, no RC/CP number, no idempotency claim). Until then both stamped null
  and took the money, ported from the old app; that cash appeared in no closing report.
  Replays are not refused: the check runs after both replay paths. The helper is
  `ShiftsService.requireOpenShiftIdFor`, and it reads the row **`FOR SHARE`** so a close
  waits for bills in flight and a bill behind a committed close is refused, rather than
  landing on a shift whose cash was already counted. `POST /returns` is covered for
  `'เงินสด'` only (#100); a transfer or tab-deduction credit note still stamps null with
  no drawer open (`currentShiftIdFor`). `shift_id`
  stays nullable in the schema: imported rows are legitimately null.
- `closeForRetirement()` is the operation `POST /devices/:id/retire` (#144) calls to
  close a machine's drawer in the same transaction that stamps `retired_at` — see
  *Devices* below; `test/shifts.e2e-spec.ts` exercises it through that endpoint (the
  probe route #28 mounted is gone). **It archives as well as closes**: normally the
  device's *next* open archives its drawer, but a retired device never opens again, so an
  active row would be stranded — `history()` (`NOT is_active`) would hide that day's
  takings forever while `current()` showed a drawer nothing could close.
- 🔴 **Rows written before 2026-09-13 (and imported ones) can still carry no
  `shift_id`.** The shipped app's closing report counts by date key
  (`closing_report.dart`), not by shift. New sales and credit payments can no longer be
  taken without a drawer, so #30 only has to decide what to do with those older rows and
  with non-cash credit notes (`POST /returns` still stamps those null with no drawer open;
  cash refunds need one since #100).
- 🔴 **Expected cash also has a credit-payment term** (#24, #30's first AC): a mechanic
  settling his tab in cash is money in the drawer that no sale accounts for. Sum
  `credit_payments WHERE shift_id = … AND payment_method = 'เงินสด'`; the transfers must
  not be counted, which is what that column exists for.

## Devices (#144)

ADR-0004 *"การผูกเครื่อง"*. **`owner` only** on all three routes (ADR-0004 keeps it there until the
shop says whether a manager may move the till), from either device role or a session with no
device token. Both writes take an `Idempotency-Key`.

- **`POST /devices` `{label, role}` → `201 {device, enrolCode}`.** The server picks the id
  (`newId('dv')`) and `device_no`; anything else in the body is ignored. `device_no` is
  `max + 1` over every row **including retired ones**, under a per-tenant
  `pg_advisory_xact_lock`, so a number — and its receipt series — is never handed out twice.
  The enrolment code is 8 upper-case hex characters, stored only as its SHA-256, valid 15
  minutes (ADR-0004's proposal; still an owner question) and single-use. The browser trades it
  at the pre-existing `POST /auth/device` for the device token; nothing about that endpoint
  changed. A second live `pos` is `409 POS_DEVICE_EXISTS` (pre-check, with a
  `one_pos_per_tenant` 23505 backstop); number 100 is `409 DEVICE_NO_EXHAUSTED`. Audit
  `device.create` — never the code. ⚠️ The idempotency layer stores the handler's response,
  so the plaintext code sits in `idempotency_keys` / the Redis replay cache for the key's
  lifetime; it is single-use and dead after 15 minutes, which is why that was accepted.
- **`GET /devices`** — every device, retired included, by `device_no`. Never a hash.
- **`POST /devices/:id/retire` `{physicalCash?}` → `200 {device, shift}`.** One transaction:
  1. the device row **`FOR NO KEY UPDATE`** — `404 DEVICE_NOT_FOUND` (also another shop's,
     via RLS) or `409 DEVICE_ALREADY_RETIRED`;
  2. `ShiftsService.closeForRetirement` — the drawer row **`FOR UPDATE`**, which waits for any
     sale / void / refund / credit payment holding it `FOR SHARE`. An open drawer with no
     `physicalCash` is `409 PHYSICAL_CASH_REQUIRED` (`details {shiftId}`), never a defaulted 0.
     A drawer closed but still `is_active` is archived with its own count kept;
  3. `retired_at = now()`, outstanding enrolment code cleared;
  4. audit `device.retire` (shift id + counted cash) on the same manager, so a failed audit
     rolls the retirement back.

  🔴 **Lock order is devices → shifts.** `ShiftsService.open` now reads the device row
  `FOR SHARE` before it locks the drawer and refuses a retired device with
  `403 DEVICE_ROLE_FORBIDDEN`: the retired till's access token lives up to 15 minutes
  (ADR-0009, no denylist), and a drawer opened in that window is the stranded shift retirement
  exists to prevent. Nothing on the money path locks `devices` (document numbers read it
  unlocked, and no table has a foreign key to it), so the drawer's `FOR SHARE` readers still
  cannot cycle with an exclusive locker. `NO KEY` so a future FK to `devices` (which takes
  `FOR KEY SHARE`) is not blocked by a retirement.
- **After the commit** the device token is refused by `POST /auth/token` (401), its refresh
  token by `/auth/refresh` (401, ADR-0009), and the device can issue no document number and open
  no drawer. `test/devices.e2e-spec.ts` walks enrol → `/auth/device` → login (`did`/`drole` in
  the JWT) → retire → login and refresh refused. An already-issued access token still *reads*
  until it expires — by ADR-0009's design.
- **Not built:** re-issuing a code for an existing device (a lost token is a new device, per
  ADR-0004), changing a label, or any client screen.

## Mechanic credit payments (#24)

`POST /mechanics/:id/credit-payments` — the mechanic comes in and pays down his tab.
`pos` only (it takes cash over the counter and prints a receipt), idempotent, and one
transaction: `mechanics FOR UPDATE` → the open drawer (`409 NO_OPEN_SHIFT` without one) →
the CP number → the row → the reduced balance.

- **Lock order is mechanic → `doc_counters`,** the money path's relative order. It
  cannot deadlock against a sale or a credit note today — `doc_counters` is keyed by
  `doc_type`, so the CP row is never the RC or CN row and the mechanic is the only
  resource they share — but the order costs nothing and stays right if that changes.
- 🔴 **An overpayment is refused, not clamped.** `credit_balance` is written with
  `GREATEST(0, …)` as the ticket asks, but a clamp on an amount nobody checked turns
  100,000 keyed for 1,000 into a wiped debt and a receipt for cash never handed over —
  the same shape as the #22 money bug. More than the tab without
  `allowOverpayment: true` is `409 CREDIT_PAYMENT_EXCEEDS_BALANCE` (English message; the
  client owns the Thai dialog, which the shipped app already shows —
  `mechanics_screen.dart:1331`). With the flag it goes through and writes one
  `audit_log` row, exactly as #21's credit-limit override does.
- **`paymentMethod` is required and whitelisted** to the two the intake dialog offers,
  `'เงินสด'` and `'โอน/QR'`. A method the server guessed is a closing report that is
  wrong in one direction or the other: count a transfer as cash and the drawer shows a
  shortfall the size of the transfer every single day, which is how staff stop believing
  the report at all. The column is new (`payment_method`, migration `…005`) because the
  Drift port dropped the JS app's `p.method`; `cash_drawer_screen.dart:121` says so.
- **`shift_id` is stamped like a sale's** — the device's own open drawer, never the body.
  That column is what #30 sums cash settlements by.
- 🔴 **No open drawer is `409 NO_OPEN_SHIFT`, cash and transfer alike** (owner's
  decision, 2026-09-13 — this replaces the old "null when none is open; refusing it here
  would be a new rule" behaviour). Order: mechanic `FOR UPDATE` → client-`id` replay →
  drawer `FOR SHARE` → overpayment check → CP number. After the replay, so a payment
  committed while the drawer was open still answers once it has closed; before the
  overpayment check and the counter, so a refusal leaves no hole in the CP series.
- **Two defences against a duplicate, as on `POST /sales`:** the `Idempotency-Key`, and
  an optional client `id`. The same id with a different mechanic, amount or method is
  `409 CREDIT_PAYMENT_ID_REUSED`. The id matters because the client's outbox
  (`pending_credit_payments`, Drift schema v5) can resend a payment long after the key's
  24 h have run out — a device offline over a weekend — or under a fresh key after a
  person confirms a refused overpayment; both replay the stored payment by id alone.
  The replay is checked **before** the overpayment check, or a replayed full settlement
  would meet the zero tab it created and be refused.
- ⚠️ **`shift_id` is the shift open when the server receives the payment,** not when the
  cash was taken. A payment queued offline and sent after the drawer closed is now
  refused with `409 NO_OPEN_SHIFT` (the outbox keeps it for a person) unless a drawer is
  open by then, in which case it lands in that shift — #30 has to know that.
- The mechanic's `deleted_at` is **not** filtered, exactly as `POST /sales` does not
  filter it: he owes the money either way, and refusing it loses the shop both the cash
  and the record of it. An id that never existed is `404 MECHANIC_NOT_FOUND`, thrown off
  the locked read rather than left to the insert's foreign key (a `23503` surfaces as a
  500).
- The response carries the payment plus `mechanicCreditBalanceAfter` — every *value*
  the transaction moved (#82) and nothing it did not. There is no `mechanicAfter` here:
  the three running totals are untouched, and handing them back invites the client to
  patch them from a stale read. `mechanics.updated_at` also moves and is not returned;
  the client stamps its own, as it does after every write.

## The catalogue (#16)

`src/products/` — products, categories, suppliers, `movements`, ported from
`products_repository.dart` / `suppliers_repository.dart` / `movements_repository.dart`.
Reads are open to any tenant token; every write is `manager`/`owner`, both device roles,
`Idempotency-Key` mandatory (`02_API_SCREENS.md §4`). `test/catalogue.e2e-spec.ts` replays
every case of `frontend/test/products_repository_test.dart` at the HTTP seam.

- **Products are soft-deleted** (`01_DATABASE.md §10`); every read hides tombstones except
  `?updatedSince=`, which is the sync read and must carry them.
- 🔴 **`?updatedSince=` is keyset-paged on `(updated_at, id)`.** Many rows share one
  `updated_at` (a sale stamps every line with the transaction's `now()`; the platform import
  stamps a catalogue at once), and `updatedAt` on the wire is millisecond-truncated, so a
  reader that paged with `updated_at > max(updatedAt)` skipped the rest of a tie cut by a page
  boundary — or, with a tie larger than a page, was served the same page forever. The response
  carries `meta.nextCursor: { updatedSince, afterId }` (microsecond precision, or `null` on an
  empty page); the reader sends both back and always asks for the first page after it
  (`page>1` with `updatedSince` is a 400; `afterId` without it is a 400). `updatedSince` alone
  still answers `updated_at > $ts`, as specified. A pass is done when a page is shorter than
  `limit`; its last `nextCursor` is where the next refresh starts. Proved by *a keyset sync pass
  over a tie larger than a page* (nine rows, one microsecond, limit 3).
- 🔴 **Not solved here — late commits.** A write stamped with its transaction's start time
  (`now()`) can commit after a reader has already moved its cursor past that time, and is then
  never read. Recorded as #55's read-back-window question under ADR-0010 *ยังไม่เคาะ*. **Until
  #55 decides that window, a client must start each refresh a safety margin before its stored
  cursor** (an `updatedSince` some seconds earlier, no `afterId`), otherwise the protocol above
  loses late-committing writes; the rows it reads again are upserts by id, so re-reading is harmless.
- **`?partNo=` is one product, trimmed and case-insensitive** (`lower(part_no) = lower($n)`,
  served by `uq_products_partno_ci`) — the same comparison uniqueness uses. A `partNo` that is
  present but blank answers an empty page, never catalogue page 1.
- **The platform import pre-flights case-duplicate part numbers** (`tenant-import.service.ts`):
  a snapshot whose products share a part number ignoring case is a 400 naming the ids, before
  the transaction, like the negative-stock pre-flight. It compares with JS `toLowerCase()`; a
  non-ASCII pair that JS and Postgres `lower()` fold differently would still reach the index as a 500.
- **`?search=`** puts the predicate on `SEARCH_EXPRESSION` — the exact expression
  `idx_products_search` is built on — then rechecks `part_no`/`name`/`name_th` so matching stays
  what the screens do (no `compat`). 🔴 **Under RLS the trigram index is not used:** as
  `pos_app`, `LIKE` (`textlike`) is not LEAKPROOF, so the planner will not run it inside the index
  ahead of the tenant policy and the search is a tenant index scan plus a filter. The e2e pins
  both plans (owner: the index; `pos_app`: not the index). Open design question
  (`01_DATABASE.md §5.2`) — do not "fix" it by marking functions LEAKPROOF or bypassing RLS.
- **A part number is unique case-insensitively among live products**, enforced by the database:
  `uq_products_partno_ci (tenant_id, lower(part_no)) WHERE deleted_at IS NULL` (migration
  `1788652800007`), so the platform import cannot bypass it. A `23505` on it maps to
  `409 DUPLICATE_PART_NO` / `รหัสอะไหล่นี้มีอยู่แล้ว`; two concurrent `BP-1`/`bp-1` creates give
  exactly one 201. A tombstone's number is free to reuse.
- **`adjust-stock` clamps at zero** (`01_DATABASE.md §7.6`) **after** validating the body: an
  integer `delta`, a `type` of `adjustment-in`/`adjustment-out` whose direction matches the sign,
  and a result that fits `INT`. The `movements` row keeps the requested `delta` beside the clamped
  `stock_after`, as the Dart repository does. One `stock.adjust` audit row (#43). It locks one
  product row and nothing else, so it cannot join the sale path's lock order.
- **Categories are hard-deleted with no foreign key** from `products.category`; the product
  keeps the name. `GET /categories` answers `[{name, color}]` for listed names from one query,
  and stands the five seed names in when the table is empty, as the Dart repository. **The
  colour of an orphaned name is the client's** — its hash fallback (`catColor` in
  `products_repository.dart` / `AppColors.catColor`); the API adds no colour to products.
- `PATCH /products/:id` never reads `stock` — stock moves only through writes that log a movement.
- Product money is now a string on the wire (`price`/`cost`, §1.1); it was a number before #16.

## Tenant import (#185, #238, #239)

`POST /api/v1/platform/tenants/:id/import` — admin plane, `PlatformAuthGuard`, onboarding only
(ADR-0005: never a per-tenant restore). It turns a shop's `SnapshotRepository.exportSnapshot()`
file (`sa_*` + `__meta`) into the tenant's first rows, per `01_DATABASE.md §9`.

**It answers `202 Accepted` with a `jobId`, not `201` (#239, owner decision 2026-09-15).** A
synchronous import took ~6.4 s per 2 MiB locally (four months, 2,043 bills,
`test/import-snapshot.e2e-spec.ts`) and nginx allows a 10 MiB body — a bigger shop's file can
run past `proxy_read_timeout 30s` while the transaction goes on to commit, so the operator got a
504 for a write that had actually succeeded, and a retry read back as a confusing 409. The route
now does two things in order:

1. **Pre-flight, synchronously** — no write, so a bad file still answers 400/409 immediately.
   Checks the tenant has no transaction data yet (`sales`/`returns`/`purchase_orders`/
   `credit_payments`/`quotes`/`shifts` all empty, else `409`), then `01_DATABASE.md §9` step 2's
   list: negative stock, a case-duplicate part number, a non-numeric category position, a
   duplicate document number (`receipt_no`/`cn_no`/`po_no`/`quote_no`, and credit payments' own
   `receipt_no` — a different table), an unparseable date anywhere `parseDate()` would otherwise
   default to import time, a value that used to clamp silently (negative mechanic
   `creditBalance`/customer `points`/product `minStock`, or a sale/return/PO/quote line `qty`
   that was zero, negative, non-integer or missing), a money field `round2()` would otherwise turn
   into a silent 0 (every price/cost/total/balance `tenant-import.service.ts` rounds — products,
   suppliers, customers, mechanics, sales, returns, POs, quotes, credit payments, shifts, drawer
   entries, `settings.taxRate` — refused if it is present and does not parse as a finite number,
   and refused as negative/non-positive on the subset Postgres itself `CHECK`s, e.g.
   `products.price/cost >= 0`, `credit_payments.amount > 0`), and #238's tombstone/FK checks
   (`missingRefs`/`unnamed`/`returnsWithoutSale`). The first five are `snapshot-preflight.ts`
   (pure, unit-tested on their own — `snapshot-preflight.spec.ts`); the tombstone checks are
   `snapshot-tombstones.ts` (#238/#252, unchanged). **#22's lesson applied to import: validate,
   then clamp — never the other way round.** A clamp on an unvalidated value (the old
   `Math.max(0, …)`/`Math.max(1, …)` calls, or `round2()`'s old `isNaN(num) ? 0 : …`) turns a loud
   corruption into a quiet one; every such clamp in `tenant-import.service.ts` now runs only on a
   value pre-flight has already accepted — `round2()` itself now throws (never returns 0) if an
   unparseable value somehow reaches it anyway, as defence in depth, not a fallback path.
2. **Enqueue** — a row in `import_jobs` (own migration, `1788652802200-ImportJobs.ts`) carries the
   whole snapshot as `jsonb`, and a tiny `TenantImportJobPayload` (`{tenantId, correlationId,
   importJobId}`) goes on its own queue, `QUEUE_TENANT_IMPORT` — **not** `QUEUE_BACKUP`, even
   though both are one-shot admin-plane whole-tenant jobs (ADR-0005 groups them): `@nestjs/bullmq`
   starts one BullMQ `Worker` per `@Processor(queueName)` class, and two Workers consuming the
   same queue name race for every job — `BackupProcessor`'s `if (name !== JOB_TENANT_EXPORT)
   return {skipped:true}` would then silently "complete" a `tenant.import` job about half the
   time without ever running `TenantImportProcessor`. A queue name costs nothing extra (no new
   Redis service — it is a keyspace in the existing `redis-queue`).

`GET /api/v1/platform/tenants/:id/import/:jobId` (same guard) reads `import_jobs` directly —
`status`: `queued|running|succeeded|failed`, plus `tombstones`/`droppedSuppliers` on success or
`error` on failure. No BullMQ `job.getState()` call: the row **is** the status, so a poller sees
the same answer whether the worker is still warming up, mid-transaction, or long finished and
its BullMQ job already reaped by `removeOnComplete`.

**Why Postgres, not Redis, holds the snapshot.** `redis-queue` runs `noeviction` (BullMQ must
never lose a job it hasn't finished), so putting a 10 MiB body straight into a job's own `data`
— the obvious BullMQ-native place — means a burst of large imports grows Redis memory unbounded
with nothing to page it out; Redis-with-a-TTL was considered and rejected for the same reason
(nothing frees the memory early, and losing it before the worker reads it is worse than never
having a TTL). `import_jobs.payload` is `jsonb`, which Postgres TOASTs out of the row
automatically, and is cleared (`payload = NULL`) once a job reaches a terminal state — the
outcome (`result`/`error`) stays, the shop's actual data at rest does not.

🔴 **`idempotency-routes.spec.ts` needed no change for #239.** `POST .../import` and
`GET .../import/:jobId` never call `idempotencyParamsOf`/`runIdempotent` — they are platform-admin
routes, not one of the pinned POS `Idempotency-Key` claiming routes that spec scans for — so its
directory walk (which does cover `src/platform/`) finds nothing to record for them and skips both
silently, by the same `if (!claimed && !mentions) continue` rule every non-idempotent route hits.
Their own duplicate-request defence is `uq_import_jobs_active` (below) plus the
tenant-already-has-bills pre-flight check, not that module.

**Idempotency.** `import_jobs (tenant_id) WHERE status IN ('queued','running')` is a partial
unique index: a second `POST .../import` for a tenant with one already in flight is a `409` on
that constraint (checked after pre-flight, so a bad file never even reaches it). A **completed**
import (success or failure that committed nothing) is refused the same way it always was — the
tenant-already-has-bills pre-flight check — since a successful import leaves those tables
non-empty and a failed one leaves them exactly as empty as before, so a fresh attempt is a fresh
row, no special-casing needed. `TenantImportProcessor` re-runs the full pre-flight (defence in
depth — the payload cannot have changed since enqueue, but nothing besides the partial unique
index stops a second code path from writing sales in between) before writing.

**A worker that crashes or stalls no longer wedges the tenant forever (#239 review issue 1).**
Nothing transitions a `queued`/`running` row on its own if the process running it dies (a killed
container, an OOM, a BullMQ-detected stall with no clean `failed` event) — `uq_import_jobs_active`
would then refuse every future import for that tenant, permanently, with no operator-visible cause
beyond a `409`. Two independent nets:
- `createJob` reclaims a stale row **in the same transaction** as its own insert: any row for the
  tenant still `queued`/`running` with `COALESCE(started_at, created_at)` older than
  `STALE_JOB_CEILING_MINUTES` (30) is marked `failed`, `error = 'stale: worker lost'`, payload
  cleared, before the new row is inserted — a genuinely in-flight row's timestamp is recent and
  survives untouched, so a real concurrent attempt still hits the unique index and gets `409`.
  30 minutes is deliberately generous: locally the import runs ~6.4 s per 2 MiB, so the 10 MiB
  body limit (`IMPORT_BODY_LIMIT`) is ≈32 s even before retries, and `DEFAULT_JOB_OPTIONS`' 3
  attempts with exponential-jitter backoff add at most ~7 s more — a job that is merely slow, even
  through every retry, finishes in well under two minutes.
- `TenantImportProcessor.onFailed` (`@OnWorkerEvent('failed')`) marks the job failed the moment
  BullMQ itself gives up on it — on whichever worker receives the event, not necessarily the one
  that was running it — so a wedged tenant is freed within the retry backoff instead of waiting on
  the 30-minute ceiling; the ceiling is the fallback for the case where no worker survives to
  receive that event at all.

Manual recovery, if both nets are somehow bypassed (e.g. a row hand-inserted or corrupted by
something outside this code path): find and clear it —

```sql
SELECT tenant_id, id, status, started_at, created_at FROM import_jobs
 WHERE status IN ('queued', 'running') AND COALESCE(started_at, created_at) < now() - interval '30 minutes';

UPDATE import_jobs SET status = 'failed', error = 'stale: manual recovery', payload = NULL, finished_at = clock_timestamp()
 WHERE tenant_id = '<tenant-id>' AND id = '<job-id>' AND status IN ('queued', 'running');
```

**Retries and the DLQ.** `QUEUE_TENANT_IMPORT` uses `DEFAULT_JOB_OPTIONS` like every other queue
(3 attempts, BullMQ's builtin exponential-jitter backoff, #201) — a transaction failure here is
almost always deterministic (bad data the pre-flight missed, or a row Postgres itself refuses,
e.g. the drawer-entry `CHECK type IN ('in','out')` `test/import-snapshot.e2e-spec.ts` pins — an
`amount` outside `CHECK amount > 0` is now refused in pre-flight itself, issue 3 below), so a retry
rarely helps, but it costs nothing more than the existing backoff delay and keeps every queue
behaving the same way. `import_jobs.payload` is kept across a non-final failure (a retry has to
re-read it) and cleared only once the last attempt is known final — `process()`'s own catch uses
`job.attemptsMade + 1 >= maxAttempts` (the same rule `TenantJobRunner.routeToDlq` uses for
everything else); `onFailed` above uses BullMQ's own post-attempt `job.attemptsMade >= maxAttempts`
and calls `markFailed` a second time in the ordinary case where `process()`'s catch already ran —
idempotent, and cheaper to allow than to gate on a status read first. Neither path shares
`TenantJobRunner.runWithTenantContext`, which opens a `pos_app`/RLS transaction scoped to one
tenant — not what this job does (see below).

**A crash between the import's `COMMIT` and recording success cannot happen (#239 review issue
2).** `writeSnapshot` writes `import_jobs.status = 'succeeded'` (with `result`, and `payload`
cleared) as the **last statement inside the same `adminDs.transaction`** as the business data —
there is no separate `markSucceeded` call after the fact for a crash to land between. Either both
commit or neither does: a rolled-back import (pre-flight passed, but a later row Postgres itself
refuses) leaves the row exactly as it was, and `TenantImportProcessor`'s catch then marks it
`failed` the ordinary way. `processJob` checks `status === 'succeeded'` before doing anything else,
so a retry that lands after a successful commit — the worker's own acknowledgement lost, not the
import — answers the transaction's own recorded result instead of importing the shop a second
time; without that check it would re-run pre-flight against a tenant that already has bills and
answer `409` instead, which is exactly how `test/import-snapshot.e2e-spec.ts`'s idempotent-replay
test proves the check is wired in.

**No `TenantJobRunner`.** Every other BullMQ processor runs its work through
`runWithTenantContext`, which sets `app.tenant_id` on the `pos_app` role and enforces the #213
commit ceiling. The import's whole point is writing historical rows as the **owner** role
(`ADMIN_DATA_SOURCE`, exactly as the synchronous endpoint always has — RLS would refuse an
insert whose `updated_at`/`created_at` predates "now", and the owner role is outside the #213
ceiling by design: "platform provisioning and import" is one of the roles the README's
*The transaction ceiling* section names as exempt). `TenantImportService` is therefore already on
`tenant-door.spec.ts`'s allowlist for `ADMIN_DATA_SOURCE`, and `TenantImportProcessor` reaches no
pool of its own at all — it only calls the service.

**`import_jobs` carries no RLS.** See that migration's own comment and *Schema and migrations*
above: it has a `tenant_id` column (for lookup) but only `ADMIN_DATA_SOURCE` ever touches it, so
a `pos_app` RLS policy would guard nothing real. `test/schema.e2e-spec.ts` asserts the no-RLS,
no-`pos_app`-grant shape explicitly, since it is deliberately absent from
`RowLevelSecurity1788652800001`'s exported table lists (which that migration's own `up()`
executes against — appending a not-yet-created table there would break a from-empty run).

**Still true, unchanged by #239:**
- An imported bill carries no `shift_id` (the file does not link bills to shifts), so a closing
  report for an imported shift shows `cashSales 0.00` — only starting cash and drawer entries.
  Documented, not fixed (`01_DATABASE.md §9`); #239 leaves it exactly as found.
- Every imported shift is archived (`is_active = false`) — see *The cash drawer* /
  `snapshot-tombstones.ts`'s header comment for the review that fixed the "active drawer with no
  device" bug (#185, PR #244).
- The 10 MiB body limit + verified-platform-token body parser (`app.setup.ts`'s `IMPORT_ROUTE`,
  #244) is unchanged: `POST .../import` is still the only route it applies to (Express's `use()`
  path-prefix matching also covers `GET .../import/:jobId`, harmlessly — a GET has no JSON body
  for it to parse).

Read `docs/handoff_log/close4-synthetic-snapshot-2026-09-15.md` for #185's synthetic-snapshot
scrutiny round that found the gaps #239 closes, with a dated correction note about #252's
supplier-drop landing after that document was written.

## Bootstrap and settings (#25)

`src/bootstrap/` and `src/settings/` — Checkout's one-shot read (`02_API_SCREENS.md §3.1`) and
the per-tenant shop-settings row (`01_DATABASE.md §5.7`), ported from `settings_repository.dart`.

- **`GET /bootstrap`** answers `{ products, categories, customers, mechanics, settings }` —
  every list unpaginated, tombstones excluded — reusing each entity's own `GET` endpoint column
  list and row mapper verbatim (`products.service.ts`/`customers.service.ts`/
  `mechanics.service.ts` export `COLUMNS` + `toProduct`/`toCustomer`/`toMechanic` for exactly
  this), so the shape the client writes into Drift can never drift from what
  `GET /products`/`/customers`/`/mechanics` would answer on their own. Field names are the
  contract (ADR-0010): see `02_API_SCREENS.md §3.1` for the full JSON shape.
- **Not included: the current shift.** Per `02_API_SCREENS.md §3.1` and `03_ARCHITECTURE.md:81`,
  shifts are not cached and are per-device — the client reads `GET /shifts/current` for that,
  same as it always has.
- **The `ETag` is a strong hash of the exact response body**, not a Redis-backed cache: two
  requests answer the same ETag iff they would answer the same bytes, so "any included entity
  changing changes the ETag" holds with no separate invalidation bookkeeping to keep in step
  across five tables. A `304` therefore still costs the same reads as a `200`; only the body is
  skipped. #32 did not add a `t:{tid}:bootstrap` Redis cache (02_API_SCREENS.md §5's sequence
  diagram sketches one, but neither §4.2 nor §5 assigns it) — see *The server cache (#32)*.
  🔴 **A cross-origin dev client needs both CORS entries `app.setup.ts` carries for this:**
  `If-None-Match` in `allowedHeaders` (or the preflight for the conditional re-fetch is refused)
  and `ETag` in `exposedHeaders` (or `fetch()` hides the header the client needs to echo back
  next time). Production is same-origin (nginx serves the client), so neither matters there.
- All five reads run on the single transaction the request already has open
  (`common/request-context.ts`) — `READ COMMITTED`, not one atomic cross-statement snapshot,
  since `TenantGuard` has already issued a query on it by the time a handler starts and isolation
  can no longer be raised. This is the same consistency level every other multi-entity path in
  this codebase (the sale path's lock order included) already operates under.
- **`GET/PATCH /settings`**: `GET` is open to both roles (both device roles too, like every
  other plain read); `PATCH` is `manager`/`owner`, `Idempotency-Key` mandatory, and writes one
  `stock.adjust`-style `settings.update` audit row (#43) naming only the fields actually
  touched. `updated_at` is stamped on every write. A missing settings row answers
  `404 SETTINGS_NOT_FOUND` — not a code a client should ever see or need to handle, since
  `POST /platform/tenants` inserts `tenants`+`users`+`settings` transactionally
  (`02_API_SCREENS.md §4.1`); it exists so a data-integrity fault is loud rather than a bare 500,
  which is why it carries no `02_API_SCREENS.md §8.1` entry — that section is for errors a
  client is expected to branch on.
- 🔴 **`PATCH /settings` validates more strictly than the Dart client
  (`settings_screen.dart:570-583`).** The Dart `_save()` accepts a blank `shopName`, any
  `double` for `taxRate` (any sign, any precision), and any `int` for `quoteValidDays`
  (including zero or negative) — whatever `double.tryParse`/`int.tryParse` returns, unchecked.
  The server requires a non-empty `shopName` (nothing in `01_DATABASE.md §5.7` or
  `02_API_SCREENS.md` says it may be blank), `taxRate` in `[0, 100]` at two decimals, and
  `quoteValidDays` a positive integer up to 3650. This is deliberate (validate before storing,
  not clamp — the same lesson as #22's `RETURN_PRICE_MISMATCH`), but it means a value the
  offline Drift build accepts today answers `400` from the server — #55/#56's client work needs
  to know this before wiring `PATCH /settings` through, and the Drift build itself enforces
  none of it (the phase-1 divergence this ticket accepts, same shape as #24's).

## Quotes and parked sales (#27)

`src/quotes/` and `src/parked-sales/`, ported from `quotes_repository.dart` /
`parked_repository.dart`. 🔴 **Neither writes `products` or `movements`.** The one exception
is `POST /quotes/:id/convert`, which sells through `SalesService.create` — it never writes
stock itself. `test/quotes-parked.e2e-spec.ts` asserts every product's stock and the
ledger's row count across the whole lifecycle.

- **Quotes: any role, both device roles; convert is `pos` only.** Every write takes an
  `Idempotency-Key`. A QT number comes from `DocNumberService` in the token's device series, so a
  session with no device token is `403 DEVICE_ROLE_FORBIDDEN`.
- **`validUntil = now + (validDays ?? 30) × 24h`.** This is the Dart data layer's literal. The
  server never reads `settings.quote_valid_days`, and neither does the Flutter client:
  `_handleSaveQuote` (`checkout_screen.dart:515`) passes no `validDays`, so every quote gets 30
  days whatever the setting says. The JS screen used to pass `quoteValidDays`; that is a
  pre-existing JS→Flutter gap, not something this server closes.
- **`isExpired` is `valid_until < now()`, evaluated at read time on every quote whatever its
  status. `isConverted` is `status = 'converted'`** — `QuoteRowStatus`. The stored status is never
  rewritten to `'expired'`. `?status=open|expired|converted` is `quotes_screen.dart`'s
  `_applyFilter`: `expired` excludes converted quotes.
- **A quote is held to the sale's arithmetic when it is saved** (`assertSaleTotals`,
  `409 TOTAL_MISMATCH`), so a quote that saves is a quote that converts.
- **`PATCH` takes header text only** (`customerName`, `customerPhone`, `notes`). It refuses
  `status`, lines and money with a 400, and refuses any change to a converted quote with
  `409 QUOTE_ALREADY_CONVERTED`. The screen's old convert, `updateQuote(status: 'converted')` followed
  by `POST /sales`, is the half-finished state `02_API_SCREENS.md §3.8` calls out, so it is not
  reachable here. `DELETE` works on any quote, as the screen allows.
- **Convert is offered on `!converted && !expired`** (`quotes_screen.dart:559`), not on
  `status = 'open'`, so an imported row stored as e.g. `'cancelled'` but still valid converts.
- **Convert body = `POST /sales` minus lines and money** (`id`, `paymentMethod`, customer,
  mechanic, `mechanicDelta`, `overrideCreditLimit`). The lines, prices, discount and total are
  the saved quote's. Sending any of them is a 400: an edited cart is a different bill, and a
  different bill goes through `POST /sales`. A quote line with no product goes to the sale path with
  an empty id, as Checkout does, and comes back as `สต็อกไม่พอ … ไม่พบในสต็อก`.
- 🔴 **Lock order on convert: quote `FOR UPDATE` → the sale path's own order.** Nothing else
  locks a quote after a shift, a mechanic, a product or a counter, so this cannot form a cycle.
  Converting twice cannot produce two bills:
  - A second request waits on the quote row, then finds it converted.
  - The same bill `id` replays the original. The sale is replayed through `existingSale`, and the
    quote is re-read. The e2e compares the whole body.
  - Any other `id` gets `409 QUOTE_ALREADY_CONVERTED`, with `details.convertedSaleId`.
  - The replay check runs before the expiry check, so a quote converted on its last day still
    replays the next morning.
  - 🔴 **A convert retry must reuse its `Idempotency-Key`.** A retry with a fresh key on a quote
    that has since been deleted (DELETE works on converted quotes, as in Dart) or purged answers
    `404 QUOTE_NOT_FOUND`, and a client that reads every 4xx as a verdict would ring the bill
    up again. The key replay does not read the quote, so it still answers the original.
  - A replay through the bill `id` re-reads the quote, so `quote.isExpired` is recomputed at
    read time: a replay the next day can differ from the original in that one field. A key
    replay returns the stored body unchanged.
  - An open quote whose bill `id` is already taken is `409 SALE_ID_REUSED`. Otherwise
    `existingSale` would replay an unrelated bill, and the quote would be marked converted into it.
- 🔴 **Divergence from Dart, open for the owner (02 §3.8):** Checkout drops short or
  non-catalogue lines from a loaded quote and lets staff edit the cart. Convert here is
  all-or-nothing. A quote that cannot convert is therefore rung up with `POST /sales`, stays
  `open`, and can later be converted into a second bill.
- **Parked sales: `pos` only, reads included** (ADR-0004). The body is `{ payload: {...} }`, stored
  verbatim as JSONB. The list is tenant-wide, newest first, and not filtered by device.
  Whether a till may see another device's cart is an open question for the owner. **`DELETE` returns the deleted row, so the delete is the
  recall.** When two tills recall the same bill, one `DELETE … RETURNING` finds it and the other
  gets `404 PARKED_SALE_NOT_FOUND`.

## The server cache (#32)

`src/infra/tenant-cache.service.ts` (`TenantCache`, global via `TenantCacheModule`). Cache-aside
on `redis-cache`. Every Redis failure fails open: a read goes to Postgres, and a write is still
answered.

**What is cached** (`02_API_SCREENS.md §4.2/§5`). Every cached response carries `X-Cache: HIT|MISS`.

| Read | Namespace | TTL | Source |
|---|---|---|---|
| `GET /products`, `GET /products/:id` | `products` | 300 s ± 60 s | §5 (a flat 60 s before #32) |
| `GET /categories` | `categories` | 3600 s ± 360 s | §5 TTL, ±10 % |
| `GET /settings` | `settings` | 3600 s ± 360 s | §5 TTL; §5 gives no jitter amount, so ±10 % |
| `GET /customers` (list only) | `customers` | 60 s ± 6 s | §4.2 "1m", ±10 % |
| `GET /mechanics` (list only) | `mechanics` | 60 s ± 6 s | §4.2 "1m", ±10 % |

The TTLs are in one table, `CACHE_TTL`. These are **not** cached: `GET /customers/:id`,
`GET /mechanics/:id`, the `/:id/sales` reads, report summaries, and `/bootstrap`
(see *Not done*).

**Every namespace has its own generation key.**

```
t:{tid}:{ns}:gen                              random token, 1 h ± 5 min
t:{tid}:products:g:{token}:list:[s:…][n:…][c:…][u:…][a:…]{page}:{limit}
t:{tid}:products:g:{token}:item:{id}
t:{tid}:categories:g:{token}:list
t:{tid}:settings:g:{token}:row
t:{tid}:customers:g:{token}:list:[s:…][u:…]{page}:{limit}
t:{tid}:mechanics:g:{token}:list:[s:…][u:…]{page}:{limit}
```

Invalidating a namespace is **one `SET` of a new token**. Nothing is deleted and nothing is
scanned. The old keys become unreachable at once and expire on their own TTL. `KEYS` is gone from
`src/`; the test fixture's `clearTenantCache` still uses it, but that is not production code.

**Why a generation instead of §5's tag set** (`SADD t:{tid}:tags:products <key>`):
- 🔴 `redis-cache` is `allkeys-lru`. If Redis evicts a tag set, the keys it listed stay readable
  and nothing can find them to delete them. If Redis evicts a generation, the next reader creates
  a new random token, and that invalidates everything.
  - The token is random rather than an `INCR` counter for the same reason: a counter restarts
    at 1 after eviction and brings back the keys written under 1.
- 🔴 **The read-populate race.** A reader misses and reads the rows, a writer commits and
  invalidates, and then the reader stores its now-stale rows for a whole TTL.
  - `TenantCache.prefix()` is called **before** the query, so the reader's late write lands under
    the token the writer already replaced.
  - *read-populate race* in `test/cache-invalidation.e2e-spec.ts` proves it: the test fails when
    the prefix is taken after the query.
- No ADR requires tag sets. §5 lists them as one way to avoid `KEYS`. This deviation is recorded in
  §5 for the owner.

**Invalidation runs only after commit.**
- Request-scoped writes call `TenantCache.invalidateAfterCommit(tid, ns)`. It goes through
  `onTransactionCommit`, the same hook the BullMQ enqueues use, so "after the transaction" is
  defined in one place.
- `TenantService.runTx` runs the hooks after `COMMIT` and release, before the handler returns
  (so before the response is sent), so a read right after a `201` is already fresh.
- A rollback (a thrown error, or a 409) drops the hooks. Each call is also placed after every
  refusal check.
- 🔴 `invalidateAfterCommit` **throws with no open transaction** — outside a request, or in a
  request outside `runTx` (tx.4 #153). So does `onTransactionCommit` itself: there is no commit
  to wait for, and running the hook at once would run it before the caller's own commit.
- The platform import runs its own `ADMIN_DATA_SOURCE` transaction. It calls `invalidate()` for all
  five namespaces after `await adminDs.transaction(…)` resolves. Since #239 this runs inside
  `TenantImportProcessor` (a BullMQ worker), not the HTTP request — see *Tenant import (#239)* below.
- A failed invalidation `SET` is logged as `cache invalidation failed`. A failed post-commit hook of
  any kind is logged as `post-commit hook failed`.

**Reads that bypass the cache on purpose.** `SettingsService.get()` stays a plain read, and
`GET /settings` uses `getCached()`.
- `PATCH /settings` reads its audit before-image inside the write transaction.
- `/bootstrap` hashes a fresh body for its `ETag`. It reads customers and mechanics straight from
  Postgres too.

`t:{tid}:status` belongs to `TenantGuard` and `PATCH /platform/tenants/:id/status` (a `DEL`). It is
a separate key, so the two paths cannot interfere.

### Stampede lock (#124)

`TenantCache.singleFlight(key)` implements §5's `SET key NX PX 5000`. `ProductsService.list` calls it
right after a miss:

- The first miss takes `{cache key}:lock`, reads Postgres, `set`s the value, then releases.
- A concurrent miss checks for the value at once, then polls every 5 ms. When the value appears it
  answers it as a `HIT`, and never queries.
- The loader releases in a `finally`, so a list query that throws frees the lock at once instead of
  making every concurrent miss wait out the 1 s cap.
- The release is a compare-and-delete script, so a loader whose lock already expired cannot free the
  next loader's lock.

🔴 **The lock is keyed on the full cache key, generation included.** A waiter can only receive a value
stored under the generation it read before its own miss. A reader that starts after an invalidation
has a new key, so it gets a new lock and never waits on a pre-write loader.

**It never costs a request its answer:**
- A Redis error means no lock, and the request reads Postgres as before.
- A waiter stops waiting after **1 s** and reads Postgres itself. That is far below the 5 s lock,
  because every waiter holds its request's pooled connection while it waits (the request
  transaction opens before routing).
- A loader whose process dies holding the lock leaves it to expire. Its waiters fall back at 1 s.
- **A hung Redis is bounded too (#140).** `enableOfflineQueue: false` fails fast only while ioredis
  knows the connection dropped; a Redis that stops answering on an open socket used to stall every
  command. Both app clients (`createRedisClient` in `infra/redis.module.ts`) now set ioredis
  `commandTimeout` = `REDIS_COMMAND_TIMEOUT_MS` (default **1000 ms**, positive integer, refused
  otherwise). A timed-out command rejects like a dropped connection, so every existing fail-open
  path takes it: `TenantGuard` reads status from Postgres, `TenantCache` answers no prefix / a miss,
  a timed-out lock acquire is the no-op release (it does not wait out the 1 s poll), and a timed-out
  release is swallowed. Worst case per request is one timeout per Redis call on the path — the
  guard's read and write-back cost 2 × the timeout. `src/infra/redis-command-timeout.spec.ts` proves
  it against a TCP server that completes the handshake and then never replies, and shows the same
  server hangs a client built without the option.
- 🔴 **Do not lower the timeout below the API's event-loop lag.** The ioredis timer starts when the
  command is sent, so a blocked loop expires it even when Redis already replied. Measured with a
  local probe (2,000 `GET`s, loop blocked 2 × timeout): at 200 ms, 61 % of commands Redis answered
  were reported as timed out. Under load that sends the whole cache onto Postgres at the moment it
  is busiest — the reason the default is 1 s and not the idempotency cache's 200 ms race.
- 🔴 **Never give BullMQ's connections a `commandTimeout`.** ioredis applies it to blocking commands
  as well, so a worker's `BZPOPMIN` (up to `drainDelay`, 5 s) and QueueEvents' `XREAD BLOCK` (10 s)
  would reject on every idle poll. BullMQ 6 races those against its own watchdog and resets the
  connection instead. `QueueModule` and `bull-board.ts` build their connections from options, not
  from `REDIS_QUEUE` — that client only answers `/health/ready`'s `PING`, so it takes the timeout.
- **Not covered by #140:** the BullMQ enqueues after commit run on BullMQ's own connection, so a hung
  `redis-queue` still stalls them. `PlatformTenantsService` (`getTenantStatus`, the status `DEL`
  after `updateStatus`) never caught a Redis error; on a hung `redis-cache` it now throws the timeout
  instead of hanging, which is the same answer it already gave a dropped connection.

**Why only the list.** Measured as `pos_app` under RLS on a 5,000-product tenant:

| Read | Execution time |
|---|---|
| `TenantGuard` status (`tenants` by PK) | 0.008 ms |
| `GET /products/:id` | 0.026 ms |
| `GET /products` `count(*)` | 1.0 ms |
| `GET /products?search=เบรก` `count(*)` | 6.9 ms, plus the page query |

A lock costs at least two Redis round trips, which is more than the status and `byId` queries it would
save. It also saves no connections anywhere, because every request already holds one before the guard
runs. So the status probe and `byId` stay plain cache-aside. `test/cache-stampede.e2e-spec.ts` proves
the list: six concurrent misses give one `MISS` and five `HIT`s. That e2e slows the cache `set` by
300 ms to open the race; with the measured 1–7 ms query, a waiter still holds its connection a few
milliseconds longer than a plain miss would, so the gain is saved database work, not latency.

### Write path → cache keys

"`products`" in the Keys column means `t:{tid}:products:gen` is replaced. That covers every cached
key of that namespace, for that tenant only. Each row has a case in
`test/cache-invalidation.e2e-spec.ts`: prime to a HIT, write, and the next read must be a MISS
showing the new value.

| Write path | What moves | Keys invalidated | Where |
|---|---|---|---|
| `POST /products` · `PATCH` · `DELETE /products/:id` | product row | `products` | `products.service.ts` |
| `POST /products/:id/adjust-stock` | stock | `products` | `adjustStock` |
| `POST /purchase-orders/:id/receive` | stock + cost (only when a line matched) | `products` | `purchase-orders.service.ts` |
| `POST /sales` (and `POST /quotes/:id/convert`, which sells through it) | stock; customer points/spend; mechanic totals/tab | `products`; `customers` if the bill names a customer; `mechanics` if it names a mechanic | `sales.service.ts` |
| `POST /sales/:id/void` | stock restored; ledger reversed | same rule as the sale | `void.service.ts` |
| `POST /returns` | stock restored; ledger reversed in proportion | same rule, from the original bill | `returns.service.ts` |
| `POST /mechanics/:id/credit-payments` | mechanic tab | `mechanics` | `credit-payments.service.ts` |
| `POST /customers` · `PATCH` · `DELETE /customers/:id` | customer row | `customers` | `customers.service.ts` |
| `POST /mechanics` · `PATCH` · `DELETE /mechanics/:id` | mechanic row | `mechanics` | `mechanics.service.ts` |
| `PATCH /settings` | settings row | `settings` | `settings.service.ts` |
| `POST /categories` · `DELETE /categories/:name` | category list | `categories` | `categories.service.ts` |
| `POST /platform/tenants/:id/import` | all five tables | `products`, `categories`, `customers`, `mechanics`, `settings` (directly, after its own commit) | `tenant-import.service.ts` |

These write paths invalidate nothing, because nothing they change is cached:
- suppliers
- shifts and drawer entries
- quotes: create, update, delete, duplicate, purge
- parked sales
- PO create, cancel and delete
- backup export
- `POST /platform/tenants`: its `settings` row belongs to a brand-new tenant, which has no keys yet.

Negatives, all in the same spec:
- `409 INSUFFICIENT_STOCK` and `409 CREDIT_LIMIT_EXCEEDED` keep the products generation.
- `409 CREDIT_LIMIT_EXCEEDED` on a bill naming a customer and a mechanic keeps both people
  generations, and the mechanic's cached tab is still the old one.
- `409 CREDIT_PAYMENT_EXCEEDS_BALANCE` keeps the mechanics generation.
- A walk-in sale (no customer, no mechanic) leaves the people caches as HITs.
- A probe route writes, registers invalidation for all four namespaces, then throws. Every
  generation is unchanged.
- A sale in tenant A leaves tenant B's generation alone, and B still reads a HIT with its own rows.

### Not done / known limits

- **Report summaries are not cached. Owner question:** §5's `t:{tid}:reports:summary:{from}:{to}`
  row says *"let it expire"* (300 s), but #32's AC3 says *"a read immediately after a write
  returns the new value, for every cached endpoint"*. Those cannot both hold.
  - Caching summaries per AC3 means every sale, void and return invalidates them, which leaves
    little to cache during business hours.
  - Caching them per §5 means a summary up to five minutes stale.
  - The owner decides. Until then they stay live SQL.
- **`GET /bootstrap` gets no Redis cache.** Neither §4.2 nor §5 assigns one to #32; its body-hash
  `ETag` (#25) stays.
- **The stampede lock covers `GET /products` only (#124).** See *Stampede lock* below.
- **Fail-open on invalidation.** If Redis rejects the generation `SET`, a cached value can outlive
  the write by up to its TTL (≤ 360 s for products, ≤ 66 s for people, ≤ 3960 s for settings).
  It is logged.
- A read that populates the cache **inside a write transaction** would cache uncommitted rows under
  the current generation, and a rollback would not replace them. No route does this: only the
  `GET` handlers read through the cache. Keep it that way.
- 🔴 **For #55:** the import writes rows with the snapshot's own `updated_at`, often in the past.
  A device whose `?updatedSince=` cursor is already later never sees them. The cache is
  invalidated, but a cache cannot fix the sync cursor.
- **Fixed by #123 (PR #130):** platform writes used to log `audit_log` **after** their own write
  committed, so an admin deleted while their token was still valid committed the write and then got
  500 on `audit_log_platform_admin_id_fkey`. Now:
  - 🔴 `platform/audit.service.ts` is `log(runner, input)`, with no default connection. `createTenant`,
    `updateStatus` and the import pass the transaction's `manager`, so a failed audit rolls the write
    back. The cache purge and invalidation still run **after** commit. `e2e` proves the rollback for all
    three by pre-seeding `pa:<id>:exists='1'` for an admin id with no row.
  - `listTenants` and login pass `adminDs`; `listTenants` logs a warning on an audit failure instead of
    failing the read.
  - `PlatformAuthGuard` checks `platform_admins` (`id` + `is_active`), cached in `REDIS_CACHE` as
    `pa:<id>:exists` for 60s, falling back to the DB if Redis errors. **Nothing deactivates an admin
    today; a future deactivate path must `DEL pa:<id>:exists`**, or the admin can still write for 60s.
  - `audit_log.ip` stores null for a value containing `%` (an IPv6 zone id passes `net.isIP` but
    Postgres `inet` rejects it, and inside the transaction that rolled back the write).
    The stored IP is the rightmost `X-Forwarded-For` entry since #132 (`common/client-ip.ts`).

## Login brute-force limits (#134, #138)

`POST /auth/token` has two fixed 60-second buckets in `REDIS_CACHE`, both through
`RateLimitService.consumeAttempt`:

| Bucket | Key | Limit | Taken |
|---|---|---|---|
| IP | `auth:ip:<clientIp>` | 10 attempts | before `qr.connect()`, so a locked-out IP costs no pool connection |
| Username | `auth:user:<device tenant or ->:<username>` | 5 attempts | after the device-token lookup |

- 🔴 **An attempt is counted before its outcome is known, in one `INCR`.** The old
  `getFailureStatus` then `recordFailure` pair was check-then-increment: 15 concurrent bad logins all
  read the same count and all answered 401 (measured on `main` by `security.e2e-spec.ts`, now 10×401
  and 5×429). So every refusal counts — invalid or retired device token (IP bucket only), unknown or
  ambiguous username, inactive user, suspended tenant, wrong password. Responses are unchanged.
- 🔴 **A success never clears the IP bucket.** It gives back only its own attempt
  (`refundAttempt`, which never creates a key). Clearing it let one valid account reset the bucket
  every 9 failures and spray usernames. A success still clears that username's bucket.
- **Keys are hashed** (`rl:<sha256>:<window>`). Replacing non-ASCII characters with `_` made two
  equal-length Thai usernames, and `a.b` / `a_b`, share one bucket. This applies to every
  `RateLimitService` key-based bucket, the void manager-PIN one included.
- The client address comes from `clientIp(req)`, the same helper the audit services use; nginx must be
  the only proxy in front of the API (07 §9).
- Redis errors fail open, like the rest of `RateLimitService`.
- **Not changed:** the void manager-PIN path (`sales/void.service.ts`) still uses check-then-increment,
  and `User is inactive` / `TENANT_SUSPENDED` are answered before the password is checked, which tells a
  caller that a username exists. Both are follow-ups, not part of #138.

## Conventions these slices set

- **Pagination lives in `meta`, not in `data`** (§1.2). A handler returns
  `new Paginated(items, { total, page, limit })` and `EnvelopeInterceptor` lifts it into
  `{ status, data, meta: { total, page, limit, totalPages } }`. `GET /sales` and
  `GET /shifts/history` are the first two; #55 will read them.
- **Money is integer satang in the server** (`src/common/money.ts`) and a string on the
  wire. `toSatang` holds a JSON number to the same two decimals as the string form and
  bounds every amount to what `NUMERIC(12,2)` can hold — past that Postgres raises `22003`
  several statements later, which surfaces as a 500 for what was plainly a bad request.
- **A list read needs a tiebreaker.** `sales.date` defaults to the transaction timestamp,
  so bills written in the same instant tie; `LIMIT`/`OFFSET` over a tie shows one row
  twice and misses another. Every paged query orders by `<sort key> DESC, id DESC`.
- 🔴 **`returning()` (`src/common/sql.ts`) is not optional.** TypeORM's Postgres driver
  returns rows directly for `SELECT`/`INSERT` but `[rows, affected]` for `UPDATE`/`DELETE`,
  so `result[0].stock` reads a number on one and `undefined` on the other — which reaches
  Postgres as a NULL several statements later, where nothing points back at the cause.

## The e2e suite

`test/support/fixture.ts` boots the real application against the compose Postgres and
Redis, mints access tokens from a per-run RSA key pair, and resets one tenant per suite.

- **`resetTenant` clears Redis as well as Postgres.** `TenantGuard` caches
  `t:{tid}:status` for five minutes and the idempotency service caches responses under
  `t:{tid}:idem:*` for a day — both outlive a run. A suite that wipes only the tables is
  testing a half-reset tenant: a suspended shop still reads `active`, and a re-used key
  replays a bill that no longer exists.
- **`fileParallelism: false`.** Each file boots the whole application, so parallel files
  multiply the connection pools past `max_connections=100` and the run dies as "worker
  exited unexpectedly" rather than as a failed assertion.
- **One run per Postgres (#141).** Every file shares the `pos` database and both Redis, and
  `test/schema.e2e-spec.ts` drops `pos_schema_test` `WITH (FORCE)` — so a second concurrent
  `pnpm test:e2e` against the same stack does not fail cleanly, it corrupts the first (a
  migration dying with `terminating connection due to administrator command`, document
  numbers starting mid-series). Vitest's `globalSetup` (`test/support/e2e-runner-lock.ts`)
  therefore takes a session-level `pg_try_advisory_lock` on a dedicated connection before any
  file starts, and a second run refuses at once with
  `e2e runner lock: another \`pnpm test:e2e\` is already running against this Postgres; held by "e2e-lock pid=… host=…"`.
  The lock lives in the maintenance database of `DATABASE_ADMIN_URL` (`postgres` by default),
  never in a database a suite drops, and Postgres releases it when the connection closes — a
  crashed or Ctrl+C'd run leaves nothing stale. It is refuse-not-wait: a waiting run would just
  hide the collision. If the lock connection dies mid-run, the run is failed at teardown.
  CI has one Postgres per job and always gets the lock. Per-run databases were not chosen:
  the Redis ports, the `pos_app` URL in `fixture.ts` and the migrate step are all fixed, so
  isolation would mean a database *and* two Redis per run.
- **On Windows, run the suite on Node 24.16.0 or later (#160).** On Node 24.15.0, about half of
  the full runs lost one file to Vitest's `Worker exited unexpectedly`: exit code `0xC0000409`,
  nothing on stderr, and a different file each time (`security`, `cache-stampede`, `sales`,
  `returns`, `people`). This is a bug in Node's bundled libuv, not in our code:
  `uv__is_fast_loopback_fail_supported()` in `deps/uv/src/win/tcp.c` passes a stack
  `OSVERSIONINFOW` to `RtlGetVersion` without setting `dwOSVersionInfoSize`. When the leftover
  stack value there happens to be `0x11C` (`sizeof(OSVERSIONINFOEXW)`), Windows writes the
  8-byte EX tail past the 276-byte buffer and over the /GS stack cookie. The worker then
  fast-fails on its next loopback `connect()`, and every pg, Redis and supertest socket in this
  suite is a loopback connect.
  - **Evidence.** Three `procdump -e` dumps, symbolised with the v24.15.0 `node.pdb`, all show
    the same crash: `__report_gsfailure` (subcode 2, `FAST_FAIL_STACK_COOKIE_CHECK_FAILURE`),
    reached from `uv__tcp_try_connect` → `uv_tcp_connect` → `TCPWrap::Connect<sockaddr_in>`.
    In each dump the cookie slot holds `0x0001010000000000`, which is exactly SP 0.0,
    `wSuiteMask=0x0100` and `wProductType=1`, and the size field reads `0x11C`.
  - **The fix is upstream.** libuv `aabb765` (libuv#5107, "win: properly initialize
    OSVERSIONINFOW") shipped in Node 24.16.0 and 26.1.0. The 22.x and 25.x lines did not have it
    on 2026-09-14.
  - **Before and after.** On Node 24.15.0, 5 of 9 full runs crashed. On Node 24.21.0, 0 of 8
    crashed, on the same machine, stack and commit. The only other failures in those runs were
    #162's two known ones.
  - **What was ruled out.** argon2 hash/verify in 120 forked processes never crashed.
    `security.e2e-spec.ts` alone, 8 runs, never crashed. No third-party Winsock provider is
    loaded in the process.
  - **CI is not affected.** It runs Linux, which never compiles `src/win/`.
  - The e2e `globalSetup` (`test/support/windows-node-check.ts`) prints a warning when it sees
    an affected Node on Windows. It only warns: a dropped file still makes the run exit non-zero.
  - Earlier notes (`fileParallelism` above, the `DB_POOL_SIZE` comment in `fixture.ts`) blamed
    "worker exited unexpectedly" on connection-pool pressure. Nobody captured a dump for those
    runs, so they may have been this bug.
- `TEST_LOG_LEVEL=error pnpm test:e2e` is how you find out why a suite is getting a 500.

## Invariants this stack enforces (from #14 / #2)

- `redis-cache` = `allkeys-lru`, no persistence. `redis-queue` = `noeviction` + AOF. Two processes.
- Both Redis run with `--requirepass`; an unauthenticated client cannot read a cache entry or
  `FLUSHALL` the queue even from inside the compose network. `etcd` runs with RBAC auth on
  (`ETCD_ROOT_PASSWORD`); an unauthenticated client is refused (#64).
- Postgres, both Redis and `etcd` publish **no** host port; only `docker-compose.dev.yml`
  (dev/CI) does.
- Bull-Board requires basic auth and is bound to host loopback only (Nginx does not proxy it —
  on the VM reach it over an SSH tunnel); `/platform/*` is refused by Nginx from any non-private
  source address.
- `/health/live` does no I/O. `/health/ready` returns `503 NOT_READY` naming the failed
  dependency — Postgres and both Redis only. `etcd` is deliberately **not** part of that check:
  the whole point of `RuntimeConfigService`'s fail-open design (#66) is that an unreachable
  store degrades logging, not availability, and health/readiness must not say otherwise.
  Nginx fails over only on connection errors, never on the app's own 5xx.
- 🔴 **Readiness means "Postgres answers", not "the request pool has a free slot" (#248).**
  The probe's `SELECT 1` runs on `HEALTH_DATA_SOURCE` — `pos_app`, a pool of **one**,
  `connectionTimeoutMillis` 2000 and `statement_timeout` 2 s, matching the probe's own 2 s.
  On the request pool, a burst holding every `DB_POOL_SIZE` slot queued the probe past that
  timeout and a healthy, busy Postgres answered `503 {postgres: down}` — to Prometheus during
  the 500-VU demo run, and potentially to `deploy.yml`'s readiness gate after a rolling
  restart under traffic, rolling back a good release. A longer timeout only delays the same
  false positive; reporting saturation as `busy` would still share the pool. A saturated
  instance is visible in latency, not here. `test/health-pool.e2e-spec.ts` holds every
  request-pool connection at pool 2 (before: `503` at 2031 ms; after: `200`) and still gets
  `503` when the probe cannot connect or its query fails. Never point the probe at
  `ADMIN_DATA_SOURCE` (it would pass while `pos_app` cannot log in) or back at the request pool.
- `SIGTERM` drains: Nest closes the listener, in-flight requests finish, then pools close.
  Nginx retries idempotent requests on the next instance (`proxy_next_upstream error timeout`).
- Every request carries `X-Correlation-ID` (client's, else Nginx `$request_id`) into the JSON
  log line and back out in the response. Request bodies are never logged.
- `mem_limit` per container totals ≈ 3.3 GB (includes `etcd`'s 256m); `max_connections=100`,
  steady-state pools 3 api × (15 request + 2 audit + 1 health) + worker (5 + 2 + 1) = 62 ≤ 80
  (80%). `ADMIN_DATA_SOURCE` (sized `DB_POOL_SIZE`, owner role) is outside that figure: it is
  touched only by the platform plane and at boot, and its idle connections close after 30 s —
  a burst of platform calls on all three instances at once is the one way past 80.
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

## Monitoring overlay (#63 `ops.1`)

Node Exporter + Prometheus + Grafana as a separate compose overlay, so it can sit next to the
stack above without touching it:

```
cd server
docker compose -f docker-compose.yml -f ../deploy/compose/monitoring.yml up -d
```

(On the VM, `vm.override.yml` goes in between.) **`GRAFANA_ADMIN_PASSWORD` is required** in
`.env`, the same way `POS_APP_PASSWORD`/`REDIS_PASSWORD`/`BULL_BOARD_PASSWORD` already are —
the stack fails fast if it's unset.

**Wired into the deploy playbook by #121.** The POS steps of `deploy/ansible/deploy.yml` never load
`monitoring.yml`. Only **after** `/health/ready` passes and `.current_sha` is recorded does it copy
`monitoring.yml` to `/opt/pos/` and the `deploy/prometheus/` and `deploy/grafana/` trees to
`/opt/pos/deploy/` (pruning files the repo no longer has, compared as paths relative to each tree —
never `realpath` on one side, which deleted every file when run through a symlinked path), pull the
monitoring images and bring the three services up, all inside one `block`/`rescue`. A changed
config recreates Prometheus and Grafana — a single-file bind mount keeps the old inode after the
copy, and the compose config hash does not change. If `127.0.0.1:9090/-/healthy` or
`127.0.0.1:3000/api/health` does not answer 200, the deploy **warns and still succeeds**: monitoring
is not a gate for the POS. `-e enable_monitoring=false` (or `ENABLE_MONITORING=false`) leaves the
overlay out and removes containers an earlier deploy left running; toggling it on a VM already
running that SHA waits for the next release, because the duplicate-release check ends the play.
While it is on, the VM's `.env` must carry `GRAFANA_ADMIN_PASSWORD` — add it to the
`DEMO_ENV_FILE` secret and re-run `provision.yml` first — or monitoring stays down with a warning
(the POS release still goes out). Re-running the same `image_tag` stops at the duplicate-release
check, so a fixed monitoring problem is picked up by the next release, or by deleting
`/opt/pos/.current_sha` and re-running the tag (which repeats the whole rollout).

🔴 **The bind mounts are `${MONITORING_CONFIG_DIR:-../deploy}/…`.** Relative paths resolve
against the project directory — `server/` from the repo, but the flat `/opt/pos/` on the VM,
where `../deploy/…` is `/opt/deploy/…` and Docker silently creates an empty directory for the
missing source. The playbook sets `MONITORING_CONFIG_DIR=./deploy`; running compose **by hand on
the VM** needs the same variable.

**Nothing new is reachable from outside the host.** `node-exporter` publishes no port at all
(Prometheus reaches it on the compose network); `prometheus` (`127.0.0.1:9090`) and `grafana`
(`127.0.0.1:3000`) are loopback-only, same pattern as Bull-Board:

```
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 deploy@<vm>
```

Grafana's datasource and its one dashboard (`deploy/grafana/dashboards/pos-overview.json`) are
provisioned from files under `deploy/grafana/provisioning/` — nothing to click, and a rebuilt
Grafana volume comes back identical. The dashboard has the VM's CPU/memory/disk (live from
node-exporter) plus two SLI panels — success rate and p95 — that read "no data" until #34/#35
add a real `/metrics` endpoint; `deploy/prometheus/prometheus.yml` has that scrape job
commented out, ready to enable.

🔴 **Prometheus's `up` reflects whether the response body parses as its text format, not just
the HTTP status.** `/health/ready` answers 200 with a JSON body, which fails that parse, so the
interim `api-readiness` job (scraping `/health/ready` directly on `api-1..3:3000`) shows all
three instances as DOWN in the Prometheus UI even while the API is actually up — confirmed
against a real `prom/prometheus` container while building this overlay. This is a known,
accepted gap (adding `blackbox_exporter` to work around it would be scope beyond what #63
asks for) that closes itself once the commented `api-metrics` job above is turned on.

Every relative path in `monitoring.yml` is written against `server/`, not against
`deploy/compose/` where the file itself lives — Compose resolves bind-mount paths against the
*project directory*, which defaults to the directory of the **first** `-f` file. Always list
`docker-compose.yml` first.
