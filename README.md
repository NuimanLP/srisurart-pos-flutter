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

> **Status (2026-10-08):** development is frozen for the course submission (owner decision,
> 2026-10-07) — only fixes the owner asks for. The latest release is `main` `6a38c87`
> (PR #669), deployed to the demo VM `mob04`. Detail:
> [`session-2026-10-08-suppliers-not-pulled.md`](docs/handoff_log/session-2026-10-08-suppliers-not-pulled.md).

---

## Table of contents

- [Overview](#overview)
- [Screenshots](#screenshots)
- [Features](#features)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Setup / Quickstart](#setup--quickstart)
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
| **Local store** | Drift (SQLite) — 26 tables, schema version 13 |
| **State / routing** | `flutter_bloc` 9.x, `go_router` 17.x |
| **Backend** | NestJS, PostgreSQL 16, Redis 7 (×2), BullMQ, Nginx 1.29, etcd 3.6 |
| **Tenancy** | One database, many tenants, PostgreSQL Row-Level Security forced on every tenant-scoped table |
| **Deployment** | Docker Compose on a single university VM, rolled out by Ansible from GitHub Actions |
| **Tests** | 120 Flutter test files · 63 server unit specs · 61 server end-to-end specs |

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
| ![Checkout](docs/tutorial/sri-pos-manual/img/checkout.png) | ![Products](docs/tutorial/sri-pos-manual/img/products.png) |

| Reports (รายงาน) | Shift closing report (ปิดกะ) |
|---|---|
| ![Reports](docs/tutorial/sri-pos-manual/img/reports.png) | ![Closing report](docs/tutorial/sri-pos-manual/img/closing-report.png) |

Captured from the API build against a local dev stack with a demo tenant. More in
[`docs/tutorial/sri-pos-manual/`](docs/tutorial/sri-pos-manual/) — the Thai SOP user manual,
one part per role (counter staff, owner, platform admin, IT operations, dashboards).

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
| ตั้งค่า — Settings | `/settings` | Shop settings, snapshot export/import, CSV export; on the API build the owner restores a backup into the server (below) |
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

### Owner backup import (API build)

The shop owner restores a backup file from **ตั้งค่า → สำรอง/กู้คืน → กู้คืนข้อมูล**. It calls
`POST /api/v1/backup/import` (202 + a job) and polls `GET /api/v1/backup/import/:jobId`; only
the `owner` role on an enrolled device may do it, and it runs through the same import service
as the platform-admin import.

- A shop that already has data needs replace mode, `?mode=replace&confirmShopName=<shop name>`:
  the owner types the shop name, and the whole shop's business data is replaced in one
  transaction. Users, devices, the audit log and the document counters are kept.
- Every import — owner or platform — raises `doc_counters` to the highest RC/CN/PO/QT/CP number
  in the file, so the first new sale does not collide with an imported receipt number.
- A pre-import copy of the shop is written to the VM's `exports` volume and is **never
  deleted automatically** (personal data — retention is the owner's call). It lives only on
  the VM disk.
- Known limits: other devices of the same shop keep stale rows after a replace (clear site
  data); shifts, drawer entries, stock movements, credit-payment history and parked bills in
  the file reach Postgres but are not pulled into the app (suppliers were on this list until
  PR #668/#669, below).

Detail: [`session-2026-10-08-owner-import.md`](docs/handoff_log/session-2026-10-08-owner-import.md).

### Suppliers (API build)

On the API build the server is the truth for suppliers (PR #668/#669): `ApiSuppliersRepository`
pulls `GET /api/v1/suppliers` into Drift (the screens still read Drift, so the last copy stays
visible offline), and add/edit/delete go online to `POST`/`PATCH`/`DELETE /api/v1/suppliers`
with an `Idempotency-Key`, writing Drift only from the server's reply. The offline build is
unchanged. Detail: [`session-2026-10-08-suppliers-not-pulled.md`](docs/handoff_log/session-2026-10-08-suppliers-not-pulled.md).

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
| `main` | Release line — Flutter client + NestJS backend + CI/CD; every code push is deployed after a manual approval |
| `develop` | Integration branch — every work PR targets it; it reaches `main` by merge commit only, enforced by a repository ruleset (a squash would drop the deploy rollback floor `bedd328` off `main`) |
| `POC_sample_offline_first` | Frozen snapshot of the offline-first, Drift-only build the shop runs today |

---

## Repository layout

```
frontend/                  Flutter app
  lib/core/                router, theme, shared utils (money, ids, dates, CSV)
  lib/data/db/             Drift tables + generated code (committed)
  lib/data/repositories/   one repository per domain; api/ holds the server-backed ones
  lib/presentation/        13 screens, shared widget kit, blocs and cubits
  test/                    120 test files — repositories, migrations, API contract, route smoke
  web/                     sqlite3.wasm + drift_worker.js (versions pinned, CI-enforced)
server/                    NestJS backend
  src/db/migrations/       23 TypeORM migrations (schema, RLS, role timeouts, sync columns,
                           UUID entity ids) — the schema's source of truth, 29 tables
  src/common/              the tenancy and transaction seam
  test/                    61 e2e specs against real Postgres and Redis
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

## Setup / Quickstart

### Prerequisites

Flutter 3.44.3 (pinned in `frontend/.fvmrc`, `sdk: ^3.12.2` in `frontend/pubspec.yaml`), Node
`>=22` with `pnpm` (`server/package.json` pins `packageManager: pnpm@10.34.5`, used via
`corepack`), and Docker with the Compose plugin. These are the exact versions CI uses
(`.github/workflows/flutter.yml`, `.github/workflows/server.yml`).

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
cp .env.example .env          # ships dev-only-* placeholders + a dummy RSA keypair — see "Dev secrets" below
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
DATABASE_URL=postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos \
REDIS_CACHE_URL=redis://:dev-only-redis@127.0.0.1:6379 \
REDIS_QUEUE_URL=redis://:dev-only-redis@127.0.0.1:6380 \
ALLOW_DEV_SECRETS=true \
corepack pnpm start:dev
```

Checks: `pnpm typecheck && pnpm lint && pnpm test`, then `pnpm test:e2e` for the integration
suite (real Postgres, real Redis, real migrations). A first admin user for a tenant is created
with `pnpm bootstrap:admin` (see `server/README.md`).

The dev overlay publishes Postgres and both Redis instances on `127.0.0.1` only. **Never use
that overlay on a shared host.**

### Dev secrets

`server/.env.example` ships the public `dev-only-*` placeholders and dummy JWT key pair used
above. Since #410/#416, `api-*`/`worker`/`bull-board` **refuse to boot** with any of
those placeholders — in a bare password variable or hidden inside `DATABASE_URL` /
`DATABASE_ADMIN_URL` / `REDIS_CACHE_URL` / `REDIS_QUEUE_URL` — unless
`ALLOW_DEV_SECRETS=true` is set exactly. `.env.example` already sets it, so a fresh clone
works; an **existing `server/.env` made before #412** needs it appended by hand:

```bash
echo 'ALLOW_DEV_SECRETS=true' >> server/.env
```

**Never set `ALLOW_DEV_SECRETS` on a real host** — the demo VM's
`deploy/compose/vm.override.yml` forces it empty regardless of what `.env` says. For
generating real secrets (VM/production), follow the existing runbook in
[`docs/handoff_log/ticket-336-env-secrets.md`](docs/handoff_log/ticket-336-env-secrets.md)
rather than improvising new values by hand.

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
PR → develop (full CI, no images)  ──  develop → main by merge commit
push to main   (GitHub-hosted runners)
   ├─► Flutter CI ──┐  analyze · test · drift codegen check · build web image
   └─► Server CI ───┤  lint · audit · gitleaks · unit · e2e on real Postgres/Redis · nginx -t
                    │
                    ├─► Trivy scan (HIGH/CRITICAL, blocks the push)
                    ├─► push images to ghcr.io  (tagged <sha> and main)
                    │
                    └─► Deploy: resolve — are BOTH images for <sha> on GHCR?
                           └─► ⏸ `demo` environment approval (NuimanLP)
                                  └─► self-hosted runner `mob04-demo` on the VM
                                         └─► sudo -u deploy pos-deploy <sha> ──► Ansible
```

The deploy job is queued into GitHub's "Waiting for review" state on every green `main` and
does not reach a runner until the required reviewer approves it. That approval click is the
entire mechanism for keeping a merge off the VM during a demo. A docs-only push to `main`
builds no images and deploys nothing. Full detail: [`07_CICD_DEPLOY.md`](docs/Backend_design/07_CICD_DEPLOY.md)
§2 and §6.

> **Status:** the pipeline has run end to end since **2026-09-30** — first real runner deploy
> `e50f4fa` ([handoff](docs/handoff_log/session-2026-09-30-first-runner-deploy.md)), with a
> `workflow_dispatch` rollback and an automatic rollback after a failed readiness check both
> proven on real runs the same day. The latest release on `mob04` is `6a38c87` (PR #669,
> 2026-10-08, deploy run `37708387535`, Ansible `failed=0`). **A green `Deploy (demo)` run is
> not proof of a deploy** — when an image is missing, `resolve` skips the deploy job and the
> run still reports success. The VM's `/opt/pos/.current_sha` is the only proof.

### What a release does

1. `pos-deploy` clones `main` itself — it never trusts the CI job's checkout — and refuses any
   commit not on `main` or older than a hardcoded rollback floor (`bedd328`, set at the
   2026-10-06 UUID entity-id cutover, which wiped every tenant on `mob04` —
   [handoff](docs/handoff_log/session-2026-10-06-uuid-cutover-mob04.md)).
2. Ansible pulls the images, syncs the static web bundle, and runs migrations **before** any
   new code starts. Schema changes are expand/contract; there are no down-migrations.
3. API instances restart one at a time, each waiting to report healthy before the next.
4. The Nginx config is validated in a throwaway container, then force-recreated.
5. The deployed SHA is written to `/opt/pos/.current_sha`, and only then is monitoring brought
   up — a monitoring failure warns, it never fails the release.
6. On failure it rolls back automatically to the previously recorded SHA, and the pipeline
   still reports red.

Rollback is a `workflow_dispatch` with an earlier SHA. **The schema is never rolled back.**

If the runner shows offline while its systemd service is `active` (seen 2026-10-08), the
Deploy run sits queued; check `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners`
before approving, and restart the runner service on the VM.

### Web cache after a deploy

Nginx serves `index.html` and `flutter_bootstrap.js` with `Cache-Control: no-cache`, and the
per-release entry point `main.<sha>.dart.js` as `immutable`. A tab that was already open keeps
running the old build until it is reloaded — before concluding a fix "did not work", check
the `main.<sha>.dart.js` name in DevTools → Sources (this is what happened after `6a38c87`).

### Android APK

`.github/workflows/android-apk.yml` is manual (`workflow_dispatch`) and runs on `main` only. It
builds the API build only (`USE_API_WRITES=true`, pointed at `mob04`), signs it with the
project's stable key from the `ANDROID_KEYSTORE_B64` secret so each new APK installs over the
old one, and publishes it as a prerelease `apk-<shortsha>`. The latest is `apk-6a38c87`.
Losing the keystore means no APK can upgrade in place. Detail: `07_CICD_DEPLOY.md` §2b.

### Operations

Health: `GET /health/live` touches nothing (a database outage must not restart every
instance); `GET /health/ready` probes Postgres and both Redis instances on dedicated
connections with a 2-second timeout and answers `503` with per-check detail.

Metrics: `GET /metrics` exposes `http_requests_total`, `http_request_duration_seconds`,
`pos_idempotency_replay_total`, and the business/runtime metrics `pos_documents_total`,
`pos_db_pool_connections` and `pos_queue_jobs`. Health and metrics paths are excluded from the
service-level indicators on purpose — scraping three instances every 15 seconds manufactures around 36
guaranteed successes a minute, which is enough to make a day where every real sale failed
still read as roughly 92% healthy.

Monitoring binds to loopback only and is reached over an SSH tunnel.

Backups: `provision.yml` installs `backup-db.sh` and a nightly 03:00 `pg_dump` cron writing into
`/opt/pos/backups`. It has been installed on `mob04` and running nightly since 2026-10-01.
**No copy leaves the VM** — the offsite upload (`rclone`, optional) is built but not wired,
and that work is parked (#363), so a dead VM disk still loses every tenant. A green
`backup-cron.log` therefore does not prove a backup left the machine. Note that a CD deploy
does not update `/opt/pos/scripts`; only `provision.yml` (or a manual install) does.

Uptime: `healthcheck-ping.sh` pings an external heartbeat every 5 minutes from cron
(installed on `mob04` 2026-10-04).

---

## Testing and CI/CD

| Suite | Command | Count |
|---|---|---|
| Flutter unit / repository / widget / route smoke | `flutter test` | 120 files |
| Server unit | `pnpm test` | 63 files |
| Server end-to-end, on real Postgres + Redis + migrations | `pnpm test:e2e` | 61 files |

Three of the unit specs — `tenant-door.spec.ts`, `tenant-wrapper.spec.ts` and
`idempotency-routes.spec.ts` — guard the tenancy and idempotency seam itself: they fail if a
new write route appears without an idempotency claim, or if a transaction is opened anywhere
other than a request handler. They are meant to be changed deliberately, never just to turn
them green.

Both workflows run on every PR and on every push to `main` and `develop`, and gate their own
jobs internally, so a backend-only PR
still satisfies the frontend's required check. Exactly two checks are required to merge:
`flutter-ci-status` and `server-ci-status`. The end-to-end suite is deliberately exempt from
path filtering because it carries the cross-tenant isolation tests, and "this PR only touched
the frontend" is exactly the reasoning that lets a tenancy regression through.

Trivy runs twice — once over the filesystem and lockfiles, once over the built image — and
blocks the GHCR push on any fixable HIGH or CRITICAL finding. Base images are pinned by
digest. There is no `.trivyignore` in this repository, and adding one is not an accepted fix.
A gitleaks secret scan runs on every PR and push and is part of `server-ci-status`.

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

### Load-test targets — not yet accepted

The thresholds below are agreed but unproven: the k6 box is the one definition-of-done item
still open (#380). A first real three-machine run on `mob04` happened on 2026-10-05 (read
scenario inside its threshold; 200 concurrent buyers p95 ≈ 3 s, over it; replay scenario
unclean on 429s), but its tooling had bugs, fixed on 2026-10-07 (PR #654/#655), so it ticks
nothing. A re-run with the fixed tooling, read and accepted by the owner, is still to do —
[handoff](docs/handoff_log/session-2026-10-05-k6-capacity-run.md).

| Scenario | Load | Threshold |
|---|---|---|
| `GET /products` | 1,000 VUs | p95 < 200 ms, cache hit > 90%, errors < 0.1% |
| `POST /sales` on one product set | 200 VUs | stock never negative, no duplicate bills, p95 < 500 ms |
| Repeated `Idempotency-Key` | 27 VUs × 5 (owner accepted 2026-10-07 in place of 100: 3 machines × 9, the per-IP burst budget) | one bill, one stock decrement |
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
| 2 | **Postgres `max_connections=100`, budget 70** | 3 API × (15 request + 2 audit + 1 health + 2 admin) + worker. A fourth instance breaches the budget. | PgBouncer in transaction mode. Scaling API instances without it exhausts the pool before it exhausts the CPU. |
| 3 | **Writes serialize on row locks** in a fixed order — sales → mechanic → products → `doc_counters` → customer, with a `shifts` `FOR SHARE` read between the sale and mechanic locks on void and return paths | One very hot part number is the throughput ceiling for that tenant, no matter how many instances run. | Correct by design; fix by sharding tenants, not by loosening the locks. |
| 4 | **25-second commit ceiling** | Any transaction open longer is rolled back before `COMMIT`; `statement_timeout` is 25 s and `idle_in_transaction` 5 s. | Keeps a slow query from holding locks across a shop's whole afternoon. Long work belongs on the queue. |
| 5 | **Per-IP rate limit, 30 r/s burst 60** | A whole shop behind one NAT address shares a single bucket. | Per-tenant limiting exists as an application guard; the Nginx limit is only a pre-auth flood guard. |
| 6 | **Nginx must be the only proxy in front of the API** | `trust proxy` is exactly 1. A CDN or second proxy collapses every client into one rate-limit bucket. | Any edge layer must forward the client IP correctly, or the limiter becomes decorative. |
| 7 | **6 GB RAM ceiling** | Roughly 4.2 GB is already used with monitoring running. | Ruled out Wazuh and ELK (4–5 GB each). More headroom means a bigger host, not tuning. |
| 8 | **No backup leaves the VM** | The nightly local `pg_dump` runs on `mob04` (since 2026-10-01), but the offsite upload on top of it is built (`rclone`, pluggable destination) and deliberately parked (#363); the destination protocol is not settled. | Pick a protocol, prove the network route, configure credentials. Until then a dead disk loses every tenant — recorded rather than hidden. |
| 9 | ~~**Deploy blocked by network policy**~~ — **resolved 2026-09-29/30** | The campus firewall's SSL inspection used to answer for `ghcr.io` with a certificate carrying no SAN, so the VM could not pull images. Its certificate now carries the SAN and `mob04` pulls from GHCR. | If `x509: certificate is not valid for any names` returns, the block is back: the network team must exempt the registry hosts for this VM. Copying images by hand is a demo-day rescue, not CD. |

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
still open is the k6 load-test measurement (#380, re-run pending). The backend — tenancy,
transactions, idempotency, the full API surface — is built and tested, and the delivery path
is proven: releases have reached `mob04` through CD since 2026-09-30. The end-to-end demo run
on `mob04` (#344) covered AC1–AC5 on 2026-10-07; its last criterion awaits the owner
([handoff](docs/handoff_log/session-2026-10-07-demo344-run.md)).

**Phase 2 — offline shell.** Returns offline capability to the API build: an outbox of pending
operations, a sync service, offline receipt and credit-note numbering, an offline PIN window
enforced at the till, and a single writer device per shop — built and merged; every phase-2
hub ticket is closed except the cutover (#231): the shop itself has not moved off the offline
build. The offline build is not being abandoned; it is being made to coexist with a server.

**Later.** Thermal printer, cash-drawer kick and barcode scanning need physical shop access.
Offsite backup copies (#363, parked) and PDPA retention rules are not wired.

---

## Documentation

| Start here | |
|---|---|
| [`docs/00_LANE_PRIMER.md`](docs/00_LANE_PRIMER.md) | เริ่มอ่านตรงนี้ก่อน — system overview and the ticket split, in Thai |
| [`docs/study/00_index.md`](docs/study/00_index.md) | The Thai self-study pack, 22 chapters — start here |
| [`CLAUDE.md`](CLAUDE.md) | Conventions, constraints, current status — read before changing anything |
| [`CONTRACT.md`](CONTRACT.md) | The binding client spec |
| [`docs/Backend_design/00_INDEX.md`](docs/Backend_design/00_INDEX.md) | The backend package; start at `00_BASICS.md` if backend is new to you |
| [`docs/Backend_design/adr/`](docs/Backend_design/adr/) | The decision record. **Binding** — where a doc contradicts an ADR, the ADR wins |
| [`docs/handoff_log/`](docs/handoff_log/) | Dated session records: what changed, what broke, and why |
| [`docs/tutorial/testing-tutorial.md`](docs/tutorial/testing-tutorial.md) | What each of the 12 test suites checks, how to run it, where to read the result (Thai) |

### Thai self-study pack (`docs/study/`)

22 chapters (`00`–`21`), in Thai, meant to be read start to finish. Entry point:
[`docs/study/00_index.md`](docs/study/00_index.md) — the map and the concepts each later
chapter assumes.

| Chapters | Group |
|---|---|
| [`00`](docs/study/00_index.md) | Intro and map |
| [`01`](docs/study/01_pitch.md)–[`03`](docs/study/03_use_case.md) | Pitch, architecture, use case |
| [`04`](docs/study/04_frontend.md)–[`07`](docs/study/07_database.md) | Frontend, API, backend, database |
| [`08`](docs/study/08_money_thai.md)–[`10`](docs/study/10_offline_phase2.md) | Money/Thai handling, data migration, offline phase 2 |
| [`11`](docs/study/11_security.md)–[`12`](docs/study/12_testing.md) | Security, testing |
| [`13`](docs/study/13_team_workflow.md)–[`16`](docs/study/16_performance.md) | Team workflow, devops, CI/CD, performance |
| [`17`](docs/study/17_lab.md)–[`18`](docs/study/18_capstone.md) | Lab, capstone |
| [`19`](docs/study/19_deploy_mob04_story.md)–[`21`](docs/study/21_demo_script.md) | The `mob04` deploy story, slide outline, live demo script |

---

Built by **NuimanLP**, **LomerAlloys** and **PattaraponKitcharoen** as a senior project.
The shop is real, the constraints are real, and the parts that do not work yet are listed
above rather than left out.
