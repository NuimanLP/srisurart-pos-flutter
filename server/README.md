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
src/infra/               DataSource (pos_app role, synchronize=false), ADMIN_DATA_SOURCE (owner),
                         AUDIT_DATA_SOURCE (pos_app, pool of 2, off the request pool),
                         REDIS_CACHE / REDIS_QUEUE
src/idempotency/         Idempotency-Key: claim, replay, 409 on a changed request (#18)
src/documents/           document numbers: RC01-2569-08-0042, per device per month (#19)
src/sales/               POST /sales — the sale transaction (#20)
src/shifts/              the cash drawer: shifts, entries, the shift_id stamp (#28)
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

This shape is scheduled for replacement: the 2026-09-10 addendum to ADR-0003
(*"ใครตัดสิน กับ ใครลงมือ"*) moves the transaction inside the handler, and
`docs/Backend_design/adr/0003-handler-scoped-migration-plan.md` sequences that as
`tx.0`–`tx.5` — the split above is what runs until `tx.4` lands.

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

Nothing in `src/` populates it yet, and `currentRequestContext()` throws rather than
defaulting — a route without the guard fails closed instead of reading someone's data.
Built in #19's branch, because every write slice needs it: `RequestContextMiddleware`
opens the transaction per controller listed in `TENANT_ROUTES` (not globally — a
transaction per liveness probe is a pool slot spent on nothing), `TenantGuard` names the
tenant on it *after* the status check, and the globally-bound `TransactionInterceptor`
commits or rolls back before the response is sent. `currentRequestContext()` fails closed
twice: outside the scope, and inside it before the guard has named a tenant.

A guard that throws never reaches an interceptor, so the response's own `close` event is
the backstop that rolls back and returns the connection to the pool. `TransactionInterceptor`
claims the transaction (`qr.data`) as soon as it runs, and the backstop then stands aside:
Nest does not cancel a handler when the client disconnects, so on a mid-sale abort an
unclaimed backstop would roll back and release **underneath statements still in flight**,
handing a live query queue to whichever request took that connection next.

🔴 **Two rules for anything that runs inside a request:**

1. **Never take a second connection from the request pool — there is no exception.** The
   request already holds one. Under load every in-flight request holding one and waiting
   for another is a pool deadlock — they all sit there until `connectionTimeoutMillis`
   fires and all return 500, and the 500s are *other people's requests*, not the one that
   misbehaved. Read through `currentRequestContext().manager`. (`tenants` and
   `platform_admins` are the two tables with no RLS, so even a status probe can go
   through it.)

   Work that genuinely cannot run in the request transaction — today that is exactly one
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
2. **An async Express middleware must never reject.** Express does not await it, so a
   rejection is an unhandled rejection, which Node answers by killing the worker. Both
   `RequestContextMiddleware` failure paths write a response instead.

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
stock **and** issues a number — `POST /purchase-orders/:id/receive` (#26), `POST /returns`
(#22) — must take them in that same order, and so must `POST /sales/:id/void` once #23
reverses the mechanic's tab: mechanic first, then products. Issuing the number first inverts the order and
the two deadlock under concurrent load, which is the kind of failure that only shows up on
a busy Saturday.

## The sale transaction (#20)

`POST /api/v1/sales` — `pos` device only, `Idempotency-Key` mandatory. Everything runs
inside the request transaction, in this order, and the order is the design:

1. the idempotency claim (interceptor, before the handler)
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

**The 201 carries the ledger back** — `customerAfter { id, points, totalSpend }` and
`mechanicCreditBalanceAfter`, null when the bill names none (§3.1, ADR-0010 §3) — so the
client patches its cache without waiting for the next `/bootstrap`. A replayed bill
answers the rows as they stand now and moves nothing. `shift_id` is stamped by #28. The
response carries no `offlineOk` — it has no storage in phase 1. Reversing the ledger on a
void is #23's.

🔴 **`returning()` (`src/common/sql.ts`) is not optional.** TypeORM's Postgres driver
returns rows directly for `SELECT`/`INSERT` but `[rows, affected]` for `UPDATE`/`DELETE`,
so `result[0].stock` reads a number on one and `undefined` on the other — which reaches
Postgres as a NULL several statements later, where nothing points back at the cause.
Every `UPDATE … RETURNING` goes through it.

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
idempotent. Restores stock, writes a `movements` row per product (`ยกเลิกบิล`), marks
the bill void and writes an `audit_log` row. Refused when the bill is already void
(`409 SALE_VOIDED`) or already has a credit note against it (`409 SALE_HAS_RETURNS` —
voiding then would restore that stock twice).

Refusals are audited too (`sale.void.denied`, with the reason). This is a four-digit PIN
with no per-user rate limit until #44; brute-forcing it must not be invisible. That row is
written on its own connection because the 403 rolls the request transaction back — an
audit row written on it would vanish along with the attempt it was recording. The
connection comes from `AUDIT_DATA_SOURCE`, a two-connection pool of its own; taking it
from the request pool made a denial a request queuing for a second connection, which
timed out unrelated requests (see *Two rules* above, and
`test/void-denial-pool.e2e-spec.ts`).

🔴 **Two things to know before this ships:**
- The old app has no void button at all: a bill is voided only as the automatic
  consequence of returning every line (`02_API_SCREENS.md §2` lists the endpoint under
  "new, not a port", and asks for a conversation first). #23 specifies it, so it is
  built — but the shop has never seen this button.
- **The customer and mechanic ledger is deliberately untouched by the void.** #20 does
  not apply those effects yet (they are #21, blocked on the #11 decision), so there is
  nothing on a bill this server wrote to reverse, and reversing anyway would drive
  points and credit balances negative. #21 must extend `VoidService.restoreStock`.

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
  drawer — never from the request body, and null when no drawer is open (the old app
  lets staff sell without one). The closing report is computed by `shift_id`, never by
  a timestamp window: a window breaks across midnight and cannot separate two machines.
- `closeForRetirement()` is the operation `POST /devices/:id/retire` (#6) calls to
  close a machine's drawer in the same transaction that stamps `retired_at`. The
  endpoint does not exist yet, so `test/shifts.e2e-spec.ts` mounts the call on a probe
  route rather than shipping it untested. **It archives as well as closes**: normally the
  device's *next* open archives its drawer, but a retired device never opens again, so an
  active row would be stranded — `history()` (`NOT is_active`) would hide that day's
  takings forever while `current()` showed a drawer nothing could close.
- 🔴 **A bill rung up while no drawer is open carries no `shift_id`,** and neither does
  one rung up after the drawer is closed. The shipped app's closing report counts by date
  key (`closing_report.dart`), not by shift, so it *does* include those bills — a report
  built purely on `shift_id` will be short by exactly the after-close takings. Whoever
  builds `GET /reports/closing` (#30) has to decide that explicitly: either fold
  `shift_id IS NULL AND date = <the shift's day>` into the query, or stamp the day's
  drawer regardless of close. It is a `db.js` behaviour change either way, so it is not a
  decision to make inside a test.

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
- `TEST_LOG_LEVEL=error pnpm test:e2e` is how you find out why a suite is getting a 500.

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
