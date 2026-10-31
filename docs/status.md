# Project status — current state, open tickets, release log

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: release history, phase-1 "Still open" items, ticket narrative, pending follow-ups.

## Current state

## Migration status (Phase 0–6 complete; phase-1 backend/CI/CD built; phase-2 in progress)

**Full build log archived.** Every merged PR, bug found, and owner decision from
2026-06-24 through 2026-09-17 — the backend stand-up, all three CI/CD levels, the
phase-1 lane-A/B/C work, and the phase-2 kickoff — is preserved verbatim in
`docs/handoff_log/claude-md-full-history-archive-2026-09-17.md`. Read it for the *why*
behind any rule in `docs/rules/`, or the story of a specific PR/ticket this section only names.
What follows is current state plus the rules from that log that still bind new code.

**Done:** scaffold; data layer + unit tests; all 11 screens; shared UI kit + nav; shifts
layer; adversarial scrutiny + fix pass; web-DB runtime wired. App `dart analyze`-clean,
tests green, `flutter build web` ok. Riverpod → flutter_bloc migration done (2026-07-14,
`handoff_log/riverpod-to-bloc.md`).

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
- ~~#67~~ (**closed 2026-09-30, 15/15** — kept here for the rules in `docs/rules/ci-cd-deploy.md`) — self-hosted deploy runner: 🔴 **installed 2026-09-30** (`mob04-demo`, service user
  `gha-runner`, via `setup-mob04-runner.sh`; `gh api …/actions/runners` = 1, online) and the
  **first real deploy ran**: `Deploy (demo)` for `e50f4fa`, approved by `NuimanLP`, Ansible
  `failed=0`, `.current_sha` = `e50f4fa`, `/health/ready` 200
  (`docs/handoff_log/session-2026-09-30-first-runner-deploy.md`). Afternoon: merge→CD proven
  on `494ace3` (run `36685602814`), `workflow_dispatch` rollback to `e50f4fa` proven (run
  `36687687309`, schema unchanged), same-SHA rerun = "Skipping duplicate deployment"
  (`36688248109`). **#67 closed 15/15 2026-09-30 evening (evidence comment 5912257527, closing comment 5913430909):** one-image-only → skip, no concurrent deploys (a job *waiting for approval* already holds the `deploy-demo` slot), `log_level` seeded when missing and a hand-set value survives, failing readiness → red run + auto-rollback by `pos-deploy` re-running the old release (run `36720675552`; not an Ansible `rescue:`), hook refuses a non-`main` branch (run `36721404240`). The fork half of the hook AC was proven from code + settings only, owner-accepted, **no real fork run** (comment 5913430909): the `demo` environment has a `main`-only branch policy and fork-PR
  approval is `all_external_contributors` (owner-approved 2026-09-30). A same-SHA `workflow_dispatch` (with `.env` unchanged) exits before etcd-init and `deploy.yml` has no force input, so re-testing `log_level` seeding needs a real SHA change. Still verify with
  `.current_sha` before claiming a deploy — a green run alone proves nothing (`docs/rules/ci-cd-deploy.md`).
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
  `::warning::` as expected (rclone offsite unconfigured). First real 03:00 cron run with it is still 2026-10-01. A foreign `Origin`
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
- **#616 UUID cutover (2026-10-06, `docs/handoff_log/session-2026-10-06-uuid-cutover-mob04.md`).**
  PR #628 (`develop` → `main`, merge commit) = `65861ea`; closed #612/#616/#619/#620/#621.
  `mob04` ran `65861ea` that day (since 2026-10-07: `53fdd1b`), DB **wiped — no tenant**. 🔴 **Pre-wipe dump (checked 2026-10-21):** `pos_backup_20261006_035714Z.sql.gz` was pruned;
  the only one left is `/opt/pos/backups-removed-20261007/pos_backup_20261006_030001Z.sql.gz`, **on the VM only** — the
  handoff's "copy on the owner's laptop" (`~/Downloads/srisurart-mob04-backups/`) no longer exists, and the PC backup pull
  (#363) copies only `/opt/pos/backups/`.
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
- **Postgres has 32 tables** (27 from `InitialSchema` + `import_jobs` + `owner_review_items`
  + `payment_accounts` (#676) + `sale_photos` (migration `1788652805200`, 2026-10-12) + `refresh_families` (migration `1788652805300`, #755, 2026-10-22); recounted 2026-10-10 — product images add the column `products.image_key`
  (migration `1788652805100`), not a table; `change_log` never built). `docs/Backend_design/` was re-synced to the migrations, code and
  ADRs on 2026-09-23 (PR #390) — **the migrations are the schema's source of truth**, the
  DDL in `01_DATABASE.md` is illustration.
- Opened 2026-09-21 from verified findings. **#364, #366 and #367 were closed the same
  day (PRs #374 / #371 / #373); #365 closed 2026-09-30; #363 is still open.**
  - **#363 — off-VM copy exists since 2026-10-18 (owner decision: the PC pulls, not rclone):** the owner's Windows PC
    runs Scheduled Task "Srisurart mob04 backup pull" (`deploy/scripts/pc-pull-backups.ps1`, daily 11:00 + 20:00 since 2026-10-23, PR #737/#767) — scp as `deploy`
    into `D:\Beestation\Sri_POS\ops\backups\mob04\YYYY-MM\` (owner-only ACL), sha256-verified, 30 days local; the BeeStation client syncs that
    folder to the shop NAS. It never writes to `mob04` (no `.uploaded` markers, so `backup-db.sh` prune stays age-based). Works only
    while the PC is on and reaches `172.30.58.20`. **AC3 rehearsed 2026-10-23** (fresh Docker Engine in WSL Ubuntu 26.04 on the owner PC, inputs only git `4b45093` + the PC-pulled set `20261023_030001Z` + the `ops\secrets` `.env`/`certs-ca` copies): stack healthy, `/health/ready` 200 in 113 s after image pull, counts = live `mob04`, same CA served — `docs/handoff_log/session-2026-10-23-owner-items-dr.md`. Not yet done: a restore on a *different* machine pulling from the NAS itself. 🔴 **All PC ops live under one root `D:\Beestation\Sri_POS\ops\`** (owner 2026-10-18, PR #739; synced to the NAS,
    secrets included — owner accepted): `bin\` (scripts the tasks run, pinned `attrib +P`), `secrets\` (webhook, `.env` copies),
    `logs\`, `state\`, `backups\mob04\YYYY-MM\`, `README.txt`; all but `logs\` owner-only ACL. Anyone who can write the NAS share can
    change `bin\` — keep NAS write access owner-only. Never `%LOCALAPPDATA%` (MSIX AppData virtualization hides it from Task
    Scheduler, exit `0xFFFD0000`). Tasks run via `conhost.exe --headless` (no console flash) — which always reports exit 0, so
    `LastTaskResult` proves nothing: read `ops\logs` / Discord.
    The PC watchdog ("Srisurart mob04 watchdog", every 5 min, pinned CA, Discord on 2 failures) covers "mob04 fully down", which
    Gatus on the same host cannot. Both run only while the PC is on and logged on; the pull also alerts Discord when the newest
    off-VM copy is older than 26 h (PR #740). The history below is kept for the why.
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
    ~~Parked until after the `mob04` demo (owner, 2026-09-22)~~ — superseded 2026-10-18 by the PC pull above: a copy now
    leaves the VM daily while the owner PC is on. AC3 rehearsed 2026-10-23 (above); #363/#288 stay open until the owner closes them —
    the copy still depends on the owner PC being on.
    **`mob04` backup folder, tidied 2026-10-07:** 20 empty/irrelevant dumps + sidecars (20-byte failed
    dumps 2026-09-29/30, 0-tenant dumps 09-30/10-01, test-tenant-only 10-02..10-05, a duplicate 10-06
    03:00) were **moved, not deleted**, to `/opt/pos/backups-removed-20261007/`. Kept in
    `/opt/pos/backups/`: the latest nightly, the etcd snapshot, the cron log (the pre-wipe dump: see "#616 UUID cutover").
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
    in `docs/rules/ci-cd-deploy.md`.
  - **#367** (closed, PR #373) — `CORS_ORIGINS`/`PLATFORM_ADMIN_IPS` now reach the
    containers via the `x-app-env` anchor, and a set-but-empty list throws at boot instead
    of silently falling back to `'*'`. `mob04` is **not** `'*'`: its `.env` already had
    `CORS_ORIGINS=https://172.30.58.20` at the first runner deploy (verified 2026-09-30 —
    own origin gets ACAO, a foreign one does not).
- Phase-2 kickoff order for the remaining hub tickets: #228 → #229 → #212/#211/#189 →
  #230 → #190 → #231. As of 2026-09-25 all but **#231** (q4.cutover) are closed
  (2026-09-18 → 09-20); #231 is the only one still open.
- **#443 `platform.admin-ui` — code merged 2026-09-27, issue still open.** Platform CLI
  (#445), enrolCode reissue + tenant detail (#446), owner temp password + forced change
  (#447, migration `1788652804500`; `POST /platform/tenants` now **rejects**
  `ownerPassword`), web dashboard `platform-ui` on `127.0.0.1:3200` (#448), phone-width fix
  + tutorial (#450). 403-at-both-layers proven on `mob04` 2026-09-30 (comment 5913452241). Open: the AC
  "only `bootstrap:admin` creates admins" contradicts the owner-ratified `PLATFORM_ADMINS` sync, and owner answers listed in
  `docs/handoff_log/session-2026-09-27-platform-admin-ui-443.md` §6. Container runs on `mob04`
  since the 2026-09-30 deploy; 3 platform admins synced from `PLATFORM_ADMINS` the same day
  (first human UI login on `mob04` 2026-10-05, during #344 — evidence for this ticket).

**#243 (the phase-2 wayfinder map) was closed 2026-09-22** after checking each of its own
"not yet specified" items: lane split ✅ (`09_PHASE2_LANES.md`), Thai phase-2 copy ✅
(#268 → PR #305), and every phase-2 slice ticket it points at is closed except #288. Its
third item — load-time RAM of the full stack on `mob04` — says "measured in #184" and
**was never measured**; that gap lives on **#380** now, not on a map.

## Release log (newest first)

**2026-10-31 — camera scan on the add-product form.** `main` `e1f68ab2` (release #821, #822): deployed to the Pi by hand (`failed=0`, ready 200); `mob04` Deploy run `41205979387` stuck `pending`, not deployed. Record: `docs/handoff_log/session-2026-10-25-pi5-first-deploy.md`.

**2026-10-30/31 — Dependabot clear-out + Pi deploy.** `main` `0710ecf9` (releases #817, #819): #815 matter-server, #816 dev/lint tooling bumps, #818 `qs` override; all 11 open Dependabot alerts cleared. Deployed to the Pi by hand (`.current_sha` `0710ecf9a81a42bc3a93431ad66890b34bfe75b0`, `failed=0`, `/health/ready` 200, 17 containers); MPTCP disabled on the Pi and (re-posted warning, 2026-10-31) on `mob04` too (`7.0.0-28-generic`, was `=1`; kernel still unpatched, no reboot). Record: `docs/handoff_log/session-2026-10-25-pi5-first-deploy.md`.

🔴 **The development freeze was lifted by the owner on 2026-10-10; normal development resumed** (it had run since
2026-10-07 for the course submission, with one-off exceptions: QR payment accounts `ef07e27`, POS favourites `1d70d1c`,
owner backup import `847e7ef`, suppliers pull `6a38c87`; the release before the freeze was `53fdd1b`). Work goes through
`develop` as usual. The first post-freeze feature is **product images** (PR #680, `feat/product-images`; API in
`docs/Backend_design/02_API_SCREENS.md §3.2`/`§3.10`, rules in "Product images" in `docs/rules/features.md`). Since then `main` moved to `5ab7266` (PR #784: `backup-db.sh` reads the offsite rclone pair from `/opt/pos/.env`, #783 — reaches a host through `provision.yml`, Pi re-provisioned) and `b5dccea` (PR #788: `android-apk.yml` `target` input, #787 — first Pi APK `apk-pi5-b5dccea`); neither rebuilt the app images, so `mob04` `.current_sha` stays `8713c9f…` (checked 2026-10-25). Record: `docs/handoff_log/session-2026-10-25-pi5-first-deploy.md`. Pi light k6 run 2026-10-26 (on the Pi, 24 r/s; not #380 evidence): reads p95 7.3 ms, mixed p95 16.5 ms, contention exact (p95 933 ms cold, 67 ms warm re-run), peak CPU 58% of 400% — `docs/handoff_log/session-2026-10-26-pi5-load-test.md`. **Last release = `main` `8713c9f` (PR #779, merge commit, 2026-10-25)**: nginx gzips the static web build only (`location /` + the `main.<release>.dart.js` entry point; API/health/`/img/` stay uncompressed — BREACH) and server overrides body-parser ≥2.4.0, multer ≥2.5.0, undici ≥6.29.1 (3 new high advisories) (#778); no migration. Deploy run `40151601600` approved, success; `mob04` `.current_sha` = `8713c9f…`, `/health/ready` 200, canvaskit.wasm/flutter_bootstrap.js `Content-Encoding: gzip`, `/api/` not. **Pi 5** (`pi5-pos`, first host besides `mob04`, deployed by hand from WSL): `deploy.yml` `failed=0 rescued=0`, `.current_sha` = `8713c9f…`, ready 200; cold canvaskit over Tailscale 2.2 MB in 2.0 s (was 5.8 MB in 51 s). Record: `docs/handoff_log/session-2026-10-25-pi5-first-deploy.md`. Before it `main` `b748387` (PR #773, merge commit, 2026-10-23): Node 22 → 24 (#769), ≥48 px counter tap targets (#770), backup job-status race (#771), CLAUDE.md split into `docs/rules/` + this file (#768), evening backup + `certs-ca` copy (#767), ADR-0009 addendum + `IMAGE_BUSY` ratified (#766), plus shop features #760–#765 (mechanic credit statement, transfer tick-list, cash-out categories, stocktake, VAT tax ID + sales-tax CSV); no migration. Deploy run `39965141859` approved, `failed=0`, `.current_sha` = `b748387…`, `/health/ready` 200, api on Node v24.22.1, `sharp` loads, Prometheus targets up. Record: `docs/handoff_log/session-2026-10-23-owner-items-dr.md`. Before it `main` `4b45093` (PR #756, merge commit, 2026-10-22): review fixes round 2 — `/auth/device` throttle (10/IP/min + 100 failures/10 min global, 429 `RATE_LIMITED`; fails open when redis-cache is down, like login) and **single-use refresh tokens** (#755: table `refresh_families`, migration `1788652805300`; the just-replaced token is answered with the current one **once**, within 24 h, else the chain is revoked; ADR-0009 addendum 2026-10-22, ratified by the owner 2026-10-23); returns/drawer-entry id reuse → replay or 409 `CLIENT_ID_REUSED`, never 500; `quotes/purge` enqueues after commit; image queue capped at 4 waiters → 503 `IMAGE_BUSY` (Thai string ratified 2026-10-23) (#753/#754); PO/quote writes parked in `PendingWrites`, no invented server ids, a parked sale blocks shift close (#752); `api-readiness` scrape job removed (#751). Deploy run `39774975792` `failed=0`; **first real pre-migrate dump** `/opt/pos/backups-pre-migrate/pos_backup_20261022_120235Z.sql.gz` (gzip + sha256 ok); `.current_sha` = `4b45093…`, 32 tables, 10 rules Normal. Record: `docs/handoff_log/session-2026-10-22-review-fixes-round2.md`. Before it `main` `8a7b350` (PR #748, merge commit, 2026-10-22): PO print — `พิมพ์` button on open + received PO cards -> A4 purchase-order PDF with no prices/status (PR #747, rules in "PO print" in `docs/rules/features.md`); client only, no migration. Deploy run `39712318054` approved, `deploy to demo` success, `/opt/pos/.current_sha` = `8a7b350…` checked over SSH, `/health/ready` 200 (twin `39712328656` cancelled); `pnpm audit` hit `ERR_SOCKET_TIMEOUT` twice, re-run green. Record: `docs/handoff_log/session-2026-10-22-po-print.md`. Before it `main` `d5e2d10`(PR #744, merge commit, 2026-10-21)**: review fixes — nginx 1.30.6, Prometheus 3.13.5 LTS, Grafana 12.4.13
(`GF_PLUGINS_PREINSTALL_DISABLED=true`; 🔴 Grafana cannot downgrade — a rollback past `d5e2d10` starts 11.2 on a 12.4-migrated volume,
monitoring only), node-exporter 1.12.1, Trivy 0.76.1 (#743); `restore-db.sh` ON_ERROR_STOP + `gzip -t` first + stops/starts
api-1..3/worker/bull-board on compose + no target-db argument (#741; proven 2026-10-21 against WSL Postgres from the NAS copy);
vite 8.3.5 direct devDependency (GHSA-587h-7wmj-h5pm, a pnpm override did not re-resolve it); PC ops fixes (#737–#740).
Deploy run `39633605566` `failed=0`, `.current_sha` checked, 10 rules Normal; `provision.yml` re-run without `DEMO_ENV_FILE`
(installed `restore-db.sh` `cc854480…`, `.env` unchanged). Record: `docs/handoff_log/session-2026-10-21-review-fixes-release.md`.
Before it `e6374df`
(PR #736, merge commit, 2026-10-18): follow-ups to #727 — `host-setup.sh` upgrade/restart fix (#728), alert test checks every
rule metric has a series + disk alert also watches `/srv/pos-data` (#734), `restore-db.sh` verifies against `migrations` (#735, it used to
exit 1 after a good restore), PC watchdog (#733), docs. Deploy run `39116359714` `failed=0`, `.current_sha` checked; then `provision.yml`
from a clean `e6374df` tree run from WSL **without** `DEMO_ENV_FILE` (`failed=0`; installed `restore-db.sh` + `measure-container-rss.sh`;
`.env` sha256 unchanged). Before it `21ad935`
(PR #727, merge commit, 2026-10-17): the DevOps bundle (see the 🔴 paragraph after this one). Before that `5c7f210`
(PR #714, merge commit, 2026-10-13): multi-arch (amd64+arm64) images (PR #711), `CERT_SAN_IPS` (PR #712) and `host-setup.sh`
(PR #713) — rules in "Multi-arch images + Raspberry Pi 5 host" in `docs/rules/ci-cd-deploy.md` — deployed to `mob04` (run `38393626652`, `.current_sha`
checked; `docs/handoff_log/session-2026-10-13-pi5-multiarch.md`).
🔴 **The devops bundle (parked in `develop` 2026-10-14) was RELEASED 2026-10-17:** PR #727 (`develop` → `main`, merge commit) =
`main` `21ad935`; Server CI + Flutter CI green, multi-arch images published. Bundle = PR #723 (#717 Semgrep + SHA-pinned actions,
#718 pre-migrate DB dump, #719 Grafana alerting → Discord + Gatus, #720 ansible-lint + Trivy config/web scan + SSH host-key
checking, #721 review fixes) + PR #722 + PR #724. Deploy (demo) run `39042973596` approved, Ansible `failed=0`, `/health/ready` ok,
`/opt/pos/.current_sha` = `21ad935…` checked over SSH (twin run `39042895154` skipped green, normal). No migration was pending, so
the pre-migrate dump was correctly skipped — **it has still never dumped on `mob04`**. `provision.yml` was NOT run: over SSH as
`cloud` the release `backup-db.sh` was installed by hand (sha256 `c312728f…`, previous copy `.backup-db.sh.prev-5c7f210`),
`/opt/pos/node-textfile` created (deploy:deploy 0755) and `backup-db.sh` run once as `deploy` in cron env (rc=0) → gauge
`pos_backup_last_success_timestamp_seconds` is in Prometheus; all 10 Grafana rules Normal, Gatus 9/9 endpoints success.
🔴 **Discord alerting live on `mob04` since 2026-10-18:** `ALERT_DISCORD_WEBHOOK` set in `/opt/pos/.env` by hand (backup
`.env.bak-20261018T041536Z`; egress checked: HTTP 200, issuer Google Trust Services, not FortiGate), `grafana` + `gatus` recreated,
Grafana contact-point test → `discord ok`. The webhook is a secret: it only lives in `.env` (leaked = delete it in Discord and make a new one). The Healthchecks.io heartbeat (cron, `healthcheck-ping.sh`, `HEALTHCHECKS_PING_URL`) was **removed from `mob04` by hand on 2026-10-18** after the account owner paused the check (backups `/opt/pos/.env.bak-20261018T024347Z`, `.deploy.cron.bak-…`, `scripts/.healthcheck-ping.sh.removed-…`). **Owner decided 2026-10-18:** pre-migrate retention 30 days (PDPA) and both ADR-0013 addenda (Semgrep, alerting) **Accepted**. Record: `docs/handoff_log/session-2026-10-17-release-727.md`. PR #728 (`0d7ffd6`, squash;
released in `e6374df`): `host-setup.sh` accepts the `5c7f210` `daemon.json` as an upgrade and restarts Docker when
`DockerRootDir` ≠ `/srv/pos-data/docker`. Before `21ad935` the release was `5c7f210`; before that `8a44a03`
(PR #704, merge commit, 2026-10-13): the sale-photo sheet's built-in camera + photo reorder (PR #702) and the
supplier-first Suppliers tab with one-click PO and one shared `stockLevel` rule (PR #703; rules in "Supplier-first tab"
in `docs/rules/features.md`), deployed to `mob04` (run `38275228902`, `.current_sha` checked over SSH; client only, no migration;
`docs/handoff_log/session-2026-10-13-camera-suppliers.md`). Before it `c3e33aa`
(PR #699, merge commit, 2026-10-12): camera barcode scan (PR #697) + sale photo evidence (PR #698; rules in "Camera
barcode scan" / "Sale photo evidence" in `docs/rules/features.md`), deployed to `mob04` (run `38260777086`, `.current_sha` checked over SSH, the
new `backup-db.sh` installed by hand the same day; `docs/handoff_log/session-2026-10-12-photo-evidence-barcode.md`). Before
it `ec31121` (PR #696, 2026-10-12, run `38189738827`): the owner-ratified Thai strings of the UI/UX pass (PR #695). Before that `2d6a575` (PR #694, 2026-10-12, run `38187206166`): the
presentation-only UI/UX polish of every screen (PR #693; audits in `docs/research/ui-ux-audit-2026-10-11/`,
`docs/handoff_log/session-2026-10-12-ui-ux-polish.md`). Before that `2dabbcf`
(PR #691, merge commit, 2026-10-11), create-PO supplier search (PR #690), deployed to `mob04` (run `38103562796`,
`.current_sha` checked over SSH once the VPN returned; `docs/handoff_log/session-2026-10-11-ui-zoom.md` Release 2). The release before it,
`bf02582` (PR #687, 2026-10-11), whole-screen zoom up to 3x for elderly users (PR #686), deployed to `mob04` (run
`38100697523`, `.current_sha` checked over SSH). The release before that, `e77356f` (PR #683, 2026-10-10, run `38066101954`): the first
try `ac9d4dd` (#681) rolled back because sharp's prebuilt binaries need x86-64-v2 and `mob04` is a `qemu64` CPU; fixed by
PR #682 (`docs/handoff_log/session-2026-10-10-product-images.md`). A Raspberry Pi 5 move is only a plan
(`docs/research/pi5-migration-plan.md`, owner undecided): the installer and arm64 images exist
(`docs/tutorial/pi5-full-stack-tutorial.md`) but **no Pi is in service** and `mob04` stays production. 🔴 **`develop` → `main` showing
"conflict" while `git merge` is clean = criss-cross merge bases** (`git merge-base --all` prints 2+): merge `main` into
`develop` with a merge-commit PR (#673), never squash. 🔴 **Never enable auto-merge on a PR an agent is still pushing to**
(a push after the merge button misses `develop` — recurred 2026-10-07 on #654, see the lesson in `docs/rules/client-write-path.md`).

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
