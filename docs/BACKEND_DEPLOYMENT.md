# Srisurart POS — Backend, Supabase Hierarchy & Deployment Plan

> ### ⚠️ §1–§2 SUPERSEDED (2026-08-25)
> The backend direction changed after this was written: the team now has backend help,
> the stack is fixed to **NestJS + PostgreSQL + Redis + BullMQ + Nginx** (course/assignment
> requirement), and **multi-tenant** (many shops on one database) was added to the scope.
>
> That flips three decisions made below — no custom server → custom server; Drift as source
> of truth → PostgreSQL as source of truth; no business logic in the cloud → transactional
> logic moves server-side.
>
> **Current plan → [`Backend_design/`](Backend_design/00_INDEX.md)** (start at `00_INDEX.md`;
> `00_BASICS.md` first if you are new to backend work).
>
> **Still valid here:** §3 Deployment & hosting (Flutter Web build → shop PC, Android/iOS,
> CI/CD) — the new package does not cover deployment. Read §1–2 as history, not as the plan.

> **Status:** Planned (nothing here is built yet) · **Created:** 2026-07-13 · Companion to [`PLAN.md`](PLAN.md)
> Fills the three gaps the migration plan left open: **backend architecture**, the
> **Supabase database hierarchy**, and **deployment/hosting (incl. Docker)**.
> Execution order follows the PLAN.md phases — 7a → 7b → 8/9.

---

## 1. Backend architecture decision

**There is no custom backend server.** Supabase is the backend
(Backend-as-a-Service): the Flutter app talks to it directly via `supabase_flutter`
(not yet in `pubspec.yaml` — added in Phase 7a).

```
┌────────────────────────── device (offline-first) ──────────────────────────┐
│  Flutter app (Android / iOS / Web)                                          │
│    presentation (Riverpod) → repositories → Drift/SQLite  ← source of truth │
│                                   │                                         │
│                        backup / sync service (Phase 7)                      │
└───────────────────────────────────┼─────────────────────────────────────────┘
                                    │ HTTPS (only when online; never blocks UI)
                          ┌─────────▼─────────┐
                          │     Supabase      │
                          │  Auth · Storage   │  ← Phase 7a (snapshot backup)
                          │  Postgres (+RLS)  │  ← Phase 7b (record sync)
                          │  Edge Functions   │  ← only if ever needed (e.g.
                          └───────────────────┘     backup retention pruning)
```

Rules that keep this honest:

- **Local Drift stays the source of truth.** Cloud is durability + (later) sync;
  reads never hit the network. This is already locked in by PLAN.md §6.
- **No business logic in the cloud.** All transactional invariants (`saveSale`,
  `createReturn`, `receivePO`, …) live in the Dart repositories only. Postgres
  never re-implements them — it stores results.
- If server-side logic is ever unavoidable (scheduled pruning, a webhook), it goes
  in a **Supabase Edge Function**, not a separate server.

---

## 2. Supabase hierarchy

### 2.1 Organization / project level (Phase 7a, step 1 — the env split)

```
Supabase account (shop owner's email)
├── project: srisurart-dev      ← all development & the restore drill
└── project: srisurart-prod     ← live shop data ONLY; created after the drill passes
```

- Two **separate projects** (not one project with two schemas) — an accidental
  dev restore can never touch live data.
- The app selects the project via `--dart-define=ENV=dev|prod` → picks the URL +
  anon key. Keys live in `env/dev.json` / `env/prod.json` (git-ignored) passed with
  `--dart-define-from-file`; commit only `env/env.example.json`. **Never hard-code
  keys in Dart source** — the anon key is public-ish by design but the file split
  is what keeps dev/prod from crossing.
- Region: Singapore (`ap-southeast-1`) — closest to Thailand.
- Free tier is sufficient for 7a (one shop, snapshot files); revisit on 7b.

### 2.2 Auth (Phase 7a)

| Item | Decision |
|---|---|
| Method | Email + password, **one owner account** per project |
| Sign-ups | Disabled in dashboard (invite-only; it's a single shop) |
| App session | Long-lived; app must keep working when the token can't refresh (offline) |
| Roles | None in Supabase for v1 — the **manager PIN gate is app-level** (Phase 8a, SEC-003), not a Supabase role |

Per-device accounts only become interesting in 7b (to attribute sync writes);
until then `deviceId` in the backup path is enough.

### 2.3 Storage — snapshot backups (Phase 7a)

```
bucket: backups   (PRIVATE — public access off)
└── {deviceId}/                        ← stable per-install id, device-local prefs
    └── {yyyy-MM-dd_HHmmss}_{schemaVersion}.json.gz
```

- File content = exactly `exportSnapshot()` (the `sa_*` + `__meta` shape) — so a
  cloud backup, a local backup file, and the Phase-2 legacy import are **one
  format, one restore path** (atomic, all-or-nothing).
- Gzip before upload (JSON compresses ~10×); name carries the schema version so
  restore can refuse/migrate old shapes.
- Schedule: on app start if last backup > 24 h old, after shift close, + manual
  button in Settings. "Last backup time" stays in device-local prefs, **outside**
  the snapshot (PLAN.md §6 rule).
- Retention: keep last 30 daily + 12 monthly per device; prune client-side after a
  successful upload (an Edge Function cron is the upgrade path, not v1).
- Bucket policy: authenticated owner can read/write only under his own paths;
  no anonymous access.
- **Exit test (from PLAN.md):** full backup → wipe → restore drill on `srisurart-dev`.

### 2.4 Postgres schema (Phase 7b — record-level sync; DO NOT build during 7a)

Mirror of the 20 Drift tables, `snake_case`, same columns, split by write pattern:

| Class | Tables | Sync rule |
|---|---|---|
| **Append-only events** | `sales`, `sale_items`, `returns` (+ lines), `purchase_orders`, `po_items`, `drawer_entries`, `shifts` (archived rows) | Push-only, insert-once by client-generated id (`newId` prefix ids are the primary keys — never Postgres serials). No conflicts possible. |
| **Mutable rows** | `products`, `customers`, `mechanics`, `settings`, `quotes`, `parked_sales` | Last-write-wins by `updated_at`; conflicts flagged to a review table, never silently dropped. |
| **Sync bookkeeping** | `devices` (device_id, last_push, last_pull), `sync_conflicts` (kept row, losing row JSON, reviewed flag) | Cloud-only; never restored into Drift. |

- **Blocking prerequisite (already flagged in PLAN.md):** `updatedAt` exists only
  on `products`; must be added to `customers`/`mechanics`/`settings` (and the other
  mutable tables above) — a Drift schema change ⇒ `build_runner` on an **ASCII
  path**.
- **RLS:** enabled on every table; single policy `auth.uid() = <owner uid>` (single
  tenant). RLS is on even though there's one user — it's the seatbelt for a leaked
  anon key.
- Money stays `NUMERIC(12,2)` (matches `round2`); dates stored as `timestamptz` +
  the yyyy-MM-dd **date-key strings** kept as generated columns where reports need
  them, so cloud queries match `dateKey()` semantics.

---

## 3. Deployment & hosting (the "Docker" question)

Three deployable artifacts, three answers:

### 3.1 Flutter Web build → the shop PC (replaces `POS.html`)

The web app is still **offline-first** (Drift WASM + `sqlite3.wasm` / OPFS in the
browser) — hosting only delivers the app shell; data stays on the device.

| Option | How | Verdict |
|---|---|---|
| **A. Static file serving on the shop PC** | `flutter build web --no-tree-shake-icons` → serve `build/web` with any static server as a Windows service (e.g. Caddy: `caddy file-server --root build/web --listen :8080`); browser bookmarks `http://localhost:8080` | ✅ **Recommended v1** — same operational model as today's `POS.html`, works with the internet down, nothing new to learn |
| **B. Docker: nginx container** | `docker run -d --restart unless-stopped -p 8080:80 -v ./build/web:/usr/share/nginx/html:ro nginx:alpine` (or the Dockerfile in §3.4) | ✅ Fine **if** the shop PC already runs Docker Desktop; otherwise it adds a dependency for zero benefit over A |
| **C. Cloud static hosting** (Cloudflare Pages / Firebase Hosting) | CI uploads `build/web` | ⚠️ Only as a *secondary* copy (e.g. owner's phone browser) — the counter must not depend on the internet to boot the POS |

> **Note on the BeeStation:** the Synology BeeStation (where this repo syncs) is a
> consumer backup appliance — it does **not** run Docker/Container Manager. Don't
> plan containers onto it; it stays what it is: file sync for the repo.

### 3.2 Android / iOS

- **Android tablet (counter):** `flutter build apk --release`, sideload; keep the
  versioned APK next to the web build artifacts. Play Store not needed for one shop.
- **iOS:** requires an Apple Developer account ($99/yr) even for ad-hoc installs —
  decide in Phase 8b whether iOS is actually needed or the Android tablet + web
  covers the shop.

### 3.3 Supabase: cloud vs self-hosted (Docker)

Supabase *can* self-host via its official `docker-compose` (~10 containers:
Postgres, GoTrue, PostgREST, Storage, Kong…). **Decision: use Supabase cloud, not
self-host**, because:

1. Self-hosting the *backup system* on shop-owned hardware defeats the purpose —
   a fire/theft/disk failure takes the POS **and** its backups.
2. It needs an always-on x86 machine + ops (upgrades, Postgres backups, TLS).
3. The BeeStation can't run it (see above), so it'd mean buying hardware.

Self-host remains the documented escape hatch if cloud cost or PDPA data-residency
ever forces it — the app only sees URL + keys, so it's a config swap.

### 3.4 CI/CD (GitHub Actions — none exist yet; add in Phase 8a)

```
.github/workflows/ci.yaml        on: push / PR
  1. flutter pub get
  2. dart analyze                      # NEVER flutter analyze (CLAUDE.md)
  3. flutter test
  4. flutter build web --no-tree-shake-icons
  5. upload build/web as artifact      # + apk on tags
```

- CI runners have ASCII paths, so CI is also the natural place to **catch a stale
  `*.g.dart`**: run `dart run build_runner build` and fail if `git diff` is dirty.
- Release flow: git tag `vX.Y` → workflow attaches `web-build.zip` + `app-release.apk`
  to a GitHub Release → shop PC updates by unzipping over the served folder.
- Repo Dockerfile (only if option B is chosen):
  ```dockerfile
  FROM nginx:alpine
  COPY build/web /usr/share/nginx/html
  # SPA fallback: try_files $uri $uri/ /index.html
  ```

---

## 4. What this adds to the phase roadmap

| PLAN.md phase | Additions from this doc |
|---|---|
| **7a** | §2.1 project split · §2.2 auth · §2.3 bucket layout + retention · `supabase_flutter` + `--dart-define-from-file` env wiring |
| **7b** | §2.4 Postgres schema, RLS, `devices`/`sync_conflicts` tables (after the `updatedAt` prerequisite) |
| **8a** | §3.4 CI pipeline + stale-codegen check (software-only, no shop visit) |
| **8b/9** | §3.1 pick hosting option A vs B on the actual shop PC; APK sideload; retire `POS.html` |

**Open items to decide when Phase 7a starts:** Supabase account email (owner's,
not developer's) · shop PC OS + whether Docker Desktop is already installed
(decides A vs B) · whether iOS is in or out.
