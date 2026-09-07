# Handoff: #14 `p1` — `server/` compose stack, Nginx, health probes

**Date:** 2026-09-06
**Project path:** `D:\Beestation\Sri_POS\Flutter`
**Repo:** `github.com/NuimanLP/srisurart-pos-flutter`, branch **`feat/p1-compose-stack`** (off `main` at `32acf4d`)
**Previous handoff:** [`to-tickets-backend.md`](to-tickets-backend.md)

## What this session was

The first implementation session. `/scrutinize` + `/karpathy-guidelines` were loaded first, the
handoff and issues #2 / #3 / #14 were read, and then **#14 `p1`** — the head of the critical path
`#14 → #15 → #6` — was built and verified end-to-end. Nothing from #15 onward was touched.

## What exists now

`server/` at the repo root (ADR-0011). `cd server && docker compose up -d --build` from a clean
clone yields, in one command:

| Service | Image / entrypoint | Notes |
|---|---|---|
| `nginx` | `nginx:1.29-alpine` | TLS (self-signed via `certgen` init container), `least_conn`, per-IP `limit_req`, `/platform/` private-range allowlist, correlation id |
| `api-1..3` | `srisurart-pos/server:local` → `node dist/main.js` | static IPs `172.30.0.11–13`, `mem_limit 384m`, `DB_POOL_SIZE=15` |
| `worker` | same image → `node dist/worker.js` | Nest application context, no queues yet |
| `bull-board` | same image → `node dist/bull-board.js` | basic auth, published on `127.0.0.1:3100` only |
| `postgres` | `postgres:16-alpine` | `max_connections=100`; init script creates `pos_app` (`NOSUPERUSER NOBYPASSRLS`) |
| `redis-cache` | `redis:7-alpine` | `allkeys-lru`, no persistence |
| `redis-queue` | `redis:7-alpine` | `noeviction`, AOF `everysec`, volume |

App code (NestJS 12, ESM, pnpm via corepack, Node 22): `src/health/` (live/ready), `src/common/`
(envelope interceptor, error filter, pino logger + correlation id), `src/infra/` (TypeORM
`DataSource` with `synchronize: false`, `REDIS_CACHE` / `REDIS_QUEUE` ioredis clients),
`src/app.module.ts` (`CoreModule` / `AppModule` / `WorkerModule`), `src/app.setup.ts` (everything
`main.ts` and the e2e test configure identically). `server/README.md` has the run/check commands
and the invariant list.

## Verified against the running stack (not speculative)

| Criterion (#14) | Result |
|---|---|
| one command → 9 containers healthy | ✅ from `docker compose down -v` |
| `/health/live` 200 through Nginx (https) | ✅, http → 301 https |
| `/health/ready` 503 when Postgres, `redis-cache` or `redis-queue` stopped; `/health/live` stays 200; no restarts | ✅ |
| two Redis processes with the stated policies (`CONFIG GET`) | ✅ |
| Bull-Board 401 without / with wrong creds, 200 with | ✅ |
| SIGTERM drain: 400 sequential GETs while `docker compose stop api-2` | ✅ 400×200, exit code 0, worst latency 2.0 s (connect timeout to the dead IP, then failover) |
| worker + bull-board exit 0 on `docker compose stop` | ✅ |
| `X-Correlation-ID` from the client in Nginx **and** app JSON log lines, echoed in the response | ✅ (Nginx mints `$request_id` when absent) |
| `/platform/tenants` from a non-private source (container on `100.64.9.0/24`) | ✅ 403; same source `/health/live` 200 |
| per-IP rate limit (300 requests, 100 concurrent) | ✅ 226 × 429; `/health/*` exempt (300 × 200) |
| `mem_limit` on every container | ✅ ≈ 3.0 GB total |
| `pnpm typecheck && pnpm lint && pnpm test && pnpm test:e2e` | ✅ 3 unit + 4 e2e (real Postgres/Redis, no mocks) |

## Two bugs found by the review pass — read before touching `nginx.conf`

1. **`proxy_next_upstream` must not include `http_502 http_503`.** The app answers 503 from
   `/health/ready` on purpose during an outage. Counting that as an upstream failure would eject
   all three instances for `fail_timeout` at once, turning a Redis blip into a full 502 outage.
   Failover is now `error timeout` only (connection-level).
2. **Nginx `resolve` on the upstream servers produced a 502 during drain** ("api-2 could not be
   resolved" → "no live upstreams" even though two instances were healthy). Replaced with
   **static IPs** on a fixed compose subnet (`172.30.0.0/24`). A recreated container keeps its
   address; Nginx never needs DNS or a reload.

## Judgment calls beyond the ticket text

| Call | Why |
|---|---|
| `pos_app` role created at Postgres init | Testing #15's RLS as a superuser would pass silently. Migrations run as `postgres` and must `GRANT` to `pos_app` (**#15's job**). |
| Response envelope + JSON 404 fallback shipped now | Health responses must have *some* JSON shape; using the contract's envelope avoids rework. Nest 12 mounts its 404 handler only under the global prefix, hence the Express-level fallback in `app.setup.ts`. |
| Three named api services, not `replicas: 3` | Stable names/IPs for Nginx, and `docker compose stop api-2` is how the drain criterion is tested. |
| `build:` on `api-1` only | Four parallel builds of one image tag raced (`already exists`). |
| No Terminus, no `nestjs-pino`, no `@nestjs/config`, no BullMQ dependency | Karpathy rule: nothing speculative. Hand-written probes are ~50 lines; Bull-Board runs with an empty queue list until #34. |
| Node `keepAliveTimeout` 65 s > Nginx upstream keepalive 60 s | The classic sporadic-502 cause. |
| Postgres/Redis ports published on `127.0.0.1` only | Needed for local `start:dev` and `test:e2e`; never on the public interface. |

## Environment notes

- Docker Desktop was not running at session start; it was launched from the session.
- Toolchain: Node 24 locally, pnpm 10.34 via corepack, Docker 29 / Compose v5. The image uses
  `node:22-alpine`. `nest new` now defaults to Nest 12 + ESM + vitest + oxlint; the scaffold's
  config files were copied verbatim.
- The Bash tool on this Windows machine failed to parse long multi-file heredoc scripts; files
  were written with the Write tool instead. Not a repo issue.
- Dev secrets are the `${VAR:-dev-only-…}` defaults in `docker-compose.yml`; `server/.env`
  overrides them (auto-loaded by compose). Set real ones on the faculty VM.
- The stack was left running. `cd server && docker compose down` stops it (`-v` wipes data).

## State

Committed on `feat/p1-compose-stack` (see the commit for the file list). **Not pushed, no PR
yet.** Flutter gate untouched (`flutter.yml` ignores `server/**`).

Docs updated in the same commit: `CLAUDE.md` (server status), `README.md` (`server/` row +
paragraph), `HANDOFF.md` (TL;DR + entry), `03_ARCHITECTURE.md §8` (DoD 1/5/7 ticked),
`adr/README.md` (new "ลงมือแล้ว" section), `.gitignore` (`/server/*.tsbuildinfo`).

## Next

1. Push and open the PR for #14; merge closes it.
2. **#15 `p2`** (team/2) — schema, migrations, RLS, seed. It must: run migrations as `postgres` in a
   separate compose job before the api starts; `GRANT` to `pos_app`; keep `synchronize: false`
   everywhere (already the DataSource default here); add the `migrate` service to
   `docker-compose.yml` with `depends_on: postgres healthy` and make `api-*` depend on it
   `service_completed_successfully`.
3. **#38 `ci.1`** can start now — the gate is `corepack pnpm typecheck && lint && test && test:e2e`
   with Postgres/Redis service containers and `POS_APP_PASSWORD` matching the init script.
4. Still open from before: #11 / #12 / #13 need a human; frontend tickets are not cut yet.

## Suggested skills for the next session

- `karpathy-guidelines` — before writing any code (surgical, no speculation).
- `scrutinize` — on the #15 migration set before commit; the RLS fail-closed policy and the
  `pos_app` grants are exactly the kind of thing that passes tests while being wrong.
- `source-driven-development` if available — TypeORM is at 1.x now and its migration API should
  be checked against the docs, not memory.
- `ci-cd-pipeline` for #38.
