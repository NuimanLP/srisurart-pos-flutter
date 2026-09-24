# Srisurart Autopart POS

[![Flutter CI](https://github.com/NuimanLP/srisurart-pos-flutter/actions/workflows/flutter.yml/badge.svg)](https://github.com/NuimanLP/srisurart-pos-flutter/actions/workflows/flutter.yml)
[![Server CI](https://github.com/NuimanLP/srisurart-pos-flutter/actions/workflows/server.yml/badge.svg)](https://github.com/NuimanLP/srisurart-pos-flutter/actions/workflows/server.yml)

A point-of-sale system for a Thai auto-parts shop (ร้านศรีสุราษฎร์อะไหล่ยนต์), built as a
Flutter client over a multi-tenant NestJS backend. The UI is Thai-first because the people
using it are; the code, the docs and this README are English.

The shop is real and the product is in daily use. The original build was a single-file
React + `localStorage` page; it was rewritten as an offline-first Flutter app (SQLite on the
counter PC), and is now being extended into a multi-tenant platform so more than one shop can
run on it. **The shop still runs the offline build — nothing has been cut over yet.**

---

## Table of contents

- [Overview](#overview)
- [Screenshots](#screenshots)
- [Features](#features)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Installation](#installation)
- [Environment](#environment)
- [Deployment](#deployment)
- [Testing and CI/CD](#testing-and-cicd)
- [Scalability, limits and known bottlenecks](#scalability-limits-and-known-bottlenecks)
- [Roadmap](#roadmap)
- [Documentation](#documentation)

---

## Overview

| | |
|---|---|
| **Client** | Flutter 3.44.3 / Dart SDK `^3.12.2` — Android, iOS, Web |
| **Local store** | Drift (SQLite) — 25 tables, the same schema the shop runs offline |
| **State / routing** | `flutter_bloc` 9.x, `go_router` 17.x |
| **Backend** | NestJS, PostgreSQL 16, Redis 7 (×2), BullMQ, Nginx 1.29, etcd 3.6 |
| **Tenancy** | One database, many tenants, PostgreSQL Row-Level Security forced on every tenant-scoped table |
| **Deployment** | Docker Compose on a single university VM, rolled out by Ansible from GitHub Actions |
| **Tests** | 64 Flutter test files · 49 server unit specs · 53 server end-to-end specs |

The system runs in **two modes from one codebase**, selected at build time:

- **Offline build** (`USE_API_WRITES=false`, the default) — SQLite on the machine is the source
  of truth. No login, no network. This is what the shop uses; if the internet dies, the shop
  keeps selling. Frozen for reference on the `POC_sample_offline_first` branch.
- **API build** (`USE_API_WRITES=true`) — PostgreSQL is the source of truth, Drift drops to a
  read cache, and every money- or stock-moving write goes to the server inside a single
  database transaction. This is what `main` builds.

### Why the split matters

An auto-parts counter cannot show a spinner while a customer waits, and the shop's internet is
not reliable. Every architectural decision in this repo falls out of that: the transactional
rules (stock validation, returns, weighted-average cost) were written once for SQLite and
**ported**, not reinvented, on the server, so both modes behave identically down to the Thai
error strings. The decision record for this is in [`docs/Backend_design/adr/`](docs/Backend_design/adr/),
which is binding — **where a document contradicts an ADR, the ADR wins.**

---

## Screenshots

| Checkout (ขายสินค้า) | Products and stock (สินค้า/สต็อก) |
|---|---|
| ![Checkout](docs/tutorial/flutter/img/checkout.png) | ![Products](docs/tutorial/flutter/img/products.png) |

| Reports (รายงาน) | Shift closing report (ปิดกะ) |
|---|---|
| ![Reports](docs/tutorial/flutter/img/reports.png) | ![Closing report](docs/tutorial/flutter/img/closing-report.png) |

More in [`docs/tutorial/flutter/`](docs/tutorial/flutter/) (Thai user manual).

---

## Features

Thirteen screens plus a login route. Twelve are reachable from the navigation rail.

| Screen | Route | What the shop does there |
|---|---|---|
| ขายสินค้า — Checkout | `/` | Ring up a sale: cart, receipt, low-stock warning, park a sale, save as quote, mechanic credit with an explicit over-limit override |
| สินค้า/สต็อก — Products | `/products` | Catalogue and stock levels, barcode label printing, stock valuation, supplier links |
| สั่งซื้อ — Purchase orders | `/purchase-orders` | Raise a PO and receive stock against it (weighted-average cost) |
| ค้นหารุ่น — Vehicle search | `/vehicle-search` | Find parts by vehicle model |
| ลูกค้า — Customers | `/customers` | Customer records, spend and loyalty points |
| ช่าง — Mechanics | `/mechanics` | Mechanic accounts, credit balance, credit repayment intake |
| คืนสินค้า — Returns | `/returns` | Returns and credit notes, with an over-refund guard |
| ใบเสนอราคา — Quotes | `/quotes` | Create, filter, duplicate, convert to a sale, export CSV, A4 preview |
| รายงาน — Reports | `/reports` | KPIs, top products, sales by category |
| ตั้งค่า — Settings | `/settings` | Shop settings, snapshot export/import, CSV export |
| ลิ้นชัก — Cash drawer | `/cash-drawer` | Open/close a shift, cash in/out, closing report |
| รอเจ้าของ — Owner review | `/owner-review` | Owner clears items the till flagged for approval |
| Devices | `/devices` | Enrol and retire shop terminals |

### The rules that actually matter

These are business invariants, held by a database transaction on both sides. They are the
reason this is not a CRUD app:

- **Sale** — stock is validated *before* anything is written, and all failing lines come back
  in one response, not one at a time. The decrement is strict: an underflow throws, it never
  clamps to zero. Loyalty points are `floor(total / 10)`.
- **Return** — refund quantity can never exceed (sold − already refunded). Discounts, points
  and mechanic credit are reversed proportionally. A full return voids the parent sale.
- **Purchase order receive** — cost is recomputed as a weighted average over old and new stock.
- **Shift** — opening a shift archives the previous one; a closed shift accepts no more drawer
  entries.
- **Manual stock adjustment** is the *only* path that clamps at zero, because a human typed it.
- **Idempotency** — every write carries an `Idempotency-Key` minted once per cart. Retrying a
  request that timed out cannot ring the sale twice; only a 4xx counts as a verdict.
- **Cross-tenant reads return zero rows**, proven by an end-to-end sweep over all 25
  tenant-scoped tables and 12 HTTP endpoints, not by trusting a `WHERE` clause.

---

## Architecture

```
  Counter PCs / tablets                   Single VM (4 vCPU · 6 GB RAM)
 ┌──────────────────────┐        ┌───────────────────────────────────────────┐
 │  Flutter app         │        │  Nginx :443   TLS · rate limit · static    │
 │  ├─ flutter_bloc     │ HTTPS  │       │                                   │
 │  ├─ go_router        │ ─────► │       ▼  least_conn                       │
 │  └─ Drift / SQLite   │  JWT   │   api-1   api-2   api-3   (NestJS)        │
 │       read cache     │        │       │      │      │                     │
 └──────────────────────┘        │       └──────┼──────┘                     │
                                 │              ▼                            │
                                 │  PostgreSQL 16 — source of truth, RLS     │
                                 │  redis-cache  (allkeys-lru, no persist)   │
                                 │  redis-queue  (noeviction, AOF) ─► worker │
                                 │  etcd · Prometheus · Grafana              │
                                 └───────────────────────────────────────────┘
```

Two Redis instances is deliberate and not a typo: a single instance with an `allkeys-lru`
eviction policy will silently evict queued jobs, losing sales with no error anywhere.

The API is served under `/api/v1` (health and metrics are deliberately unprefixed):
`auth`, `platform/*`, `devices`, `products`, `categories`, `suppliers`, `movements`,
`customers`, `mechanics`, `sales`, `returns`, `purchase-orders`, `quotes`, `parked-sales`,
`shifts`, `reports`, `review-items`, `settings`, `bootstrap`, `doc-counters`, `sync`, `backup`.

### Branches

| Branch | What it is |
|---|---|
| `main` | Active line — Flutter client + NestJS backend + CI/CD |
| `POC_sample_offline_first` | Frozen snapshot of the offline-first, Drift-only build the shop runs today |

---

## Repository layout

```
frontend/                  Flutter app
  lib/core/                router, theme, shared utils (money, ids, dates, CSV)
  lib/data/db/             Drift tables + generated code (committed)
  lib/data/repositories/   one repository per domain; api/ holds the server-backed ones
  lib/presentation/        13 screens, shared widget kit, blocs and cubits
  test/                    64 test files — repositories, migrations, API contract, route smoke
  web/                     sqlite3.wasm + drift_worker.js (versions pinned, CI-enforced)
server/                    NestJS backend
  src/db/migrations/       14 TypeORM migrations (schema, RLS, role timeouts, sync columns)
  src/common/              the tenancy and transaction seam
  test/                    53 e2e specs against real Postgres and Redis
deploy/
  ansible/                 provision.yml (once, with sudo) · deploy.yml (every release)
  compose/                 monitoring stack and VM image overrides
  prometheus/ grafana/     scrape config and the provisioned dashboard
  scripts/                 backup, restore, RSS measurement, deploy entrypoint
docs/Backend_design/       the binding backend spec; adr/ is the decision record
docs/handoff_log/          dated session records — why things are the way they are
CONTRACT.md                binding client spec: tables, repo signatures, routes, Thai strings
CLAUDE.md                  project knowledge base — read this before changing anything
```

---

## Installation

### Prerequisites

Flutter 3.44.3 (pinned in `frontend/.fvmrc`), Node 22 with `pnpm` via corepack, and Docker
with the Compose plugin.

### Frontend

```bash
cd frontend
flutter pub get
dart analyze          # NOT `flutter analyze` — see the path constraint below
flutter test
```

Run it:

```bash
# offline build — the shop's mode, no server needed
flutter run

# API build — talks to the backend
flutter run --dart-define=USE_API_WRITES=true --dart-define=API_BASE_URL=http://localhost:3000

# web build for the counter PC
flutter build web --no-tree-shake-icons
```

> ⚠️ **`build_runner` and `flutter analyze` fail on a filesystem path containing non-ASCII
> characters.** The Dart AOT compiler mangles the path and cannot write its snapshot. The
> generated `*.g.dart` files are therefore committed, so the repo builds, runs and tests
> anywhere; only regeneration after a Drift schema change needs an ASCII path such as
> `C:\srisurart_pos`. Always use `dart analyze`.

### Backend

```bash
cd server
cp .env.example .env          # ships a dummy RSA keypair for local use only
docker compose up -d --build
curl -k https://localhost/health/live
curl -k https://localhost/health/ready
```

Without Docker for the app itself (datastores still in Docker):

```bash
corepack pnpm install
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --wait \
  postgres redis-cache redis-queue
corepack pnpm build
DATABASE_URL=postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos corepack pnpm db:migrate
corepack pnpm start:dev
```

Checks: `pnpm typecheck && pnpm lint && pnpm test`, then `pnpm test:e2e` for the integration
suite (real Postgres, real Redis, real migrations).

The dev overlay publishes Postgres and both Redis instances on `127.0.0.1` only. **Never use
that overlay on a shared host.**

---

## Environment

The server reads its configuration from the environment. Compose injects it through a single
`x-app-env` anchor — a variable present in `.env` but missing from that anchor never reaches
the container.

### Required

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection for the least-privileged `pos_app` role |
| `POSTGRES_PASSWORD` · `POS_APP_PASSWORD` | Owner and application role passwords |
| `REDIS_PASSWORD` | Shared password for both Redis instances |
| `REDIS_CACHE_URL` · `REDIS_QUEUE_URL` | Cache and queue endpoints |
| `JWT_PRIVATE_KEY` · `JWT_PUBLIC_KEYS` · `JWT_KEY_ID` | RS256 keypair for shop tokens |
| `JWT_PLATFORM_SECRET` | HS256 secret for platform-admin tokens |
| `ETCD_ROOT_PASSWORD` | etcd RBAC root credential |
| `BULL_BOARD_PASSWORD` | Basic auth for the queue dashboard |
| `K6_REMOTE_WRITE_BASIC_AUTH_USER` · `_PASSWORD` | Auth for the load-test metrics endpoint |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin — no default, fails fast (monitoring overlay) |

### Optional

| Variable | Default | Purpose |
|---|---|---|
| `DB_POOL_SIZE` | `15` per API instance and `5` for the worker as shipped in compose; `5` if the variable is absent entirely | Postgres pool size |
| `REDIS_COMMAND_TIMEOUT_MS` | `1000` | Cache client timeout (not BullMQ) |
| `CORS_ORIGINS` | unset → `*` | Browser origin allowlist |
| `PLATFORM_ADMIN_IPS` | unset → loopback only | Extra IPs allowed on the admin plane |
| `LOG_LEVEL` | `info` | Also settable at runtime through etcd |
| `DOC_NUMBER_FALLBACK` | `true` | Server issues document numbers when the client omits them |
| `INSTANCE_ID` | `local` | Instance identity; also gates whether JWT keys are required |
| `PORT` | `3000` | HTTP listen port |

Leaving `CORS_ORIGINS` or `PLATFORM_ADMIN_IPS` empty is the documented way to disable them and
keeps the historical default. But a value that has content and still yields no entry — `,` or
`,,` — is a typo, and it **throws at boot** rather than silently reopening CORS to `*` with
nothing in the log to say so. Validate first, then fall back.

### Client build flags

| Flag | Default | Effect |
|---|---|---|
| `USE_API_WRITES` | `false` | `true` enables login and routes writes through the server |
| `API_BASE_URL` | `http://localhost:3000` | Backend base URL; pass it empty to mean "same origin" |

### Web database assets

`frontend/web/sqlite3.wasm` and `frontend/web/drift_worker.js` are committed binaries whose
upstream versions are recorded in `frontend/web/WEB_DB_ASSET_VERSIONS.txt`
(`sqlite3=3.4.0`, `drift=2.34.1`). If they fall out of step with `pubspec.lock`, the web
database fails at boot with no visible error. CI checks this on every build; bumping `drift`
or `sqlite3` means re-downloading both assets from the matching release tags.

---

## Deployment

Production is a single university VM (`mob04`, 4 vCPU / 6 GB RAM / 48 GB disk) on an internal
network with no public inbound. The whole stack is Docker Compose; the memory budget is
roughly 3.3 GB for the POS stack and 4.2 GB with monitoring, against 6 GB total. That ceiling
is a design constraint, not an accident — it is why there is no Alertmanager and no ELK stack.

### Pipeline

```
push to main
   ├─► Flutter CI ──┐  analyze · test · drift codegen check · build web image
   └─► Server CI ───┤  lint · audit · unit · e2e on real Postgres/Redis · nginx -t
                    │
                    ├─► Trivy scan (HIGH/CRITICAL, blocks the push)
                    ├─► push images to ghcr.io  (tagged <sha> and main)
                    │
                    └─► Deploy ──► ⏸ manual approval by the required reviewer
                                       │
                                       └─► self-hosted runner on the VM
                                              └─► sudo -u deploy pos-deploy <sha>
```

The deploy job is queued into GitHub's "Waiting for review" state on every green `main` and
does not reach a runner until a named reviewer approves it. That approval click is the entire
mechanism for keeping a merge off the VM during a demo.

> **Status: this pipeline has never completed a real run.** Everything up to and including the
> image push to GHCR works and runs on every merge. The last hop does not: the self-hosted
> runner is not yet installed on the VM, and the VM cannot pull from `ghcr.io` at all because
> of the network policy described in [bottleneck #9](#known-bottlenecks). The release sequence
> below is what the playbooks do, verified by reading and by dry runs — it is not a report of a
> production deployment that has happened.

### What a release does

1. `pos-deploy` clones `main` itself — it never trusts the CI job's checkout — and refuses any
   commit not on `main` or older than a hardcoded rollback floor.
2. Ansible pulls the images, syncs the static web bundle, and runs migrations **before** any
   new code starts. Schema changes are expand/contract; there are no down-migrations.
3. API instances restart one at a time, each waiting to report healthy before the next.
4. The Nginx config is validated in a throwaway container, then force-recreated.
5. The deployed SHA is written to `/opt/pos/.current_sha`, and only then is monitoring brought
   up — a monitoring failure warns, it never fails the release.
6. On failure it rolls back automatically to the previously recorded SHA, and the pipeline
   still reports red.

Rollback is a `workflow_dispatch` with an earlier SHA. **The schema is never rolled back.**

### Operations

Health: `GET /health/live` touches nothing (a database outage must not restart every
instance); `GET /health/ready` probes Postgres and both Redis instances on dedicated
connections with a 2-second timeout and answers `503` with per-check detail.

Metrics: `GET /metrics` exposes `http_requests_total`, `http_request_duration_seconds` and
`pos_idempotency_replay_total`. Health and metrics paths are excluded from the service-level
indicators on purpose — scraping three instances every 15 seconds manufactures around 36
guaranteed successes a minute, which is enough to make a day where every real sale failed
still read as roughly 92% healthy.

Monitoring binds to loopback only and is reached over an SSH tunnel.

Backups: provisioning installs a nightly 03:00 `pg_dump` cron writing into `/opt/pos/backups`.
**It has not been applied to the VM, so no backup currently runs there** — the crontab is empty
and the directory does not exist. A missing cron entry produces no failure signal at all, which
is worse than one that fails loudly, so it is recorded here rather than left to be discovered.

---

## Testing and CI/CD

| Suite | Command | Count |
|---|---|---|
| Flutter unit / repository / widget / route smoke | `flutter test` | 64 files |
| Server unit | `pnpm test` | 49 files |
| Server end-to-end, on real Postgres + Redis + migrations | `pnpm test:e2e` | 53 files |

Three of the unit specs — `tenant-door.spec.ts`, `tenant-wrapper.spec.ts` and
`idempotency-routes.spec.ts` — guard the tenancy and idempotency seam itself: they fail if a
new write route appears without an idempotency claim, or if a transaction is opened anywhere
other than a request handler. They are meant to be changed deliberately, never just to turn
them green.

Both workflows trigger unfiltered and gate their own jobs internally, so a backend-only PR
still satisfies the frontend's required check. Exactly two checks are required to merge:
`flutter-ci-status` and `server-ci-status`. The end-to-end suite is deliberately exempt from
path filtering because it carries the cross-tenant isolation tests, and "this PR only touched
the frontend" is exactly the reasoning that lets a tenancy regression through.

Trivy runs twice — once over the filesystem and lockfiles, once over the built image — and
blocks the GHCR push on any fixable HIGH or CRITICAL finding. Base images are pinned by
digest. There is no `.trivyignore` in this repository, and adding one is not an accepted fix.

---

## Scalability, limits and known bottlenecks

This runs one shop on one VM. It is honest about what that means.

### Measured and proven

- **200 concurrent `POST /sales` against a product with 50 in stock produced exactly 50 bills
  and left stock at 0, never negative** — 201×50, 409×150, zero 5xx.
- A 200-round three-way race (till sales + back-office PO receipt + manual stock adjustment on
  the *same* product) finished with stock and stock movements both exact, no deadlock and no
  lost update. This is the concurrency that actually exists in a shop, which is why it is
  tested in preference to hammering one endpoint.
- Cross-tenant reads return zero rows across all 25 tenant-scoped tables.
- With `redis-cache` genuinely unreachable — both refused *and* connected-but-silent — sales
  still complete and stock still decrements, while a suspended tenant is still refused.

### Targets defined but not yet measured

The thresholds below are agreed but unproven. Nothing in this section is a result.

| Scenario | Load | Threshold |
|---|---|---|
| `GET /products` | 1,000 VUs | p95 < 200 ms, cache hit > 90%, errors < 0.1% |
| `POST /sales` on one product set | 200 VUs | stock never negative, no duplicate bills, p95 < 500 ms |
| Repeated `Idempotency-Key` | 100 VUs × 5 | one bill, one stock decrement |
| Mixed 80/20 read/write | 500 VUs, 10 min | connection pool never exhausted |

The source specification also sets a replication-lag target for the mixed scenario. It does not
apply here: there is no read replica, which is bottleneck #1.

Measuring this needs three machines pushing load simultaneously, each under its own per-IP
rate limit, because a single client through Nginx measures the client, and running the load
generator on the VM makes it compete with the server for CPU. Exempting the load generator
from the rate limit was considered and rejected: a limiter you switch off to get a good number
is not a limiter.

That method has a consequence worth stating plainly. Three machines under a 30 r/s per-IP limit,
held to a safety margin of 24 r/s each, deliver roughly **72 requests per second in aggregate**.
The virtual-user counts above therefore describe tail latency under sustained concurrency; they
are not a claim that this deployment serves 1,000 concurrent users. Measuring that would need a
load path that does not pass through the limiter the shop itself lives behind.

### Known bottlenecks

| # | Bottleneck | Where it bites | Path forward |
|---|---|---|---|
| 1 | **Single VM, single Postgres, single disk** | No high availability. A dead disk loses the tenant. | Managed Postgres or a replica. This is the first thing to fix for real multi-tenant traffic. |
| 2 | **Postgres `max_connections=100`, budget 62** | 3 API × (15 request + 2 audit + 1 health) + worker. A fourth instance breaches the budget. | PgBouncer in transaction mode. Scaling API instances without it exhausts the pool before it exhausts the CPU. |
| 3 | **Writes serialize on row locks** in a fixed order — sales → mechanic → products → `doc_counters` → customer, with a `shifts` `FOR SHARE` read between the sale and mechanic locks on void and return paths | One very hot part number is the throughput ceiling for that tenant, no matter how many instances run. | Correct by design; fix by sharding tenants, not by loosening the locks. |
| 4 | **25-second commit ceiling** | Any transaction open longer is rolled back before `COMMIT`; `statement_timeout` is 25 s and `idle_in_transaction` 5 s. | Keeps a slow query from holding locks across a shop's whole afternoon. Long work belongs on the queue. |
| 5 | **Per-IP rate limit, 30 r/s burst 60** | A whole shop behind one NAT address shares a single bucket. | Per-tenant limiting exists as an application guard; the Nginx limit is only a pre-auth flood guard. |
| 6 | **Nginx must be the only proxy in front of the API** | `trust proxy` is exactly 1. A CDN or second proxy collapses every client into one rate-limit bucket. | Any edge layer must forward the client IP correctly, or the limiter becomes decorative. |
| 7 | **6 GB RAM ceiling** | Roughly 4.2 GB is already used with monitoring running. | Ruled out Wazuh and ELK (4–5 GB each). More headroom means a bigger host, not tuning. |
| 8 | **No backup runs on the VM at all** | The nightly job is written and provisioned but has never been applied to the machine, and the offsite upload on top of it is built (`rclone`, pluggable destination) and deliberately parked. | Re-run provisioning, then configure a destination. Until both happen, a dead disk loses the tenant — recorded rather than hidden. |
| 9 | **Deploy blocked by network policy** | The campus firewall performs SSL inspection and answers for `ghcr.io` with its own certificate, which carries no SAN, so hostname verification fails and the VM cannot pull images. This kills both delivery paths at once — the self-hosted runner and the manual Ansible run share the VM's Docker daemon. Trusting the firewall's CA does *not* fix it. | Needs the network team to exempt the registry hosts for this VM. Copying images by hand is a demo-day rescue, not a delivery pipeline, and is not recorded as one. |

### If usage grew

The client already uses stateless tokens and the API instances share nothing, so the first
three steps are mechanical: put PgBouncer in front of Postgres, add API instances behind the
existing `least_conn` upstream, and move the static web bundle to a CDN. The fourth step is
not mechanical — tenants would have to shard across databases, because row-level security
gives isolation but not independent throughput, and bottleneck #3 does not improve with more
instances. That is the point at which this design stops being the right one, and knowing
where that line sits is more useful than pretending it is not there.

---

## Roadmap

**Phase 1 — multi-tenant backend.** 16 of the 17 definition-of-done criteria are met; the one
still open is the k6 load-test measurement. Separately from that checklist, and larger than it,
the delivery path is unproven: no release has ever reached the VM, for the network reason in
bottleneck #9. The backend itself — tenancy, transactions, idempotency, the full API surface —
is built and tested.

**Phase 2 — offline shell, in progress.** Returns offline capability to the API build: an
outbox of pending operations, a sync service, offline receipt and credit-note numbering, an
offline PIN window enforced at the till, and a single writer device per shop. The offline
build is not being abandoned; it is being made to coexist with a server.

**Later.** Thermal printer, cash-drawer kick and barcode scanning need physical shop access.
Backups, offsite copies, PDPA handling and an audit log are specified and not yet wired.

---

## Documentation

| Start here | |
|---|---|
| [`docs/00_LANE_PRIMER.md`](docs/00_LANE_PRIMER.md) | เริ่มอ่านตรงนี้ก่อน — system overview and the ticket split, in Thai |
| [`CLAUDE.md`](CLAUDE.md) | Conventions, constraints, current status — read before changing anything |
| [`CONTRACT.md`](CONTRACT.md) | The binding client spec |
| [`docs/Backend_design/00_INDEX.md`](docs/Backend_design/00_INDEX.md) | The backend package; start at `00_BASICS.md` if backend is new to you |
| [`docs/Backend_design/adr/`](docs/Backend_design/adr/) | The decision record. **Binding** — where a doc contradicts an ADR, the ADR wins |
| [`docs/handoff_log/`](docs/handoff_log/) | Dated session records: what changed, what broke, and why |
| [`docs/tutorial/testing-tutorial.md`](docs/tutorial/testing-tutorial.md) | What each of the 12 test suites checks, how to run it, where to read the result (Thai) |

---

Built by **NuimanLP**, **LomerAlloys** and **PattaraponKitcharoen** as a senior project.
The shop is real, the constraints are real, and the parts that do not work yet are listed
above rather than left out.
