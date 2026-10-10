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

## 🌿 Branch strategy (set 2026-09-04; `develop` added 2026-10-06)

Three long-lived branches. Know which one you are on before you change anything.

| Branch | What it is | Status |
|---|---|---|
| **`main`** | **The multi-tenant line** — Flutter **client** + NestJS **backend** + **CI/CD**, per `docs/Backend_design/` (Architecture C phase 1 = A, tenancy model T1) | **Release line.** Receives `develop` only; every code push builds images and triggers a deploy. |
| **`develop`** | Integration branch for the `main` line (owner decision 2026-10-06) | **Active.** Every work PR targets `develop` (`gh pr create --base develop`). |
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

🔴 **`develop` → `main` = merge commit only — now enforced (2026-10-06).** Squash/rebase rewrites the
SHAs, so `bedd328` (the `ROLLBACK_FLOOR` in `deploy/scripts/pos-deploy.sh`) would stop being an
ancestor of `main` and `pos-deploy` would refuse every SHA. Repository ruleset 24564072
"main: merge commit only" (active, no bypass actors) refuses squash and rebase on PRs into `main`;
PRs into `develop` may still squash. `develop` has the same branch protection as `main`.

🔴 **Development freeze (owner, 2026-10-07): development stops here for the course submission.** Last release =
`main` `ef07e27` (PR #677, merge commit, 2026-10-10), deployed to `mob04` (run `38050647954`, migration
`1788652805000-PaymentAccounts`) + APK `apk-ef07e27`; the owner lifted the freeze for exactly that one request (QR
payment accounts ≤5, owner-only, PromptPay QR with amount at checkout, sale records the account — PR #676,
`docs/handoff_log/session-2026-10-10-qr-payment-accounts.md`). Earlier exceptions: `1d70d1c` (PR #671/#672, POS
favourite stars, `docs/handoff_log/session-2026-10-08-pos-favorites.md`), `847e7ef` (PR #665, shop-owner
backup import, `docs/handoff_log/session-2026-10-08-owner-import.md`), then `6a38c87` (PR #669, suppliers pull
fix); the release before them was `53fdd1b` (PR #658, `docs/handoff_log/session-2026-10-07-final-release.md`).
Do not start feature work; only fixes the owner asks for. 🔴 **`develop` → `main` showing "conflict" while
`git merge` is clean = criss-cross merge bases** (`git merge-base --all` prints 2+): merge `main` into `develop`
with a merge-commit PR (#673), never squash. 🔴 **Never enable auto-merge on a PR an agent is still pushing to** (a push after the merge button
misses `develop` — recurred 2026-10-07 on #654, see the lesson below).

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
      utils/                   ← newUuid/newIdempotencyKey/docNo (ids.dart), baht/round2/pointsFor (money.dart),
                                 csvSafe (csv_safe.dart)
    data/
      db/tables.dart           ← 27 Drift tables, schemaVersion 15 (20 ported sa_* stores + #24's
                                 credit-payment outbox + phase-2 tables incl. OutboxOps, OpEffects
                                 + #676 PaymentAccounts; v15 = Products.imageKey) — recounted 2026-10-10
      db/database.dart         ← AppDatabase (@DriftDatabase) + seed data + AppDatabase.open()
      db/database.g.dart       ← GENERATED (committed). Regenerate ONLY on an ASCII path.
      repositories/            ← one repo per domain; transactional services mirror db.js
      repositories/api/        ← #56: ApiSales/ApiReturns/ApiShifts — same interfaces,
                                 server is the truth, Drift rows patched from the response
                                 (ADR-0010). Opt-in: --dart-define=USE_API_WRITES=true
    domain/models/aggregates.dart  ← SaleWithItems/… read aggregates + input DTOs (SaleInput…)
    presentation/
      repositories/repository_providers.dart ← flutter_bloc RepositoryProvider tree (24 entries:
                                 20 repos incl. AuthRepository and PaymentAccountsRepository, +
                                 ApiClient/BootstrapService/DocCounterSeeder/SyncFacade) — recounted
                                 2026-10-10; `useApi` swaps in the #56 API repos
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
- Entity ids via `newUuid()` (lowercase UUIDv7, #616); idempotency keys via `newIdempotencyKey(prefix)`;
  doc numbers via `docNo`; CSV via `csvSafe`.
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
  **First real measurement ran 2026-10-05** (`docs/handoff_log/session-2026-10-05-k6-capacity-run.md`:
  scenario 1 inside the criterion, scenario 2 @200 p95 ~3 s over it, scenario 3 @100 unclean on 429) but
  with tooling bugs, so it ticks nothing: the RSS sampler printed PASS over an empty table, the
  `Idempotency-Key`s collided across machines, `assertBurstSafe` under-counted. Fixed by PR #654 +
  PR #655 (2026-10-07; #654 auto-merged before its review-fix commit — recovered by #655): failed
  checks now fail the run (`checks: ['rate==1']`) and the RSS verdict counts restarts/OOM during the run.
  🔴 **Owner decision 2026-10-07: scenario 3's replay at 27 VU (3 machines × 9, the `perip` burst
  budget) is accepted instead of `02 §9`'s 100.** Still to do: re-run with the fixed tooling and have
  the owner read it; `measure-container-rss.sh` on `mob04` is still the old copy (only `provision.yml`
  or a manual `install` updates `/opt/pos/scripts`). It replaces **#184**, which was closed→reopened→closed
  three times in two days and finally closed by the owner on 2026-09-21 with all four ACs
  unticked; **do not reopen #184** (owner decision 2026-09-22). PR #357's `Closes #184`
  shipped tooling + a runbook and no measurement at all — never read that PR as evidence.
  **#251 is closed (2026-09-22): the *method* is settled, the *measurement* is not.**
  The method is `03_ARCHITECTURE.md §8.1`, decided 2026-09-15 and re-confirmed 2026-09-22:
  three machines each under their own `perip`, results streamed to the VM's Prometheus over
  remote-write. 🔴 **Exempting the load-generator IP from `perip` was considered and
  explicitly rejected** — never add that carve-out to `nginx.conf` without asking the owner.
  The `§8` k6 DoD box stays unticked until #380's re-run is read and accepted by the owner.
- **Auditing tickets? `closedByPullRequestsReferences` lies here.** GitHub links no PR at
  all when the PR carries no closing keyword — **93 of this repo's 201 merged PRs** are like
  that — and it never reads a keyword placed in the PR **title** (4 more: #328/#329/#332).
  PR **#306** is the engine behind #293/#294/#296 and part of #292 yet cites only `#196`.
  Cross-check with `git log --all --grep` before concluding that nothing shipped (#345,
  2026-09-22).
- ~~#343~~ / #344 — the first real deploy to `mob04` and the end-to-end demo run. **#343
  closed 2026-09-30 (5/5)** — deploy, Grafana checked, manual-Ansible rollback to `e50f4fa`
  `failed=0`, command log in the 2026-09-30 handoff (PR #511/#514). **#344 must restart from AC1** — 🔴 2026-10-06 the #616 cutover wiped every tenant on `mob04` (backup + runbook, `docs/handoff_log/session-2026-10-06-uuid-cutover-mob04.md`; `ROLLBACK_FLOOR` `bedd328`; VM since 2026-10-07 = `53fdd1b`). **2026-10-07 (owner):** restart from AC1 on tenant `ศรีสุราษฎร์เจริญยนต์`, the agent driving it through the Chrome extension — not run when this was written. Earlier partial run (2026-10-05: AC1 + AC2 only, tenant `demo-344-20261005`
  via platform-ui; sales/replay/Grafana not yet — `docs/handoff_log/session-2026-10-05-demo344-retired-device.md`); its
  checklist is `docs/handoff_log/demo-344-checklist-2026-09-30.md`, with flagged blockers
  (temp-password + forced change within 10 min, new tenant has no products, the app cannot
  resend an idempotency key, three #335 ACs not provable on the VM; #476 closed 2026-10-03). 2026-09-30
  `provision.yml` re-run added only `PLATFORM_ADMINS` (3 admins synced; first human platform-ui login 2026-10-05, see #344) and installed the missing `backup-db.sh`. 🔴 Correction: on 2026-09-29
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
  (commit `8faebac`), issue closed 2026-09-19. Drift is now at schema v15 (v12 = #417 indexes; v13 = #488
  `op_effects`: the deltas an offline sale/return/void actually applied, so discard reverses
  exactly — ops queued before v13 have no row and take the legacy recompute path; v14 = #676
  `payment_accounts` cache + `Sales.paymentAccountId`; v15 = product images, `Products.imageKey` — the
  server's content hash only, bytes never in Drift; v7's `TableMigration(products)` lists it in `newColumns`).
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
  Item 6 (LOW) fixed by PR #610 (2026-10-05, `03dc116`): online `POST /shifts/open`
  with an existing `id` and a different `startingCash` is `409 CLIENT_ID_REUSED`
  (`ClientIdReusedException`, `server/src/common/client-id-reused.exception.ts`, shared with
  `/sync/push`; `shifts.service.ts:202`); the same cash written differently (`"2000"` vs
  `"2000.00"`) is still a 200 replay. `08 §6.1` calls this an exception to "online keeps its
  own code" — **owner has not confirmed it yet**. Still open: the standards findings
  (§3) beyond the `Math.max` one, none re-triaged.
- **Retired/unknown device token at login (#609, PR #611 + PR #613, 2026-10-05, deployed).**
  `POST /auth/token` with a `deviceToken` the server retired or does not know is
  `401 DEVICE_RETIRED` / `401 DEVICE_TOKEN_INVALID`, checked **before** the password
  (`auth.service.ts:112-125`); `DeviceTokenGuard` on `/sync/push` is unchanged. Client:
  `AuthRepository.login` clears the device token + offline PIN (compare-and-clear — only if
  the stored token is still the one sent; owner confirmed clearing the PIN, #609 comment
  5987543993) and throws `DeviceEnrolmentGoneException`; `AuthCubit` shows Backoffice plus
  the Thai string `AuthCubit.deviceEnrolmentGone` (ratified by the owner 2026-10-07, `02 §8.1.1`), and
  `init`/`_logout` no longer show a remembered `pos` role without a device token. Drift and
  the outbox are untouched; `ENROL_UNSENT_WORK` still guards a new enrolment. Not built:
  shop name on the badge, device-status check at app open (both need new API). #612
  (offline-PIN setup dialog read any 401 as a wrong password) closed 2026-10-06 (PR #625/#629:
  dead token → same path as #609; only 401 `UNAUTHORIZED` = wrong password). Browser profile
  holding another tenant's retired token showed `เครื่อง POS` and hid the enrol link — the
  bug this fixed; use Incognito for a demo until the build is on the profile.
- **Owner backup import (2026-10-08, PR #664/#665, `847e7ef`, deployed; `docs/handoff_log/session-2026-10-08-owner-import.md`).**
  The shop owner imports a backup from Settings → สำรอง/กู้คืน → กู้คืนข้อมูล: `POST /backup/import`
  (+ `GET /backup/import/:jobId`), role `owner` + enrolled device, same `TenantImportService` as the platform
  import (ADR-0005 amendment 5). `?mode=replace&confirmShopName=` replaces the whole shop's data in one
  REPEATABLE READ tx; users/devices/audit_log/tenants/idempotency_keys/`doc_counters` stay.
  🔴 **Every import (platform + owner) must raise `doc_counters` from the imported RC/CN/PO/QT/CP numbers**
  (`GREATEST`; legacy-random numbers skipped; a `device_no` the tenant lacks is skipped and reported as
  `docCounterSkippedDevices`) — without it the first new sale collides (`409 RECEIPT_NO_CONFLICT`).
  🔴 The pre-import copy (`/app/exports/<tenant>/pre-import/<jobId>.json`, `exports` volume) is **never
  auto-deleted** (PDPA — retention is the owner's call) and lives only on the VM disk (#363 parked).
  Known limits: other devices keep stale rows after a replace (clear site data); shifts, drawer entries,
  movements, suppliers, credit-payment history and parked bills in the file are not pulled into the app.
  The real import on `mob04` has not been run yet; the Thai strings and amendment 5 are `agent ร่าง`, unratified.
- **#616 UUID cutover (2026-10-06, `docs/handoff_log/session-2026-10-06-uuid-cutover-mob04.md`).**
  PR #628 (`develop` → `main`, merge commit) = `65861ea`; closed #612/#616/#619/#620/#621.
  `mob04` ran `65861ea` that day (since 2026-10-07: `53fdd1b`), DB **wiped — no tenant**; dump
  `/opt/pos/backups/pos_backup_20261006_035714Z.sql.gz` (all 10 pre-wipe tenants). 🔴 **Correction
  2026-10-07: there is NO copy off the VM** — the handoff's "copy on the owner's laptop"
  (`~/Downloads/srisurart-mob04-backups/`) no longer exists (folder gone when checked), #363 is parked.
  `ROLLBACK_FLOOR` = `bedd328` (#617 merge): `pos-deploy` refuses anything older; restoring old
  data is an owner decision, not a rollback. `server/package.json` `pnpm.overrides` pins
  `proxy-addr`/`source-map-js` (#627 — a new advisory turned `pnpm audit` red on `main` too).
  Before use: create a tenant via platform-ui, wipe every client (Incognito / clear site data /
  clear APK storage — a pre-UUID outbox can neither send nor discard). The follow-ups left open
  that day were **fixed 2026-10-06/07**: `/sync/push` replay by client id now runs before the
  payload parser (PR #638, B1 step 2); `ApiException` is kept out of `presentation/` and out of
  every repository's runtime path (PRs #642/#644 — guard tests `presentation_no_api_exception_test.dart`
  + `api_exception_never_escapes_test.dart`); `assertValidTenantId` moved to `common/ids.ts` (#640);
  `pos_trust_test.dart` TLS assertions are OS-agnostic (#643); `INVALID_ID` Thai string ratified
  2026-10-07. Still open (not fixed): `offline_pin_repository.dart` ↔ `auth_repository.dart` import
  each other; `/sync/push` sales replay orders lines by stored `line_no` (the client always sends
  `lineNo` i+1, so harmless today).
- **5xx does not queue — owner decision 2026-09-27, `08 §5` amended (PR #469).** On the
  API build a 5xx/429 leaves the attempt parked (same id + key) and shows the error, for
  sales, shifts and returns alike — and since PR #645 (2026-10-06) customers and credit payments,
  since PR #657 (2026-10-07) `adjustStock` too (parked with `PendingWrites`, no offline queue); only a
  transport failure queues to the outbox. Two rules came with #657 (`08 §5`, owner 2026-10-07): a
  parked attempt closes **only after the local apply succeeded** (a failed apply keeps it parked,
  else the next press mints a new key = a duplicate), and a **new, different edit of a record
  supersedes that record's older parked edits at send time** (`PendingWrites.closeWhere`; a PATCH
  replaces whole values, so the older edit gets a fresh key instead of replaying a stale reply).
  A credit-payment retry re-sends its parked body and skips the local overpayment check.
  `PendingWrites` TTL = 10 min by design — past that a repeat is a new action.
- **Bugs filed 2026-09-27 are all closed:** #460 by PR #467, #461/#464 by PR #468 (owner
  chose: add the `เครดิตช่าง` row; take quote validity from Settings), #462/#463/#465 by
  PR #470, #452 by PR #469. **Three Thai strings from those PRs were `agent ร่าง` — ratified by the owner 2026-10-07**
  — `เปิดกะใหม่` (#469), the 8-character enrol-code wording (#470,
  `devices_screen.dart:869`, `device_enrolment_dialog.dart:97`), and the post-enrol banner
  (#470, `login_form.dart:188`); all three are in `02 §8.1.1` (ratified 2026-10-07, along with every other agent-drafted Thai string).
- **Follow-ups filed 2026-09-28** (verified in code, table in
  `docs/handoff_log/session-2026-09-28-overnight-bug-sweep.md` §2) — **all closed same
  day except #476 (closed 2026-10-03):** ~~#472 offline RC numbering guessed `deviceNo ?? 1` and fell back to
  `docNo('RC')`~~ fixed by PR #484 (`DocNumberService.issueOffline`, same rule #469 gave
  CN) · ~~#473 discarding a `sale.create`/`return.create` did not undo local
  stock/ledger~~ fixed by PR #483 (reverses stock/customer/mechanic/void inside the
  discard transaction; refuses `DISCARD_HAS_LOCAL_DEPENDENTS` when the bill already has a
  local return/void) · ~~#474 settings were not re-pulled when the link returns~~ fixed by
  PR #486 · ~~#475 a new device with no counter rows could not number an offline CN~~
  fixed by PR #484 (seeder writes a `last_no = 0` row) · ~~#476 device-management dead end
  after the last enrolled browser is lost~~ closed 2026-10-03 · ~~#477 reports
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
  isn't.** Recurred 2026-10-03 (#551/#552, #579, #580, #587 — see
  `handoff_log/session-2026-10-03-ux-test-drawer-ci.md`) 2026-10-05 (#611 auto-squashed
  at `03eb17a`, review fixes `49cd4c0` pushed 12 min later; recovered by PR #613) and 2026-10-07
  (#654 auto-merged 07:56Z at head `3b251a0`, its k6 review-fix commit pushed after; recovered by
  PR #655) — so no auto-merge while an agent is still pushing review fixes. 🔴 **Same trap on the branch side (found 2026-09-30):** before deleting a
  merged-PR branch, compare its tip with the PR's `headRefOid` — a mismatch means commits
  pushed after the merge that may exist nowhere else. That is how PR #486's review fix
  (`_writeGen` guard against a stale `GET /settings` clobbering a newer `PATCH`, commits
  `47653b1`/`c57019a`, pushed after the 2026-09-28 01:21:43Z merge) was found and recovered by PR #521
  (`ca2fef1`). This unblocked #490: `ensureSeedMarker`
  now accepts a seed from **any** period, so an offline sale after a month rollover starts
  at `0001` instead of refusing with
  `ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์` (08 §9 E8).
  #488 (discard exactness / `void_offline` follow-up) closed 2026-09-28.
- **Postgres has 30 tables** (27 from `InitialSchema` + `import_jobs` + `owner_review_items`
  + `payment_accounts` (#676);
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
    **`mob04` backup folder, tidied 2026-10-07:** 20 empty/irrelevant dumps + sidecars (20-byte failed
    dumps 2026-09-29/30, 0-tenant dumps 09-30/10-01, test-tenant-only 10-02..10-05, a duplicate 10-06
    03:00) were **moved, not deleted**, to `/opt/pos/backups-removed-20261007/`. Kept in
    `/opt/pos/backups/`: `pos_backup_20261006_035714Z.sql.gz` (all 10 pre-wipe tenants), the latest
    nightly, the etcd snapshot, the cron log. All of it is on the one VM disk.
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
  (first human UI login on `mob04` 2026-10-05, during #344 — evidence for this ticket).

The repo's long-lived branches are `main`, `develop` and `POC_sample_offline_first` (see Branch
strategy). Merged branches are pruned in sweeps (44 on 2026-09-22, 35 on 2026-09-30, 87 on
2026-10-06), each checked first: ancestor of `main`/`develop`, or PR MERGED with tip == PR head, or
post-merge commits patch-id-equivalent on the base. 🔴 **Before deleting a branch, check it is actually merged** — two
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
  `rethrowServerRefusal` to a plain Thai-string `Exception`/`PosException`. Enforced since
  2026-10-06 by `presentation_no_api_exception_test.dart` (no import in `presentation/`) and
  `api_exception_never_escapes_test.dart` (no repository lets one out at runtime).
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
- **Expected drawer cash is counted BY SHIFT** (owner decision 2026-10-03, PR #580;
  history: #452/PR #469 counted a time window — the day's first shift from midnight, a
  later one from its opening — via `cashCountFrom`, now deleted). Every baht taken or paid
  while a shift is open belongs to that shift, even past midnight — the server's
  `shift_id` rule (`server/src/reports/drawer-cash.sql.ts`, shared by `GET /reports/closing`
  and the cash-out refusal). Client: `ShiftsRepository.drawerCash` is the only rule — the
  cash-drawer screen, the closing report's drawer check and `assertCashOutFits` all use it.
  Attribution: drawer entries by `shiftId`; sales by `Sales.shiftId`, or (no `shiftId`, the
  Drift build) by `date` in the shift's `[openedAt, closedAt]`; returns and credit payments
  (no local shift column) by `date` in that interval; credit payments only when
  `isCashCreditPayment()`. Both sides must keep passing
  `docs/Backend_design/fixtures/drawer-cash/agreement.json`. Never compute expected cash a
  second way; the report's revenue/payment/top-item sections stay whole-day.
- **A cash-out larger than the drawer's expected cash is refused** (owner 2026-10-03,
  PR #580): `409 DRAWER_INSUFFICIENT_CASH` online, `PosException` on the Drift build and the
  API build's offline queue; a `/sync/push` `drawer.entry` replay is never refused (the cash
  already left) — one that takes the shift's expected cash below zero files one owner review
  item `drawer_overdrawn_offline` per entry (PR #585, migration `1788652804800`).
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
- Both `flutter.yml` and `server.yml` trigger on every PR (any base) and on push to `main` **and
  `develop`** (develop added 2026-10-07, so develop's head always has a full CI result); a `changes`
  job gates each workflow's own jobs internally so a `server/`-only PR still runs (and
  can satisfy) the Flutter required check, and vice versa. Each workflow ends in one
  always-reported status job (`flutter-ci-status`/`server-ci-status`) — the only
  required checks on `main`. On `main`/`develop` `concurrency.group` is keyed by ref + commit SHA
  and never cancelled. 🔴 **A push publishes to GHCR only from `main`** (`build-image`/`build-web`
  gated on `refs/heads/main`; the one exception is a manual `workflow_dispatch` of `build-web`, which
  pushes only a web `<sha>` tag and can never deploy — no server image; `deploy.yml` reacts to `main`
  only) — never let a develop push publish an image.
- Branch protection on `main` has been set since 2026-09-15: PR required (0 approvals),
  the two status jobs required, no force-push/delete, admins not enforced. **`develop` has the
  identical protection since 2026-10-06.** Ruleset 24564072 "main: merge commit only" (target
  `refs/heads/main`, active, **no bypass actors**) refuses squash/rebase into `main` — so admins
  cannot push directly to `main` either. Verify: `gh api repos/NuimanLP/srisurart-pos-flutter/rules/branches/main`.
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
  "on" while off); Dependabot alerts + security updates enabled 2026-10-01.
- In Actions expressions `0` is falsy: `cond && 0 || 1` is always `1` — use strings (`'0'`). This silently disabled the docs-only push skip until it was fixed (2026-10-01).
- **Quality gates (2026-10-03, PRs #579/#581/#582 — table in `07_CICD_DEPLOY.md §2c`):**
  a UI write that can fail silently gets a surfacing catch — never an `_allowlist` entry
  without a reason; coverage baselines only go **up**, never lowered to go green; a changed
  client request means regenerating and committing `fixtures/client-requests/`; a shipped
  migration is never edited — add a new one. 🔴 Two PRs green alone can be red
  together: #579 + #580 merged 29 s apart turned Flutter CI on `main` red (`2411ebf`,
  `a8a8080`) until #582 — after a gate lands, rebase open PRs before merging.
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
- **Docs-only push to main skips tests/images → no deploy; the VM stays on the last code SHA** (2026-10-01,
  `deploy/scripts/push-changes-kind.sh`, 07 §2 rule 2). Docs = `*.md` or `docs/**` except
  `docs/Backend_design/fixtures/**`; anything else is code. `deploy.yml` `resolve` applies the same rule to
  the range run-SHA..main-head, so a docs commit after a code commit does not strand that code deploy.
  A docs-only push to `develop` skips the same test jobs (develop never builds images or deploys).
- **Runner offline while its service is `active`** (2026-10-08): `BrokerServer` TLS read errors in the runner log
  ("Operation canceled") leave a Deploy run queued forever. Fix: `sudo systemctl restart
  actions.runner.NuimanLP-srisurart-pos-flutter.mob04-demo.service` as `cloud`. Check
  `gh api repos/NuimanLP/srisurart-pos-flutter/actions/runners` (`status: online`) before approving a deploy.
- **Cancel stale waiting Deploy runs before approving a newer one** — a job waiting for approval holds
  the `deploy-demo` slot and the newer run sits `pending`; the approval API needs a `comment`.
  A code merge to `main` fires Deploy twice (once per CI workflow); the first usually skips green
  because the other image is not on GHCR yet — approve the second (2026-10-06). When both runs reach the
  gate, the unapproved twin keeps waiting and blocks the *next* release — cancel it right after the deploy
  (2026-10-10: run `37786086586` of `1d70d1c` held the slot for 2 days).
- **A green `Deploy (demo)` run is not evidence that anything was deployed.** Its
  `deploy` job is gated on `needs.resolve.outputs.images_ready == 'true'`, so when the
  images for that SHA are not on GHCR yet the job is skipped and the workflow still
  reports *success* with only `resolve release` having run. The VM's `/opt/pos/.current_sha`
  is the only proof.
- **Never `gh pr merge --delete-branch` on a stacked PR.** Deleting a branch that is
  another PR's base makes GitHub close that PR, and a closed PR's base cannot be
  changed — recovery is push the old tip back, `gh pr reopen`, `gh pr edit --base develop`.
  Clean up branches once, after the whole stack has landed.
- **Retarget a stacked PR to `develop` once its base PR has merged, before merging it.**
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
- **Android APK (PR #551, merged 2026-10-03):** manual `android-apk.yml`, `main` only, **API build only** — no
  offline APK from `main` because `useApiRepositories` defaults true. Signed via secret `ANDROID_KEYSTORE_B64`; the
  keystore backup is the owner's — lose it and no APK can upgrade in place.
- **Private CA for `mob04` TLS (PR #552, merged 2026-10-03):** one-shot `certgen` keeps a CA in volume `certs-ca`
  and re-issues the leaf each deploy. 🔴 Never `down -v` or delete `certs-ca`: a new CA stops every distributed APK
  until the CA asset is recommitted and APKs rebuilt. `ca.key` lives only in `certs-ca`. `frontend/assets/certs/pos-ca.crt`
  holds the CA since 2026-10-03 (first certgen deploy `7ea0178`; SHA-256 `87:7B:B8:F7:…:54:CF:83:65`) — it must match
  `certs-ca/ca.crt` on the VM (`07_CICD_DEPLOY.md` §5 "TLS"). Never add `badCertificateCallback`.
  A VM IP change = edit the SAN in `server/docker/certgen/certgen.sh`.

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
- **Business/runtime metrics (2026-10-04):** `pos_documents_total{kind=sale|void|return}`,
  `pos_db_pool_connections{state=in_use|idle|waiting}` + `pos_db_pool_max_connections`,
  `pos_queue_jobs{queue,state}` — all named by `pos-overview.json` panels (ids 20–26).
  Documents follow the replay counter's rules: **no `tenant_id` label**, counted **only in
  `onTransactionCommit`**, placed after the existing-sale early return so a replayed key never
  counts twice; `void` = a clerk's void only (the auto-void of a fully returned bill is a
  `return`). `MetricsService` is a required dependency of `SalesService`/`VoidService`/
  `ReturnsService`. The pool gauge reads the `DB_POOL_STATS` reader (`db.module.ts`), never the
  `DataSource` — `tenant-door.spec.ts` refuses that. Queue depth lives in Redis, so all three
  instances report the same numbers: panels take `max()`, never `sum()`; the read has a 1 s
  timeout and drops its samples on error rather than serving stale counts.
  `RuntimeMetricsModule` is imported by `AppModule` only (the worker builds none of this).

- **App metrics (#597, 2026-10-04, deployed `41a8f19`):** `pos_documents_total{kind}` (counted in
  `onTransactionCommit`), `pos_db_pool_connections{state}` + `pos_db_pool_max_connections`,
  `pos_queue_jobs{queue,state}` (redis-queue read under a 1 s `withTimeout`) — named by
  `pos-overview.json` (29 panels), same rename rule as above. Queue reads are single-flight
  (`withTimeout` cannot cancel `getJobCounts`): a scrape joins a still-pending read instead of
  issuing new commands that would pile up in ioredis during a redis-queue outage — never remove it.
- **Local observability overlay (#600/#604, 2026-10-04) is dev-only:** `deploy/compose/observability.yml`,
  `local-api.yml`, `deploy/{alloy,loki,grafana-local,prometheus-local}/` are never referenced by Ansible.
  The production `deploy/prometheus/prometheus.yml` loads `scrape.d/*.yml` (absent on `mob04`).
  🔴 `deploy.yml` only **warns** if Prometheus/Grafana fail after a deploy, so the
  `promtool check config` step in `server.yml` `nginx-check` is the real gate — keep its image
  digest equal to `monitoring.yml`'s. Keep local-only files out of `deploy/prometheus/` and
  `deploy/grafana/` (deploy.yml copies those trees wholesale).
- **Uptime heartbeat (#596, 2026-10-04):** `deploy/scripts/healthcheck-ping.sh`, cron every 5 min as
  `deploy` from `provision.yml` (`journalctl -t pos-healthcheck`). **Installed on `mob04` by hand
  2026-10-04** (07 §7b: script sha256 `77f79d62…` = `origin/main`, key appended to `/opt/pos/.env`,
  cron entry with the `#Ansible:` marker so `provision.yml` adopts it; first cron run 15:20 UTC
  silent = healthy ping). 🔴 A CD deploy never updates it — re-install after a script change. The ping URL is a secret: only in `/opt/pos/.env`, passed to
  curl on stdin (`-K -`) never argv; a URL holding a quote/backslash/space is refused (`::error::`),
  not escaped. Unset = `::warning::` exit 0 (same rule as offsite backup).

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
- **Customer/mechanic pull keeps local totals under unsent money ops** (`outbox_ledger_refs.dart`): rows referenced by `sale.create`/`sale.void_offline`/`return.create`/`credit_payment.create` (any status) or a queued credit payment keep `points`/`totalSpend` / `creditBalance`/`totalSales`/`totalDiscount`/`totalMarkup`; the guard is recomputed per page inside the write txn and the saved cursor never passes a protected row. A new money-op type must be added to `_moneyOps`.

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
