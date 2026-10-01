# Srisurart Autopart POS — Flutter (Project Knowledge Base)

Flutter migration of a Thai auto-parts shop POS, ported from the React-in-browser +
localStorage app (the "Srisurart Autopart Design System" repo; origin
github.com/NuimanLP/Sri-SuRat_Store). The shipped client is **offline-first**: Drift/SQLite +
flutter_bloc + go_router. Thai-first UI with EN labels. Targets **Android/iOS + Web**.
Since 2026-09-04 `main` is the **multi-tenant client + backend + CI/CD** line (see below); the
offline-first-only build is preserved on `POC_sample_offline_first`.

> **🔒 Read first — private operating instructions (machine-local, NOT in this repo).**
> Also read these from the local toolkit folder `D:\Beestation\A_Tooling\claude-portable\`:
> - `CLAUDE.md` — global working guidelines for this machine.
> - `skills-for-claude.md` — skill-routing table (trigger → skill); invoke via the Skill tool.
>
> These live **outside** this repo on purpose and must stay private. Do **NOT** copy, paste,
> summarize, or commit their contents here — only this pointer belongs in the repo.

---

## 🌿 Branch strategy (set 2026-09-04)

The repo now carries **two lines of work**. Know which one you are on before you change anything.

| Branch | What it is | Status |
|---|---|---|
| **`main`** | **The multi-tenant line** — Flutter **client** + NestJS **backend** + **CI/CD**, per `docs/Backend_design/` (Architecture C phase 1 = A, tenancy model T1) | **Active.** All new work lands here. |
| **`POC_sample_offline_first`** | Frozen **proof-of-concept snapshot** of the offline-first, Drift-only build (branched from `main` at `4dae2f0`) | Reference only. Do not build on it. |

**What this means in practice:**
- `main` grows a **server** (NestJS + PostgreSQL + Redis + BullMQ + Nginx) and **pipelines**
  (`.github/workflows/`) alongside the existing Flutter app — it is no longer a Flutter-only repo.
- **PostgreSQL becomes the source of truth**; Drift drops to a read cache / offline shell, and the
  transactional invariants (`saveSale`, `createReturn`, `receivePO`, shifts) move **server-side**.
  The Dart repositories stay the behavioural reference for those rules — port them, don't reinvent.
- `POC_sample_offline_first` preserves the offline-first build exactly as the shop runs it today,
  so the phase-1 rule **"the shop keeps running the Drift build, no cutover"** stays testable.
- The offline-first design is **not abandoned** — it returns as **phase 2** (outbox + ~~`offlineOk`~~ — dropped 2026-09-15, see 08
  + a single `role='pos'` writer per tenant, ADR-0004). The POC branch is its starting point.

> Read `docs/Backend_design/adr/README.md` before writing backend code, and remember:
> **where a doc contradicts an ADR, the ADR wins.**

---

## ⚠️ CRITICAL — build path constraint (non-ASCII breaks codegen)

Dart's **`build_runner`** (Drift codegen) and the LSP-based **`flutter analyze`** CANNOT run
on a filesystem path containing **non-ASCII characters** (e.g. the Thai folder `ร้านศรี`) — the
AOT compiler mangles the path to `???????` and fails: *"Unable to write file …build.dart.aot"*.
A Windows junction does NOT help (build_runner canonicalizes to the real path).

What works on a non-ASCII path: `flutter create`, `pub get`, `dart analyze`, `flutter test`,
`flutter build`. What breaks: `build_runner`, `flutter analyze`.

**Consequences / rules:**
- This repo may be **stored** at `D:\Beestation\ร้านศรี\Flutter` (BeeStation sync). The
  generated `*.g.dart` files are **committed**, so it still **builds / runs / tests** there.
- To run **`build_runner`** (required after ANY change to Drift tables / `@DriftDatabase` /
  `database.dart`), first **copy or `git clone` the repo to an ASCII path** (e.g.
  `C:\srisurart_pos`), run codegen there, then commit the regenerated `*.g.dart`.
- **Always use `dart analyze`**, NEVER `flutter analyze`.
- 🔴 **BeeStation cloud placeholders break `docker build` on this checkout** (found
  2026-09-21, `docs/handoff_log/demo-rehearsal-dev-2026-09-21.md`). After a `git pull`,
  most files under `server/src/` can be dehydrated placeholders (`Attributes` =
  `Archive, ReparsePoint`), and BuildKit refuses the context with
  *`load build context: invalid file request …`*. `builder prune` does not help. Build
  from a clean git-object context instead:
  `git archive HEAD server | tar -x -C <ascii-tmp>/ctx && docker build …`, then
  `docker compose up -d` **without** `--build`. This is a *different* cause from the
  non-ASCII-path rule above, and it cannot happen on `mob04` (no build there).

### Build / test commands

### Frontend (Flutter)
```bash
cd frontend
flutter pub get
dart analyze                              # NOT flutter analyze
flutter test                              # unit + repository + smoke tests
flutter build web --no-tree-shake-icons   # web build (replaces POS.html on the shop PC)
dart run build_runner build               # ONLY after Drift schema changes — ASCII path only
```

### Backend (NestJS)
```bash
cd server
pnpm install
pnpm lint && pnpm typecheck
pnpm test
pnpm test:e2e
```

---

## Architecture (layered: data → domain → presentation)

```
frontend/
  lib/
    core/
      router/app_router.dart   ← GoRouter + AppRoutes (13 shell routes + /login). ShellRoute → AppShell.
      theme/                   ← navy/orange brand, Sarabun (Thai) + Barlow type
      utils/                   ← newId/docNo (ids.dart), baht/round2/pointsFor (money.dart),
                                 csvSafe (csv_safe.dart)
    data/
      db/tables.dart           ← 26 Drift tables, schemaVersion 13 (20 ported sa_* stores + #24's
                                 credit-payment outbox + phase-2 tables incl. OutboxOps, OpEffects) — recounted 2026-09-28
      db/database.dart         ← AppDatabase (@DriftDatabase) + seed data + AppDatabase.open()
      db/database.g.dart       ← GENERATED (committed). Regenerate ONLY on an ASCII path.
      repositories/            ← one repo per domain; transactional services mirror db.js
      repositories/api/        ← #56: ApiSales/ApiReturns/ApiShifts — same interfaces,
                                 server is the truth, Drift rows patched from the response
                                 (ADR-0010). Opt-in: --dart-define=USE_API_WRITES=true
    domain/models/aggregates.dart  ← SaleWithItems/… read aggregates + input DTOs (SaleInput…)
    presentation/
      repositories/repository_providers.dart ← flutter_bloc RepositoryProvider tree (21 entries:
                                 17 repos incl. AuthRepository, + ApiClient/BootstrapService/
                                 DocCounterSeeder/SyncFacade); `useApi` swaps in the #56 API repos
      blocs/                    ← Cubits (ThemeMode, FontScale, PendingQuote, Cart)
      screens/                  ← 14 screen files: 12 in the AppShell nav + /devices + /login
      widgets/                  ← shared UI kit + AppShell nav + sub-views (receipt, A4 quote,
                                  label printer, closing report)
    app.dart / main.dart       ← MaterialApp.router + MultiRepositoryProvider/MultiBlocProvider
  test/                        ← repo unit tests (per transactional rule) + route smoke tests
CONTRACT.md                    ← THE binding spec: tables, repo signatures, providers, routes,
                                screen→sub-view ownership, Thai-string rules. Read it first.
```

`AppDatabase.open()` uses `drift_flutter` for the app; tests use `NativeDatabase.memory()`.

---

## Data layer = a faithful port of `pos/db.js` (invariants preserved)

The legacy `pos/db.js` is the behavioural source of truth. Each repository preserves its rules,
using Drift **`transaction(() async {…})`** for atomicity (a throw rolls everything back — the
idiomatic replacement for the JS snapshot/rollback):

- **saveSale** — pre-validate stock (exact Thai `สต็อกไม่พอ…` error); strict decrement (NO
  clamp-to-0 on sale; underflow throws); `pointsGranted = (total/10).floor()`; update customer
  spend+points and mechanic stats (credit when `paymentMethod == เครดิตช่าง`).
- **createReturn** — over-refund guard (qty ≤ sold − already-refunded); proportional
  discount/points/mechanic reversal; credit-balance reduced ONLY for `หักจากเครดิต`; auto-void
  the parent sale on full return.
- **receivePO** — weighted-average cost `round2((oldQty·oldCost + newQty·newCost)/total)`.
- **openShift** — deliberately departs from db.js here (its "same day → return the open
  shift" is gone): several shifts a day (08 §11, #453). An `id` that already exists
  returns that shift unchanged; otherwise it archives the prior active shift first (even
  one opened today — never lose a day) and inserts a new one. `addDrawerEntry` blocked after close.
- **quotes / parked** never touch stock. **adjustStock** DOES clamp at 0 (manual adjustment).
- **snapshot** — `exportSnapshot()` emits the JS `sa_*` + `__meta` backup shape;
  `importLegacyBackup()` atomically imports a JS `DB.exportSnapshot()` JSON (zone→category
  migration, null-as-absent). This is the Phase-2 data-migration path.
- IDs/doc-numbers via `newId/docNo` only; CSV via `csvSafe`.
- API build (`USE_API_WRITES`) never seeds demo business data; an already-seeded DB gets a one-time `purgeDemoSeed()` (skipped while outbox ops or queued credit payments exist; deletes only untouched `updatedAt IS NULL` seed rows no local record references; AppMeta marker `demo_seed_purged`, also set by `importLegacyBackup`). The seeded settings identity persists until the first successful `GET /settings`.

---

## Migration status (Phase 0–6 complete; phase-1 backend/CI/CD built; phase-2 in progress)

**Full build log archived.** Every merged PR, bug found, and owner decision from
2026-06-24 through 2026-09-17 — the backend stand-up, all three CI/CD levels, the
phase-1 lane-A/B/C work, and the phase-2 kickoff — is preserved verbatim in
`docs/handoff_log/claude-md-full-history-archive-2026-09-17.md`. Read it for the *why*
behind any rule below, or the story of a specific PR/ticket this section only names.
What follows is current state plus the rules from that log that still bind new code.

**Done:** scaffold; data layer + unit tests; all 11 screens; shared UI kit + nav; shifts
layer; adversarial scrutiny + fix pass; web-DB runtime wired. App `dart analyze`-clean,
tests green, `flutter build web` ok. Riverpod → flutter_bloc migration done (2026-07-14,
`handoff_log/riverpod-to-bloc.md`).

**Web DB:** needs `web/sqlite3.wasm` + `web/drift_worker.js` matching the pub-locked
`sqlite3`/`drift` versions (`frontend/web/WEB_DB_ASSET_VERSIONS.txt`); CI fails the build
on any skew. 🔴 **Bumping `drift` or `sqlite3` → re-download both assets from the
matching GitHub release tags and update the version file** — a skew changes SQLite-core
or worker-cancellation behaviour, it isn't cosmetic. 🔴 **#266** (browsers without
`dedicatedWorkersInSharedWorkers` hit a `LinkError` on `xFileControl` in drift's
non-OPFS fallback): a fix (stub `xFileControl` → `SQLITE_NOTFOUND`) merged 2026-09-17
by `LomerAlloys` (`docs/handoff_log/ticket-266-web-db-linkerror.md`, PR #310), and the
GitHub issue was closed 2026-09-19 (verified 2026-09-23) — #241 (PWA precache manifest)
is no longer blocked on it.

**CouchDB was considered and rejected (2026-09-08)** — PostgreSQL stays source of truth.
Reasoning: `docs/Backend_design/adr/0012-couchdb-replaces-postgres.md` (**Rejected**).

**Backend/multi-tenant stack (set 2026-08-25):** NestJS + PostgreSQL + Redis + BullMQ +
Nginx, multi-tenant (one database, many tenants). PostgreSQL is the source of truth;
Drift is a read cache; transactional invariants live server-side, ported from the Dart
repositories (don't reinvent them). Design package: `docs/Backend_design/` —
`00_BASICS.md`/`00_INDEX.md`, `01_DATABASE.md` (schema+DDL+invariants),
`02_API_SCREENS.md` (endpoints), `03_ARCHITECTURE.md` (rollout+DoD),
`04_QA_SCRUTINY.md`, and **`adr/`** — the binding decision record. **Where a doc
contradicts an ADR, the ADR wins.** Open questions only the owner can answer are
collected at the end of `adr/README.md`. Phase-2 spec/lanes: see below.

**Where work lives:** GitHub issues, not this file. `#2` is the phase-1 program brief;
`#3/#7/#8/#9/#10` are parents (#10 closed 2026-09-30, as is its CI/CD spec #60) (no `ready-for-agent` — don't implement directly);
`#11–#13` are owner-only decisions, never settled in a PR. Phase-1 lanes: `NuimanLP`
(team/1), `LomerAlloys` (team/2), `PattaraponKitcharoen` (team/3) — every member
touches frontend, backend *and* CI/CD (course rule, 2026-09-05).

**Status:** the phase-1 backend (server, RLS, transaction/idempotency seam, all three
lanes' slices) and the frontend API-write layer (`fe.0`–`fe.3`) are merged. CI/CD levels
1–3 are done (Flutter CI, backend CI, GHCR release images with Trivy gating); level 4
(Ansible deploy to the demo VM, monitoring, etcd/`RuntimeConfigService`) is **partial**
— see "Still open". **Recount the `03_ARCHITECTURE.md §8` DoD boxes before claiming
phase 1 is "done" — this sentence has gone stale twice.** Re-verified 2026-09-22 against the tests
themselves, not against ticket state: **17 boxes, 16 ticked, 1 open.** The one still open is
the k6 box (→ **#380**). The retire/enrol box closed 2026-09-22 — **#384**
(`server/test/shifts.e2e-spec.ts:562`) now exchanges a real `enrolCode` through
`POST /auth/device` and logs in via `POST /auth/token` instead of minting a token, plus a
stock-before/after assertion on the replacement sale. The `redis-cache` outage box also closed
2026-09-22 — **#383** (`server/test/redis-cache-outage.e2e-spec.ts`) makes `redis-cache`
genuinely unreachable two ways (refused connection, and open-but-silent until `commandTimeout`
— the #140 case) and proves `GET /products` + `POST /sales` (stock actually decremented) still
work for an active tenant while a `suspended` one is refused at once; the old evidence it
replaces (`tenant-scope.e2e-spec.ts:186`, removed in the same PR) only `vi.spyOn`'d the cache
client's methods instead of making `redis-cache` unreachable, and asserted against
`/api/v1/tx4-probe` rather than the `GET /products` + `POST /sales` that #294's own AC demands.
Neither #294 nor #296 was reopened — each did deliver a real part. 🔴 The six boxes labelled
"#196 2026-09-17" rest on merged PR #306, **not** on
#292–#296, which were closed by hand with no PR attached — never use that set to tick a
`§8` box. No cutover: the shop still runs the Drift build; the server
develops against a demo tenant.

**Still open (phase 1):**
- ~~CD to the demo VM blocked by the faculty FortiGate~~ — **resolved 2026-09-29/30**:
  `mob04` pulls from `ghcr.io` (the FortiGate cert now carries the SAN). If
  `x509: certificate is not valid for any names` returns, the block is back — fix is the
  network team exempting `ghcr.io`/`registry-1.docker.io`/`gcr.io` for `172.30.58.20`;
  `docker save`/`load` by hand is a demo-day rescue, **not** CD. Original evidence:
  `docs/handoff_log/handoff_demo-335-merge-and-cd-blocked_21_09_2026.md`.
- ~~#67~~ (**closed 2026-09-30, 15/15** — kept here for the rules below) — self-hosted deploy runner: 🔴 **installed 2026-09-30** (`mob04-demo`, service user
  `gha-runner`, via `setup-mob04-runner.sh`; `gh api …/actions/runners` = 1, online) and the
  **first real deploy ran**: `Deploy (demo)` for `e50f4fa`, approved by `NuimanLP`, Ansible
  `failed=0`, `.current_sha` = `e50f4fa`, `/health/ready` 200
  (`docs/handoff_log/session-2026-09-30-first-runner-deploy.md`). Afternoon: merge→CD proven
  on `494ace3` (run `36685602814`), `workflow_dispatch` rollback to `e50f4fa` proven (run
  `36687687309`, schema unchanged), same-SHA rerun = "Skipping duplicate deployment"
  (`36688248109`). **#67 closed 15/15 2026-09-30 evening (evidence comment 5912257527, closing comment 5913430909):** one-image-only → skip, no concurrent deploys (a job *waiting for approval* already holds the `deploy-demo` slot), `log_level` seeded when missing and a hand-set value survives, failing readiness → red run + auto-rollback by `pos-deploy` re-running the old release (run `36720675552`; not an Ansible `rescue:`), hook refuses a non-`main` branch (run `36721404240`). The fork half of the hook AC was proven from code + settings only, owner-accepted, **no real fork run** (comment 5913430909): the `demo` environment has a `main`-only branch policy and fork-PR
  approval is `all_external_contributors` (owner-approved 2026-09-30). A same-SHA `workflow_dispatch` (with `.env` unchanged) exits before etcd-init and `deploy.yml` has no force input, so re-testing `log_level` seeding needs a real SHA change. Still verify with
  `.current_sha` before claiming a deploy — a green run alone proves nothing (below).
- **#380** — the three-laptop k6 + container-RSS run (`PattaraponKitcharoen`, lane C).
  Nothing in it is measured yet. It replaces **#184**, which was closed→reopened→closed
  three times in two days and finally closed by the owner on 2026-09-21 with all four ACs
  unticked; **do not reopen #184** (owner decision 2026-09-22). PR #357's `Closes #184`
  shipped tooling + a runbook and no measurement at all — never read that PR as evidence.
  **#251 is closed (2026-09-22): the *method* is settled, the *measurement* is not.**
  The method is `03_ARCHITECTURE.md §8.1`, decided 2026-09-15 and re-confirmed 2026-09-22:
  three machines each under their own `perip`, results streamed to the VM's Prometheus over
  remote-write. 🔴 **Exempting the load-generator IP from `perip` was considered and
  explicitly rejected** — never add that carve-out to `nginx.conf` without asking the owner.
  The `§8` k6 DoD box stays unticked until #380 produces real numbers.
- **Auditing tickets? `closedByPullRequestsReferences` lies here.** GitHub links no PR at
  all when the PR carries no closing keyword — **93 of this repo's 201 merged PRs** are like
  that — and it never reads a keyword placed in the PR **title** (4 more: #328/#329/#332).
  PR **#306** is the engine behind #293/#294/#296 and part of #292 yet cites only `#196`.
  Cross-check with `git log --all --grep` before concluding that nothing shipped (#345,
  2026-09-22).
- ~~#343~~ / #344 — the first real deploy to `mob04` and the end-to-end demo run. **#343
  closed 2026-09-30 (5/5)** — deploy, Grafana checked, manual-Ansible rollback to `e50f4fa`
  `failed=0`, command log in the 2026-09-30 handoff (PR #511/#514). **#344 has not been run**; its
  checklist is `docs/handoff_log/demo-344-checklist-2026-09-30.md`, with flagged blockers
  (temp-password + forced change within 10 min, new tenant has no products, the app cannot
  resend an idempotency key, three #335 ACs not provable on the VM, #476). 2026-09-30
  `provision.yml` re-run added only `PLATFORM_ADMINS` (3 admins synced, no human has logged
  in to platform-ui) and installed the missing `backup-db.sh`. 🔴 Correction: on 2026-09-29
  03:00 the script existed and **failed** ("Neither active docker compose postgres container…",
  leaving a 20-byte empty `.gz`); only the 2026-09-30 03:00 run was "not found". #346 closed
  2026-09-30 (script run in cron env OK, dump verified, comment 5913495869); first real 03:00
  cron run is 2026-10-01 — check `backup-cron.log`. PR #519 (`b089f36`): `backup-db.sh` writes
  `$BACKUP_FILE.partial` and `mv`s on success, an EXIT trap removes it, prune drops stale
  `.partial` by age; test `deploy/scripts/test/backup-db.test.sh` runs in `server.yml`
  `nginx-check`. 🔴 **Only `provision.yml` installs `/opt/pos/scripts` — a CD deploy does NOT
  update `backup-db.sh` on the VM.** ~~#519's script is **not yet installed on `mob04`** (VPN
  dropped)~~ — **installed and verified 2026-09-30 (late):** `sudo install -o deploy -g deploy -m 0755`
  from `origin/main`, sha256 `fa65dbd5…` matches, previous copy kept as
  `/opt/pos/scripts/.backup-db.sh.prev-be9e7f3`; one run in cron's env (`env -i`, cwd
  `/home/deploy`) → rc=0, 9580-byte `.sql.gz`, `gzip -t` ok, sha256 sidecar OK, no `.partial`, offsite
  `::warning::` as expected (#363 parked). First real 03:00 cron run with it is still 2026-10-01. A foreign `Origin`
  used to get **HTTP 500** (`app.setup.ts` threw; not counted in `http_requests_total`) —
  fixed by PR #516 (`callback(null,false)`: request served, no ACAO header), deployed to
  `mob04` as `00d3488` 2026-09-30 (run `36717963989`, Ansible `failed=0`).
- ~~#272 — drop `Products.offlineOk` (Drift schema v7)~~ — **done**: merged via PR #310
  (commit `8faebac`), issue closed 2026-09-19. Drift is now at schema v13 (v12 = #417 indexes; v13 = #488
  `op_effects`: the deltas an offline sale/return/void actually applied, so discard reverses
  exactly — ops queued before v13 have no row and take the legacy recompute path).
- ~~Two real bugs in migration `1788652803002-OwnerReviewItems.ts`~~ — **fixed 2026-09-25**
  by the new migration `1788652804200-OwnerReviewItemsFixes.ts`, proven in
  `server/test/schema.e2e-spec.ts` (found 2026-09-23, `01_DATABASE.md §11`): (1) its RLS
  policy cast `current_setting('app.tenant_id', true)::uuid` without `NULLIF(…,'')` — an
  emptied tenant gave 22P02 → HTTP 500 instead of 0 rows; now `tenant_isolation` with
  `NULLIF` like every other table; (2) `FOREIGN KEY (tenant_id, reviewed_by) … ON DELETE
  SET NULL` also nulled the NOT NULL `tenant_id`; now `ON DELETE SET NULL (reviewed_by)`.
  Applied migrations are never edited (commit `225ecf7` edited `InitialSchema.ts` once).
- ~~Two HIGH phase-2 bugs found by the 2026-09-24 whole-codebase review~~ — **fixed
  2026-09-25**: the `/sync/push` fingerprint mismatch (`POST /sales` vs
  `POST /api/v1/sales`) by PR #413 (#409), and online routes storing the client body's
  `date` instead of server `now()` by PR #414 (#411). The same review log (`docs/handoff_log/session-2026-09-24-whole-codebase-review.md`
  §2) also lists 3 MED + 1 LOW spec gaps and the standards findings (e.g. unvalidated `Math.max`
  clamp in `quotes.controller.ts:113` — fixed 2026-09-25 by PR #420, now validated by
  `parsePurgeOlderThanDays`). **All three MED items are fixed (2026-09-27):** item 3 by
  PR #458 (#455), item 5 by PR #456 (#453), item 4 by PR #456 + PR #469 (#452 closed).
  Still open: item 6 (LOW — online `POST /shifts/open` with an existing `id` ignores
  `startingCash`, `shifts.service.ts:190-198`) and the standards findings (§3) beyond the
  `Math.max` one, none re-triaged.
- **5xx does not queue — owner decision 2026-09-27, `08 §5` amended (PR #469).** On the
  API build a 5xx/429 leaves the attempt parked (same id + key) and shows the error, for
  sales, shifts and returns alike; only a transport failure queues to the outbox.
- **Bugs filed 2026-09-27 are all closed:** #460 by PR #467, #461/#464 by PR #468 (owner
  chose: add the `เครดิตช่าง` row; take quote validity from Settings), #462/#463/#465 by
  PR #470, #452 by PR #469. 🔴 **Three Thai strings from those PRs are still `agent ร่าง`**
  — `เปิดกะใหม่` (#469), the 8-character enrol-code wording (#470,
  `devices_screen.dart:869`, `device_enrolment_dialog.dart:97`), and the post-enrol banner
  (#470, `login_form.dart:188`); all three are in `02 §8.1.1` for the owner to ratify.
- **Follow-ups filed 2026-09-28** (verified in code, table in
  `docs/handoff_log/session-2026-09-28-overnight-bug-sweep.md` §2) — **all closed same
  day except #476:** ~~#472 offline RC numbering guessed `deviceNo ?? 1` and fell back to
  `docNo('RC')`~~ fixed by PR #484 (`DocNumberService.issueOffline`, same rule #469 gave
  CN) · ~~#473 discarding a `sale.create`/`return.create` did not undo local
  stock/ledger~~ fixed by PR #483 (reverses stock/customer/mechanic/void inside the
  discard transaction; refuses `DISCARD_HAS_LOCAL_DEPENDENTS` when the bill already has a
  local return/void) · ~~#474 settings were not re-pulled when the link returns~~ fixed by
  PR #486 · ~~#475 a new device with no counter rows could not number an offline CN~~
  fixed by PR #484 (seeder writes a `last_no = 0` row) · #476 device-management dead end
  after the last enrolled browser is lost — **still open, owner call** · ~~#477 reports
  `_RecentRow` overflow at 390 px~~ / ~~#478 vehicle-search highlight hid the match~~ /
  ~~#480 shelf labels hard-coded `รวม VAT 7%`~~ all fixed by PR #485 · ~~#479 A4 quote PDF
  detached Thai tone marks~~ fixed by PR #482 (`latinOnlySpacing`, no `letterSpacing` on
  Thai text).
- **#489/#490 fixed 2026-09-28** (PR #491, PR #492) — an online-issued `receiptNo`/`cnNo`
  was never written to the local `DocCounters`, so an offline sale/CN after an online one
  could reissue a number the server had already given out. **Rule: any RC/CN number the
  server issues — the online reply *and* a `/sync/push` replay — must be committed into the
  local `DocCounters` via `DocNumberService.commitServerIssued`** before offline issuing can
  trust its own high-water mark (offline issuing depends on it) — `ApiSalesRepository
  ._patchFromResponse` and `ApiReturnsRepository`'s equivalent do this today. 🔴 **The
  `/sync/push` replay half of that rule (`SyncService._patchDocNo`) was pushed as commit
  `dbaa7e5` *after* PR #491/#492 had already merged, so it never reached `main` from those
  two PRs** — verified 2026-09-28 by diffing `main` against `dbaa7e5`: `sync_service.dart`
  on `main` had no reference to `DocNumberService` at all. Cherry-picked into **PR #494**
  (`fix/489-push-replay-counter`, open, not merged) — its own replay tests fail without the
  commit. 🔴 **Lesson: check a PR's head SHA at merge time
  (`gh pr view N --json headRefOid`) — a review-fix pushed after the merge button is
  clicked silently misses `main`, and the PR body describing it reads as done when it
  isn't.** 🔴 **Same trap on the branch side (found 2026-09-30):** before deleting a
  merged-PR branch, compare its tip with the PR's `headRefOid` — a mismatch means commits
  pushed after the merge that may exist nowhere else. That is how PR #486's review fix
  (`_writeGen` guard against a stale `GET /settings` clobbering a newer `PATCH`, commits
  `47653b1`/`c57019a`, pushed after the 2026-09-28 01:21:43Z merge) was found and recovered by PR #521
  (`ca2fef1`). This unblocked #490: `ensureSeedMarker`
  now accepts a seed from **any** period, so an offline sale after a month rollover starts
  at `0001` instead of refusing with
  `ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์` (08 §9 E8).
  #488 (discard exactness / `void_offline` follow-up) is open.
- **Postgres has 29 tables** (27 from `InitialSchema` + `import_jobs` + `owner_review_items`;
  `change_log` never built). `docs/Backend_design/` was re-synced to the migrations, code and
  ADRs on 2026-09-23 (PR #390) — **the migrations are the schema's source of truth**, the
  DDL in `01_DATABASE.md` is illustration.
- Opened 2026-09-21 from verified findings. **#364, #366 and #367 were closed the same
  day (PRs #374 / #371 / #373); #365 closed 2026-09-30; #363 is still open.**
  - **#363** — `backup-db.sh` never copied a backup off the VM although #288's AC for it
    is still `[ ]` on a reopened ticket (#288 was **reopened 2026-09-21** by the owner).
    🔴 **Mechanism built same day, not wired**:
    `backup-db.sh` gained a pluggable `offsite_upload()` via `rclone`
    (`BACKUP_RCLONE_REMOTE`/`BACKUP_RCLONE_CONFIG`, unset = disabled), proven only against
    a local stub/fake destination — see `docs/handoff_log/ticket-363-backup-offsite.md`.
    🔴 **Offsite upload is OPTIONAL (owner decision, 2026-09-21 — this replaces the
    behaviour PR #372 shipped):** `BACKUP_RCLONE_REMOTE` unset/empty → one `::warning::`
    line and **exit 0**, so the nightly cron on `mob04` is quiet-but-honest instead of
    failing every night until credentials exist; **configured but broken** (no `rclone`,
    missing `BACKUP_RCLONE_CONFIG`, failed `copyto`) → unchanged loud `::error::` +
    **non-zero exit**, because a configured destination that silently fails is the exact
    bug #363 exists for. A green `backup-cron.log` therefore does **not** prove a backup
    left the VM — read the `::warning::`/`::error::` lines. Once offsite is configured,
    local prune deletes a dump only after its `.uploaded` marker confirms the offsite
    copy (unconfirmed dumps are kept with a `::warning::`); while it stays unconfigured
    prune is age-based as before this ticket, so an indefinite "not wired yet" period
    does not fill the disk. **Still open, real infra required — do not claim
    done:** no real upload has ever left a VM (AC2), no restore from an offsite copy has
    been proven (AC3), `rclone` is not installed on `mob04`. #288's "backups leave the VM
    daily" AC is still unticked; #288 is reopened and the correction is recorded in its
    comments. **Destination decided 2026-09-22: the shop's own NAS, not a cloud provider**
    — a cloud target would have to cross the same FortiGate (which broke `ghcr.io` until 2026-09-29).
    🔴 **The protocol is NOT settled: SFTP was chosen, then research killed it** —
    a Synology **BeeStation runs BSM, not DSM, and exposes no usable SSH/SFTP** (its only
    SSH surface is a 14-day Synology-support diagnostic channel). Either use rclone's
    `smb` backend against the BeeStation, or buy a DSM-based (DS-series) NAS for SFTP.
    Evidence, both example configs, and the still-unverified network questions:
    `docs/handoff_log/research-363-sftp-nas-offsite.md`. AC1 (destination **and**
    credentials) stays unticked until a protocol is picked and creds exist.
    🔴 **PARKED until after the `mob04` demo (owner, 2026-09-22).** #363/#288 are both
    still open but `ready-for-agent` was removed from #288 — do not start this work; #344
    (the demo) comes first (#343 closed 2026-09-30). The cost is accepted knowingly: **no backup leaves the VM at all
    meanwhile**, so a dead `mob04` disk loses the demo tenant. Never write "backups are
    ready" anywhere while this is parked.
    **First-run rule (owner, 2026-09-22):** dumps written while offsite was unconfigured
    have no `.uploaded` marker and prune keeps them forever by design — on the day offsite
    is switched on, upload the backlog **by hand once**, then let prune resume. No
    auto-backfill logic goes into `backup-db.sh` for a one-time event.
    **Assigned to all three members 2026-09-22** (both #363 and #288, which had one
    assignee each) — that is ownership for when the work resumes, **not** a signal to
    start. Split of labour when it does resume: **#363 owns the whole offsite path**
    (pick the protocol → prove the network route → credentials → install `rclone` →
    first real upload → restore from the off-VM copy); **#288 is the parent** and only
    closes afterwards, against #363's evidence. 🔴 Test the network route from `mob04`
    to the shop **before** creating any credential — it is still unverified and it is a
    bigger unknown than the protocol.
  - **#364** (closed, PR #374) — `ownerPassword` had no server-side length rule while
    `bootstrap:admin` demanded 12. The floor now lives once in `src/common/password.ts`
    (`MIN_PASSWORD_LENGTH`/`passwordPolicyViolation`), both callers use it, and
    `createTenant` refuses with `WEAK_PASSWORD` **before** `hashPassword` and before the
    transaction opens (argon2 also moved out of the transaction). The Thai string for
    `WEAK_PASSWORD` in `02_API_SCREENS.md §8`/`§8.1` was **ratified by the owner on
    2026-09-21** — the `agent ร่าง` marker is gone.
  - **#365** (closed 2026-09-30, 4/4) — `etcd-init.sh` on the VM was a root-owned *directory*, so etcd had no auth.
    **Fixed 2026-09-30:** auth on since the first runner deploy, proven both ways, `.env`
    password matches the volume, `RuntimeConfigService` reads `log_level`, snapshot in
    `/opt/pos/backups/`. Command log in the 2026-09-30 handoff (PR #511/#514).
    🔴 A password mismatch between `.env` and the `etcd-data` volume surfaces as "the
    service is not green", never as a message about a password; never `down -v`.
  - **#366** (closed, PR #371) — owner picked option 3 2026-09-21: auto-deploy stays,
    gated by a required reviewer on the `demo` environment. See the binding CI/CD rule
    below.
  - **#367** (closed, PR #373) — `CORS_ORIGINS`/`PLATFORM_ADMIN_IPS` now reach the
    containers via the `x-app-env` anchor, and a set-but-empty list throws at boot instead
    of silently falling back to `'*'`. `mob04` is **not** `'*'`: its `.env` already had
    `CORS_ORIGINS=https://172.30.58.20` at the first runner deploy (verified 2026-09-30 —
    own origin gets ACAO, a foreign one does not).
- Phase-2 kickoff order for the remaining hub tickets: #228 → #229 → #212/#211/#189 →
  #230 → #190 → #231. As of 2026-09-25 all but **#231** (q4.cutover) are closed
  (2026-09-18 → 09-20); #231 is the only one still open.
- **Found by the study-pack review (PR #397), 2026-09-25 — all fixed same day:**
  #398 (`JWT_PLATFORM_SECRET` falls back to a public dev value) by PR #407, #399
  (`pos_app` can UPDATE/DELETE `audit_log` — should be append-only) by PR #406, #401
  (compose images not digest-pinned) by PR #403, #402 (closing report profit uses
  current cost, not `costAtSale` — ADR-0008) by PR #408, and **#400** (Flutter Web kept
  the access token in `localStorage`, against ADR-0009) by PR #404 + commit `68a6c2d`
  (issue closed 2026-09-25, verified 2026-09-27). The owner decision it waited on is
  recorded as the **ADR-0009 addendum 2026-09-25**: web access token in memory only,
  refresh/device token in IndexedDB, **no localStorage fallback** — if IndexedDB fails
  the user reloads; tokens a legacy build left in localStorage are migrated once
  (write, read back, then delete). Never reintroduce a localStorage fallback.
- **#443 `platform.admin-ui` — code merged 2026-09-27, issue still open.** Platform CLI
  (#445), enrolCode reissue + tenant detail (#446), owner temp password + forced change
  (#447, migration `1788652804500`; `POST /platform/tenants` now **rejects**
  `ownerPassword`), web dashboard `platform-ui` on `127.0.0.1:3200` (#448), phone-width fix
  + tutorial (#450). 403-at-both-layers proven on `mob04` 2026-09-30 (comment 5913452241). Open: the AC
  "only `bootstrap:admin` creates admins" contradicts the owner-ratified `PLATFORM_ADMINS` sync, and owner answers listed in
  `docs/handoff_log/session-2026-09-27-platform-admin-ui-443.md` §6. Container runs on `mob04`
  since the 2026-09-30 deploy; 3 platform admins synced from `PLATFORM_ADMINS` the same day
  (UI login not yet tested by a human).

The repo's only long-lived branches are `main` and `POC_sample_offline_first`. Enforced
2026-09-22: 44 stale remote branches and every local agent worktree were deleted, leaving
exactly those two. **Re-done 2026-09-30:** 35 merged remote branches deleted after checking
each (ancestor of `main`, or PR MERGED with tip == PR head, or post-merge commits patch-id-equivalent on `main`);
only `main` + `POC_sample_offline_first` remain. 🔴 **Before deleting a branch, check it is actually merged** — two
branches (`research/production-host`, `research/pwa-offline-shell`) held the only copy of
`docs/research/*.md` (424 lines, closed tickets #241/#242 whose closing comments linked
straight at the files), had **no PR at all**, and would have been destroyed silently.
`git merge-base --is-ancestor <branch> origin/main` per branch is the check;
`git log --all --diff-filter=A -- '<path>'` is how to prove a file exists nowhere else.
Both docs were merged to `main` first (PR #386) with a banner saying what has since
overridden them — **`production-host.md` recommends a cloud host the owner decided
against on 2026-09-15**; it is kept only because #242's own closing comment says to keep
it as input for the future outside-campus phase.

**#243 (the phase-2 wayfinder map) was closed 2026-09-22** after checking each of its own
"not yet specified" items: lane split ✅ (`09_PHASE2_LANES.md`), Thai phase-2 copy ✅
(#268 → PR #305), and every phase-2 slice ticket it points at is closed except #288. Its
third item — load-time RAM of the full stack on `mob04` — says "measured in #184" and
**was never measured**; that gap lives on **#380** now, not on a map.

---

### Binding rules from the phase-1 build (still enforced — read before touching the named area)

**Transactions & tenancy (`server/src/common/`, `TenantService`):**
- The transaction lives in the request **handler**, never in middleware/guard/
  interceptor (ADR-0003 amendment, **Accepted**, in force since `tx.4`).
  `TenantService.runTx(fn)` takes **no tenant-id argument** — that's what makes it safe;
  never reintroduce a `runTx(tid, fn)` signature.
- **No component may take a second pool connection inside one request.** A global guard
  reading `tenants.plan` on a cold cache did this once and deadlocked the pool at
  `DB_POOL_SIZE` concurrent requests (#162). `Promise.all([runTx(a), runTx(b)])` has the
  same shape — fold sibling calls into one `runTx`.
- A void's manager-PIN check runs **ahead of** `runIdempotent`, outside any transaction
  (argon2 is slow); a resent `Idempotency-Key` no longer skips PIN verification.
- Three architecture specs gate this seam — `tenant-door.spec.ts`, `tenant-wrapper.spec.ts`,
  `idempotency-routes.spec.ts` — change them deliberately, never just to turn them green.
  A new write route with no idempotency claim at all is invisible to all three.
- A 25 s **commit-ceiling guard** in `runTx`/`TenantJobRunner` rolls back and throws
  `CommitCeilingExceededError` before `COMMIT`; `pos_app` also gets
  `statement_timeout=25s`. Never set `statement_timeout` ≤ `CLAIM_LOCK_TIMEOUT` (it makes
  `503 IDEMPOTENCY_KEY_IN_FLIGHT` unreachable). A pool holder writing a table clients pull
  by `updated_at` must commit through the guard (tenant export is the only opt-out).

**Lock order (money/stock writes):** `sales` → mechanic → products → `doc_counters` →
customer, with a `shifts` `FOR SHARE` read inserted between the sale and mechanic locks
on void/return paths. Keep this order in any new write touching more than one of these.

**Idempotency & the client write path (`server/src/idempotency/`, `frontend/lib/data/repositories/api*`):**
- The idempotency fingerprint is the **concrete request path**, never `req.route.path`
  (the pattern) — a reused key on two different bills must not collide.
- Only a **4xx is a verdict** (`isVerdict`); a 5xx, a 429, or a lost/timed-out reply
  means the write's fate is unknown — never fall back to a local write on anything but a
  genuine transport failure (`ApiTimeoutException` included). `api_repository_contract_test.dart`
  enforces this over both `data/repositories/api/` and `data/repositories/api_*.dart`.
- An `ApiRepository` never calls a Drift transactional service (double stock decrement).
- An `ApiException` must never reach a screen — convert via `rethrowThai` /
  `rethrowServerRefusal` to a plain Thai-string `Exception`/`PosException`.
- The bill id and `Idempotency-Key` are minted **once per cart**, not once per call
  (`PendingWrites` parks the attempt); a fresh id+key on retry defeats both server
  defences and double-rings the sale.
- Consent (e.g. `overrideCreditLimit`) is carried explicitly from a dialog the counter
  was actually shown — never inferred by re-running a stale local check.
- Money crosses the wire as the string `"1234.50"`; a field the response omits leaves
  its row alone — the online customer/mechanic patch and the `/sync/push` reply patch
  share `patchCustomerAfter`/`patchMechanicAfter` (`api_wire.dart`, #455) for this.
- **Closing a shift needs the whole outbox empty** (08 §11, #456): `ApiShiftsRepository.closeShift`
  first sends what it can (the outbox via `SyncService` when wired, else only queued credit
  payments), then refuses with `OUTBOX_NOT_EMPTY` while **any** `outbox_ops`
  row remains — `pending`, `stuck` or `rejected`, of any type — and the close button is
  disabled while `outboxRemaining > 0`. The server cannot see the outbox, so this check is
  client-only; never narrow it back to one op type (it replaced the cash-credit-only
  `CASH_CREDIT_PAYMENTS_UNSENT`). Its Thai string was ratified by the owner 2026-09-27.
- **Expected drawer cash has one counting window** (#452, PR #469): the cash-drawer
  screen and the closing report's drawer check both use `ShiftsRepository.cashCountFrom(shift)`
  — the first shift of a day counts from midnight, a later shift from its own opening —
  and both count a credit payment only when `isCashCreditPayment()`. Never compute
  expected cash a second way; the report's revenue/payment/top-item sections stay whole-day.
- **Returns share one pure rule set:** `planReturn()` + `refundedQtyOf()`
  (`return_plan.dart`) are used by both `ReturnsRepository` and `ApiReturnsRepository`;
  the offline `return.create` numbers its CN inside the local transaction, after every
  guard, and refuses `OFFLINE_SEED_REQUIRED` rather than guess a `device_no` (#469).
- **Settings writes are online-only on the API build** (#460, PR #467):
  `ApiSettingsRepository.updateSettings` is `PATCH /settings` with an `Idempotency-Key`,
  refuses when Degraded, and writes Drift **only** from the server's accepted reply —
  never a local-first write, never on a failure; `pullFromServer` (`GET
  /settings`) runs on app open/login and again from `triggerEntityPull`
  (`SyncService.onPull`) on reconnect (#474, fixed).
  🔴 **Do not wire `BootstrapService.bootstrap()` as it stands** — its product upsert
  skips the pending-outbox stock guard (08 §15), nulls `zone`, and its settings mapping
  reads `shopNameEN` where the server sends `shopNameEn` and ignores `quoteValidDays`
  (the `bootstrap_service.dart` header names the stock guard; all three are in PR #467's
  body).

**CI/CD (`.github/workflows/`, `deploy/`):**
- Both `flutter.yml` and `server.yml` trigger unfiltered on every push/PR; a `changes`
  job gates each workflow's own jobs internally so a `server/`-only PR still runs (and
  can satisfy) the Flutter required check, and vice versa. Each workflow ends in one
  always-reported status job (`flutter-ci-status`/`server-ci-status`) — the only
  required checks on `main`. `concurrency.group` is keyed by commit SHA.
- Branch protection on `main` has been set since 2026-09-15: PR required (0 approvals),
  the two status jobs required, no force-push/delete, admins not enforced.
- Base image digests are pinned and bumped by hand, never suppressed with `.trivyignore`.
- **Secret scan = gitleaks** (job `secrets` in `server.yml`, 2026-10-01): never path-gated,
  scans the commits each PR/push adds (`-v --redact`), and `server-ci-status` requires its
  `success`. Allowlists live in `.gitleaks.toml` (placeholder patterns) and
  `.gitleaksignore` (reviewed fingerprints). **Never allowlist a real secret — rotate it**
  (history is not rewritten). On a PR, CI reads both files from the **base** commit, so an
  allowlist change takes effect **only after it merges** — land it in its own PR first.
  Inline `gitleaks:allow` is ignored. Details: `07_CICD_DEPLOY.md §2a`.
  GitHub secret scanning + **push protection are ON since 2026-10-01** (verify with
  `gh api repos/NuimanLP/srisurart-pos-flutter --jq .security_and_analysis`; ADR-0013 once claimed
  "on" while off); Dependabot security updates are still disabled.
- `.github/dependabot.yml` is security-updates-only — routine bumps are human-timed.
- Never `docker compose down -v` on a shared Docker daemon (wiped another session's dev
  volumes once); throwaway stacks use a unique `-p`.
- **`demo` environment requires a manual approval before `deploy.yml`'s `deploy` job
  touches the VM** (#366, 2026-09-21 — ADR-0013 addendum, option 3). Auto-trigger on
  every green `main` is unchanged; the job enters GitHub's "Waiting for review" state
  and is never handed to a runner until the required reviewer (`NuimanLP`) approves —
  that is the entire mechanism for keeping a merge off the VM mid-demo. This is a live
  repo-settings change (`gh api …/environments/demo`), not just documentation — verify
  with `gh api repos/NuimanLP/srisurart-pos-flutter/environments/demo --jq '.protection_rules'`
  before assuming it's still on. Reconciles #335 D9 (manual Ansible) as the documented
  fallback for when the #67 runner is offline, not a competing trigger policy.
- **A red `server-ci-status` on `main` = no images on GHCR = every Deploy run skips while
  reporting success** (2026-09-30: `pnpm audit --audit-level=high` blocked every deploy
  until PR #512). An ~8 s green run after a merge can mean this, not only "docs-only".
- **Tests must not hardcode the current month** (2026-10-01, PR #525): `sync-push.e2e-spec.ts` used
  `RC01-2569-09-…` with a server-stamped `now()` date, so on the 1st of the next month the server
  (correctly, 08 §10) added a `date_flag` and `main` went red — which also means no images and
  every Deploy run skipping. Derive RC/CN periods from now in `Asia/Bangkok` (`currentPeriod()`).
- **Cancel stale waiting Deploy runs before approving a newer one** — a job waiting for approval holds
  the `deploy-demo` slot and the newer run sits `pending`; the approval API needs a `comment`.
- **A green `Deploy (demo)` run is not evidence that anything was deployed.** Its
  `deploy` job is gated on `needs.resolve.outputs.images_ready == 'true'`, so when the
  images for that SHA are not on GHCR yet the job is skipped and the workflow still
  reports *success* with only `resolve release` having run. The VM's `/opt/pos/.current_sha`
  is the only proof.
- **Never `gh pr merge --delete-branch` on a stacked PR.** Deleting a branch that is
  another PR's base makes GitHub close that PR, and a closed PR's base cannot be
  changed — recovery is push the old tip back, `gh pr reopen`, `gh pr edit --base main`.
  Clean up branches once, after the whole stack has landed.
- **Retarget a stacked PR to `main` once its base PR has merged, before merging it.**
  #447 was merged into PR2's already-merged branch, so its code reached `main` only
  because #448 happened to contain it.
- **`ansible-playbook deploy.yml --check` proves almost nothing.** `ansible.builtin.command`
  has no check mode, so it is skipped and the network pre-flight assertion then fails on
  an empty `stdout` — a false positive that reads like a disaster. It also never reaches
  any task past the first `command`. Never cite a `--check` run as evidence.
- `deploy.yml` and `provision.yml` need **different SSH users and are not interchangeable**:
  `deploy.yml` runs as `deploy` (owns `/opt/pos`, in group `docker`, **no sudo**),
  `provision.yml` as `cloud` (has sudo, **not** in group `docker`, cannot write
  `/opt/pos`). `--check` hides this because `copy` compares checksums without writing.
- Never pass `--diff` to `provision.yml` — it prints the whole `/opt/pos/.env`.
- When editing a `.env` by hand, anchor every check with `^` (`grep -c KEY` counts lines
  *containing* the name, so a key glued onto the previous line by a missing trailing
  newline looks present while Compose still reports it missing) and append a blank line
  first. `pgdata`/`etcd-data`/`nginx-auth` bake their secrets in at first bootstrap only:
  changing those passwords in `.env` does not re-key an existing volume, and re-keying is
  a separate owner decision, never an improvised step.
- **Dev `server/.env` needs `ALLOW_DEV_SECRETS=true`** (#410/PR #412, 2026-09-25) — without
  it the api/worker/bull-board refuse to boot on a `dev-only-*` placeholder secret or the
  public dummy JWT pair. **Never set it on a real host** — `vm.override.yml` forces it
  empty on `mob04`.

**Metrics (`server/src/metrics/`, `deploy/prometheus/`, `deploy/grafana/`) — landed 2026-09-21:**
- `http_requests_total` and `http_request_duration_seconds` are **named by the existing
  Grafana panel expressions** — renaming either silently blanks the dashboard.
- The counting happens in **middleware**, not an interceptor, because requests a guard
  rejects (401/429) must still be counted, and `route` must be the pattern, not the
  concrete path. `GET /metrics` returns text format and is **not** wrapped in the
  envelope; Nginx answers `location = /metrics` with 404 (exactly `=`, not `^~`, which
  would also block any future path merely starting with `/metrics`).
- `/metrics`, `/health/live` and `/health/ready` are **excluded from the SLI**
  (`UNMEASURED_PATHS`). Owner-approved 2026-09-21 as an addendum to #335 D6: scrape every
  15 s × 3 instances plus healthchecks manufactures ~36 guaranteed `200`s a minute, and
  the success-rate and p95 panels average every series, so a day where every real bill
  failed would still read ~92% healthy.
- `pos_idempotency_replay_total` carries **no `tenant_id` label** (panels use
  `sum()`/`increase()`), and is incremented **only inside `onTransactionCommit`** in the
  replay branch, so a rolled-back write is never counted. `MetricsService` is a
  **required** dependency of `IdempotencyService` — if that wiring is ever loosened back
  to `@Optional()`, a broken graph silently zeroes the counter instead of failing at
  bootstrap.

**Nginx / auth / rate limiting:**
- Nginx must be the only reverse proxy in front of the API — `trust proxy` is exactly
  `1` and `clientIp()` reads the rightmost `X-Forwarded-For` entry; a second proxy or
  CDN in front collapses every client onto one rate-limit bucket.
- Login throttles **before** it spends a DB connection and counts **before** it knows
  the outcome (one atomic Lua `INCR`); every refusal counts, a success only refunds its
  own IP attempt.
- An e2e file that logs in more than 10 times must send its own `X-Forwarded-For` per
  login (as `devices.e2e-spec.ts` does): the per-IP login bucket is 10/60 s and lives in
  the Redis every e2e file shares, so a fixed IP turns red by run order (#449).
- `platform-ui` reaches the API as `172.30.0.20`; that IP, the `allow` line in
  `nginx.conf` and `PLATFORM_ADMIN_IPS` change together or the UI gets a silent 403 —
  `07_CICD_DEPLOY.md` row "ดู platform-ui".
- Password verify is **NFC first, raw form as fallback** (`auth.service.ts`): NFC reorders
  Thai tone/below-vowel marks, and hashes made before #443 are of the raw string —
  dropping the fallback locks those owners out.

**Catalogue/sync (`server/src/products/`):**
- `GET /products?updatedSince=&afterId=` is a **microsecond**-precision keyset cursor —
  a millisecond timestamp skips or re-serves rows sharing one bill's `now()`.
- Part-number uniqueness is a Postgres constraint (`uq_products_partno_ci`), not an app
  check; check `EXPLAIN` as `pos_app`, never as superuser (RLS changes the plan).
- PO receive lock order: PO row → products in id order; weighted-average cost rounds
  satang half-up (deliberately differs from the Dart client's float `round2`).

**Client-side Flutter:**
- `setState(() { x = …; })`, never the arrow form, **when the assigned value is a
  `Future`** — the arrow form trips a Flutter assertion (compiled out in release builds,
  which is why it hid for a while).

- **Local cache is tenant-scoped (API build, #539):** `AppMeta tenant_id` + `TenantCacheGuard`;
  a switch resets via `resetTenantCache`/`resetPulledCache` and is **refused with unsent work**
  (`TENANT_SWITCH_UNSENT_WORK`, `ENROL_UNSENT_WORK`). `cacheGeneration` fences late pulls/seeds, and
  `ApiClient` has a session generation so a stale refresh/401/token never acts for the next user
  (#534/#536). Replies to in-flight online writes are not fenced (accepted limit).

**Writing in `docs/Backend_design/` (added 2026-09-23, PR #391 —
`handoff_log/session-2026-09-23-key-primer-docs.md`):**
- **Never cite a `-- 🆕 migration NNNN:` comment as a live constraint.** `01_DATABASE.md §5`
  can carry both shipped DDL and not-yet-applied migrations in the same code fences. Check
  which side of that line an identifier sits on — and that its migration is in `MIGRATIONS`
  (`server/src/db/data-source.ts`) — before quoting it. 🔴 **Corrected 2026-09-25:** the
  example first recorded here was itself backwards — `uq_products_partno_ci` (migration
  `1788652800007`) **is** applied and is the enforcing case-insensitive index;
  `uq_products_partno` still exists but is subsumed by it.
- **Mermaid ER diagrams cannot express a composite key** — labelling `tenant_id PK` and `id PK`
  as two rows made readers see two primary keys, even with a warning above the diagram. Since
  2026-09-24 `§3` never puts a `PK`/`UK` label on a multi-column key: those columns carry the
  comment `"PK ร่วม (tenant_id, id)"` / `"UNIQUE (tenant_id, receipt_no)"` instead, and
  `tenant_id` is labelled `FK` (to `tenants`). Only single-column keys (`TENANTS`) keep
  `PK`/`UK`. Keep that convention if you add a table to a diagram.
- **A cross-reference to another doc's section must be grepped before it is written.** Three
  pointers shipped in the first pass named things that do not exist (`ADR-0003` has no
  `PRIMARY KEY` in it at all; `architecture-primer.md §4` is about architecture options, not FKs).
  Restating a *definition* in several files is fine — it does not drift; inventing a
  *file-specific example* is what produced every false claim.
- Two known doc-vs-reality divergences, both annotated, neither reconciled: `architecture.md`'s
  DDL is an old sketch (single-column PK, still has `offline_ok`, dropped per #272) while
  `00_INDEX.md` advertises it as the reference spec — `01_DATABASE.md §5` binds; and
  `audit_log` is `id BIGSERIAL PRIMARY KEY` in the docs but `(tenant_id, id)` in the shipped
  migration (recorded at the end of `adr/README.md`).
- The key terminology primer has **one** home: `00_BASICS.md#keys` (full) and
  `01_DATABASE.md#keys` (short). Link to them; do not copy the table into a third file.

**General lesson, learned the expensive way more than once (#22, #24, #260's import
pre-flight):** **validate input first, then clamp** — a `GREATEST`/`Math.max` clamp on
an unvalidated value turns a loud corruption into a quiet one.

---

## Phase 2

**Spec:** `docs/Backend_design/08_PHASE2_SPEC.md` (2026-09-15; owner decisions D1–D15,
E1–E11, F1–F10 in #240, map #243; merged as PR #254). Key shape: one `owner` role + one
active shop account per tenant, retire/enrol/export need an enrolled device token, no
`offlineOk` (column dropped), the `pos` device issues RC/CN online *and* offline,
`POST /sync/push` authenticates with the device token and replays by key then client id
before any check, multiple shifts per day, online void = reason only (no PIN), the
offline-PIN window is enforced till-side only, production = department VM `mob04` via
the hardened self-hosted runner. ADR-0004/0007/0009/0010/0013 carry dated phase-2
addenda.

**Lanes:** `docs/Backend_design/09_PHASE2_LANES.md` (2026-09-16, owner-approved; 35
issues under #243). Lane B (`team/2`, `LomerAlloys`) owns the whole on-device engine —
PWA/SW, `outbox_ops`, `SyncService`, RC/CN numbering, offline PIN, pull, and **every
Drift schema bump**. Lane C (`team/3`, `PattaraponKitcharoen`) owns the server + new
screens + ops. Lane A (`team/1`, `NuimanLP`) is 3 unblocking tickets — **all merged
2026-09-17**:
- **#268** (Thai copy, Option A) → PR #305 — 5 new error codes + 13 phase-2 UI strings
  in `02_API_SCREENS.md §8`/`§8.1`/`§8.1.1`, wired into `server_error_resolver.dart`.
- **#269** (`SyncFacade` seam) → PR #307 — `SyncFacade`/`NullSyncFacade`/`FakeSyncFacade`
  (`frontend/lib/data/sync/sync_facade.dart`) + all 18 `/sync/push` fixture JSONs
  (`docs/Backend_design/fixtures/sync-push/`) — the contract lane B/C build against.
- **#270** (platform allowlist) → PR #308 — `/api/v1/platform/` restricted to
  loopback/`PLATFORM_ADMIN_IPS`, `/sw.js` no-cache, `nginx-check` CI job.

🔴 Four issues are **halves** — read both before touching either: #228 ↔ #283,
#212 ↔ #277, #194 ↔ #285, #193 ↔ #287. 🔴 **Blocked-by never crosses a lane** — a
cross-lane need is a contract (fixtures, `SyncFacade`), never a queue. 🔴 An AC may
never claim "works against the real thing" while the other half of a split ticket is
unmerged. Every ticket ends with `09 §10`'s working agreement: `/scrutinize` the
approach → code per `karpathy-guidelines` → test only against your own side's fake →
close with `/code-review`. Read `docs/handoff_log/phase2-lane-split-and-tickets-2026-09-16.md`
for how the split was chosen.

---

## Pending follow-ups (not yet built)

Deployment/hosting is owned by `docs/Backend_design/07_CICD_DEPLOY.md` (ADR-0013).
- **Cloud snapshot backup (Supabase) — Phase 7a**, stubbed/not wired (needs project
  creds).
- **Record-level sync — Phase 7b** — done as of #53 (schema v3): all six
  product-mutating paths stamp `updatedAt`; optional until a second device exists.
- **Software hardening — Phase 8a**: manager-PIN gate, audit log, PDPA. Font bundling
  done (#271) — 🔴 not fully closed: the web build's fallback-glyph fetch to
  `fonts.gstatic.com` (the Flutter engine's, not `google_fonts`') still fires for the
  ~29 files using emoji, and the web service worker precaches nothing (blocked on
  #266) — see `docs/handoff_log/ticket-271-bundle-fonts.md`.
- **Native hardware — Phase 8b** (needs shop access): thermal printer / cash-drawer
  kick / barcode scanning — scan actions currently use manual entry.
- **Security** — compose hardening done (Redis `--requirepass`, no datastore ports
  published beyond dev/CI loopback); ADR-0009 addendum covers token signing/storage.
- Fill the screenshot placeholders left in `docs/tutorial/sri-pos-manual/` (the Thai SOP
  manual that replaced `docs/tutorial/flutter/` on 2026-09-27): each dashed box reads
  `(ภาพหน้าจอ: <name> — รอเพิ่ม)` — add `img/<name>.png` and swap the box for an `<img>`.
  Full tax invoice (ใบกำกับภาษีเต็มรูป) stays out of scope for v1.

---

## Conventions

- **Thai UI strings = behaviour parity** — copy exactly from `db.js` / the `.jsx`; never translate.
- Money via `baht()` / `round2()` — or `baht2()` where the display is fixed 2-decimal
  (cost/margin views); never inline `'฿${…toStringAsFixed(…)}'`.
- Date-string keys (yyyy-MM-dd / yyyy-MM, the db.js `slice(0,10)` idiom) via
  `core/utils/dates.dart` (`dateKey`/`todayKey`/`monthKey`); never re-slice inline.
- Thai date/time display via `presentation/widgets/thai_format.dart`
  (`thaiDate`/`thaiDateTime` for "23 มิ.ย. 2569", `thaiDateSlash`/`thaiDateTimeSlash`
  for the numeric "23/06/2569" CSV/receipt shape); no private per-file formatters.
- Status pills via the shared `StatusChip` widget (`StatusChip.of` for the common keys, or an
  explicit label+tone where the JS labels differ, e.g. PO 'open' → รอรับสินค้า).
- Quote expiry/converted checks via the `QuoteRowStatus` extension in
  `domain/models/aggregates.dart` (`q.isExpired` / `q.isConverted`).
- Screens consume **repository providers + Drift row classes** — never touch `AppDatabase`
  directly from a screen.
- Each screen file owns its sub-views (Receipt, ClosingReport, QuotesManager, etc.) per
  `CONTRACT.md §5`.

## Legacy app & full plan

The legacy JS app (source-of-truth-until-cutover) and the full migration plan live in the
**"Srisurart Autopart Design System"** repo. Tag **`v1.0-js-localstorage`** there marks the last
pure-JS/localStorage state.
