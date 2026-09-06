# Srisurart POS — server (phase 1)

NestJS multi-tenant backend. Design lives in `../docs/Backend_design/` (ADRs win over
prose); work items live in GitHub issues (#2 is the brief). This directory was created by
**#14 `p1`** — compose stack, Nginx, health probes. No business endpoints yet.

## Run

```
cd server
docker compose up -d --build
curl -k https://localhost/health/live     # → {"status":"success","data":{"status":"up"}}
curl -k https://localhost/health/ready    # checks Postgres + both Redis
```

That is the whole stack: Nginx (TLS, self-signed) → `api-1..3` → PostgreSQL, `redis-cache`,
`redis-queue`, plus the BullMQ `worker` and `bull-board` (http://127.0.0.1:3100, basic auth).
Dev secrets are the defaults in `docker-compose.yml`; override them in `server/.env`
(see `.env.example`) on any shared machine.

Local development without Docker for the app itself:

```
corepack pnpm install
docker compose up -d postgres redis-cache redis-queue
DATABASE_URL=postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos \
REDIS_CACHE_URL=redis://127.0.0.1:6379 REDIS_QUEUE_URL=redis://127.0.0.1:6380 \
corepack pnpm start:dev
```

## Checks

```
corepack pnpm typecheck && corepack pnpm lint && corepack pnpm test   # pure unit tests
corepack pnpm test:e2e      # boots the app against the compose Postgres/Redis — no mocks
```

## Layout

```
src/main.ts              api entrypoint (HTTP)          → node dist/main.js
src/worker.ts            BullMQ worker (no HTTP)        → node dist/worker.js
src/bull-board.ts        Bull-Board behind basic auth   → node dist/bull-board.js
src/app.module.ts        CoreModule (config, logger, Postgres, Redis) / AppModule / WorkerModule
src/app.setup.ts         global prefix /api/v1 (health excluded), envelope, filter, JSON 404
src/common/              response envelope, error envelope, pino logger + correlation id
src/infra/               DataSource (pos_app role, synchronize=false), REDIS_CACHE / REDIS_QUEUE
src/health/              /health/live (touches nothing) · /health/ready (Postgres + both Redis)
docker/nginx/nginx.conf  least_conn, TLS, per-IP limit_req, timeouts, /platform/ allowlist
docker/postgres/init/    creates the non-superuser pos_app role on first boot
```

## Invariants this stack enforces (from #14 / #2)

- `redis-cache` = `allkeys-lru`, no persistence. `redis-queue` = `noeviction` + AOF. Two processes.
- Bull-Board requires basic auth and is bound to host loopback only; `/platform/*` is refused
  by Nginx from any non-private source address.
- `/health/live` does no I/O. `/health/ready` returns `503 NOT_READY` naming the failed
  dependency. Nginx fails over only on connection errors, never on the app's own 5xx.
- `SIGTERM` drains: Nest closes the listener, in-flight requests finish, then pools close.
  Nginx retries idempotent requests on the next instance (`proxy_next_upstream error timeout`).
- Every request carries `X-Correlation-ID` (client's, else Nginx `$request_id`) into the JSON
  log line and back out in the response. Request bodies are never logged.
- `mem_limit` per container totals ≈ 3.0 GB; `max_connections=100`, pools 3×15 + 5 = 50.
- The app connects as `pos_app` (`NOSUPERUSER NOBYPASSRLS`, not the table owner) so RLS from
  #15 cannot be bypassed by accident. Migrations (#15) run as `postgres`.

## Deploying a new image without a full outage

`docker compose up -d --build` recreates all three instances at once. For a rolling restart:

```
docker compose build api-1
for s in api-1 api-2 api-3; do docker compose up -d --no-deps $s; sleep 5; done
```

Each instance keeps its static address (`172.30.0.11–13`), so Nginx needs no reload.
