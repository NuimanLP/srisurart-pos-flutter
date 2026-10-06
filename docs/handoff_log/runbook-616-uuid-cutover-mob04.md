# Runbook — #616 cutover บน `mob04`: ล้างข้อมูลเดโม → deploy id แบบ UUID (`develop` → `main`)

**Date:** 2026-10-06 · **Written by:** agent (branch `chore/616-main-merge-readiness`) · **Nothing here was
run.** This is a procedure for the owner (`NuimanLP`, the `demo` reviewer) — not evidence. Record what you
actually ran, with output, in a session handoff afterwards.

> **Why this exists.** `develop` carries PR #617 (#616, merge `bedd328`): migration
> `server/src/db/migrations/1788652804900-EntityIdsToUuid.ts` retypes 44 id columns TEXT → UUID and
> **refuses to run if any of its 22 business tables holds a row** (`up()`, lines 230–243 — owner decision:
> fresh database only, legacy `prefix+base36` ids cannot be cast). `mob04` holds the demo tenant
> `demo-344-20261005` (#344), so the first CD deploy after `develop` → `main` fails at
> `Apply database schema migrations` — cleanly (each migration is its own transaction,
> `migrationsTransactionMode: 'each'`; nothing has restarted yet) — and **every later deploy fails the
> same way until the data is wiped.** There are no down-migrations, so once it has run, code from before
> it can never run against this database again (every write → 22P02 / HTTP 500).

---

## 0. Rules (read before step 1)

- 🔴 **Merge `develop` → `main` with "Create a merge commit" only — never squash, never rebase.**
  `pos-deploy.sh`'s `ROLLBACK_FLOOR` is now `bedd328aa3ba1de8c56b5fe5753fd12deca5dd4f` and `deployable()`
  requires the floor to be an ancestor of the release *and* the release to be on `main`
  (`git merge-base --is-ancestor`). Squash/rebase leave `bedd328` off `main` → **every** deploy dies
  `is not a commit on main at or after …; nothing deployed`. Check after the merge:
  `git fetch origin && git merge-base --is-ancestor bedd328aa3ba1de8c56b5fe5753fd12deca5dd4f origin/main && echo floor-on-main`.
- 🔴 **Never `docker compose down -v`** — it destroys `pgdata`, `etcd-data`, `nginx-auth` and **`certs-ca`**
  (a new CA breaks every distributed APK). The wipe below is SQL only; no volume is touched.
- **Do not cutover with any unsent work on any device.** Legacy outbox ops carry non-UUID `opId`s: the new
  server's `/sync/push` refuses the **whole envelope** with 400 (`sync.dto.ts` `parseUuid(o.opId…)`), the
  client treats a request-level 4xx as "leave ops alone" (`sync_service.dart` ~398) so they stay `pending`
  forever, and `/sync/discards` refuses the same `opId` with 400 too — so discard is **not** an escape
  hatch. Result: shift close (`OUTBOX_NOT_EMPTY`) and re-enrol (`ENROL_UNSENT_WORK`) blocked on that
  device. The data is being wiped anyway, so the answer is step 1 + step 9: send/abandon, then clear.
- `.current_sha` on the VM is the only proof of a deploy. A green `Deploy (demo)` run is not.
- Every SQL block below is run as the `deploy` user in `/opt/pos` through the `postgres` container as the
  superuser (bypasses RLS — that is why the counts are real). Set this once per shell:
  ```bash
  cd /opt/pos && export IMAGE_TAG=$(cat .current_sha)   # vm.override.yml needs it for interpolation
  PSQL='docker compose -f docker-compose.yml -f vm.override.yml exec -T postgres psql -U postgres -d pos -v ON_ERROR_STOP=1'
  ```
  (`pos`/`postgres` = `backup-db.sh`'s defaults; if `/opt/pos/.env` sets other `POSTGRES_DB`/`POSTGRES_USER`, use those.)

---

## 1. Before the merge — stop the shop side

1. Tell everyone using the demo: stop selling, close the shift if one is open.
2. On every demo browser / APK, open the sync status and confirm **outbox = 0**. Anything that will not
   send is abandoned (the data is wiped in step 4 anyway) — write down which device, do not try to fix it.
3. bull-board (or Grafana `pos_queue_jobs`): no `active`/`waiting` jobs (an import job for a tenant that
   is about to vanish would just fail).

## 2. Merge, and hold the Deploy

1. Merge the `develop` → `main` PR with **Create a merge commit** (rule §0). Run the `floor-on-main` check.
2. CI on `main` goes green → `Deploy (demo)` starts and stops at **Waiting for review**. **Do not approve.**
   It waits; nothing reaches the VM until you approve.
3. If older Deploy runs are also waiting, cancel them now (a waiting job holds the `deploy-demo` slot).
4. Note the merge SHA: `M=$(git rev-parse origin/main)`.

## 3. Backup (on `mob04`, as `deploy`)

```bash
/opt/pos/scripts/backup-db.sh /opt/pos/backups
ls -l /opt/pos/backups | tail -3        # newest *_backup_*.sql.gz + .sha256, no .partial
gzip -t /opt/pos/backups/<newest>.sql.gz && echo gzip-ok
```

This dump (text ids) is restorable **only** with code below the floor and only onto a pre-#616 schema —
it is the "undo" for the whole cutover, not for a single step after it. Keep it.

## 4. Wipe (on `mob04`)

Inventory first, so the handoff records what was destroyed:

```bash
$PSQL -c "SELECT code, status, created_at FROM tenants ORDER BY created_at;"
$PSQL -c "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE n_live_tup > 0 ORDER BY 1;"
```

Then the wipe. **Which tables and why:**

- the **22 guarded tables** — copied from `GUARDED_TABLES` in the migration; the guard demands they are empty;
- **`tenants`, `users`, `tenant_meta`, `settings`, `categories`** — a tenant left without its devices has
  no enrolled device, and retire/enrol need one; re-provisioning through platform-ui (step 10) is the
  supported path and mints a fresh owner + enrol code. `users` also has to go because `owner_review_items`
  references it;
- **`idempotency_keys`** — stored replies hold old text ids; a replayed key would hand a client a
  pre-#616 response;
- **kept: `platform_admins`** (re-synced from `PLATFORM_ADMINS` at every api boot anyway) and the
  TypeORM `migrations` table.

This removes **every** tenant, including any `plan = 'loadtest'` tenants the #380 k6 runs left behind
(their setup re-creates them). That is 28 of the 29 tables. No `CASCADE` on purpose: if some table that is not in the list references one
that is, `TRUNCATE` errors and nothing is wiped — stop and ask, do not add `CASCADE`.

```bash
$PSQL <<'SQL'
BEGIN;
TRUNCATE TABLE
  devices, doc_counters, audit_log, products, suppliers, movements, customers, mechanics,
  credit_payments, sales, sale_items, returns, return_items, purchase_orders, po_items,
  quotes, quote_items, parked_sales, shifts, drawer_entries, import_jobs, owner_review_items,
  idempotency_keys, settings, categories, tenant_meta, users, tenants
  RESTART IDENTITY;
COMMIT;
SQL
```

## 5. Prove the guard will pass

The same check the migration makes — must print `ok`:

```bash
$PSQL <<'SQL'
DO $$
DECLARE t TEXT; has_rows BOOLEAN;
BEGIN
  FOREACH t IN ARRAY ARRAY['devices','doc_counters','audit_log','products','suppliers','movements',
    'customers','mechanics','credit_payments','sales','sale_items','returns','return_items',
    'purchase_orders','po_items','quotes','quote_items','parked_sales','shifts','drawer_entries',
    'import_jobs','owner_review_items'] LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I)', t) INTO has_rows;
    IF has_rows THEN RAISE EXCEPTION 'still has rows: %', t; END IF;
  END LOOP;
  RAISE NOTICE 'ok';
END $$;
SELECT (SELECT count(*) FROM tenants) AS tenants, (SELECT count(*) FROM platform_admins) AS platform_admins;
SQL
```

Expected: `NOTICE: ok`, `tenants = 0`, `platform_admins ≥ 1`. The old release is still serving; with no
tenants nobody can log in, which is what we want until step 7.

## 6. Reinstall `pos-deploy` **before** approving (as `cloud`, sudo)

Order matters. The Deploy run is executed by `/usr/local/bin/pos-deploy` **as installed on the VM**, not
the repo copy (07 §6.2 step 4). With the old floor (`4f3a244`) installed, a cutover deploy that fails
*after* the migration (e.g. readiness) is auto-rolled-back to the previous text-id release — onto the UUID
schema. With the new floor installed, that rollback is refused instead (`not rolling back to it`) and the
VM stays on the new release for you to fix forward.

```bash
rm -rf /tmp/pos-src && git clone --depth 1 https://github.com/NuimanLP/srisurart-pos-flutter.git /tmp/pos-src
grep -n '^readonly ROLLBACK_FLOOR=' /tmp/pos-src/deploy/scripts/pos-deploy.sh   # must be bedd328aa3ba…
sudo install -o root -g root -m 0755 /tmp/pos-src/deploy/scripts/pos-deploy.sh /usr/local/bin/pos-deploy
sha256sum /tmp/pos-src/deploy/scripts/pos-deploy.sh /usr/local/bin/pos-deploy  # the two must match
```

Only `pos-deploy.sh` changed (`runner-job-started.sh` and the sudoers line are untouched by this PR).

## 7. Approve and verify

1. Approve the waiting `Deploy (demo)` run for `M` (the approval API needs a comment).
2. When it finishes, on `mob04`:
   ```bash
   cat /opt/pos/.current_sha                                   # == M — the only proof
   curl -sk -o /dev/null -w "ready=%{http_code}\n" https://localhost/health/ready   # 200
   $PSQL -c "SELECT name FROM migrations ORDER BY id DESC LIMIT 1;"                 # EntityIdsToUuid1788652804900
   $PSQL -c "SELECT table_name, column_name, data_type FROM information_schema.columns
             WHERE (table_name, column_name) IN (('sales','id'),('devices','id'),('products','id'));"  # uuid ×3
   ```
3. If the run failed at the migration step: nothing restarted, the old release is still up. Read the
   `RAISE` message (`needs an empty database (table …)`), go back to step 4. With the new floor installed,
   `pos-deploy` will refuse its automatic rollback to the pre-#616 `running` release — that is expected
   here, not a second failure.
4. **From now on no rollback below `bedd328`**, by the runner *or* by hand (07 §6.2 manual Ansible path:
   its `merge-base --is-ancestor` check uses the new floor). The only way back is restoring the step-3 dump
   *and* deploying pre-floor code by hand — an owner decision, not a rollback.

## 8. Rebuild the APK

Run `android-apk.yml` (`workflow_dispatch`, `main`) for `M`. An APK built before #616 mints text ids and
every write is refused. Same keystore → installs over the old one, **but that keeps the old app data** —
see step 9.

## 9. Clear every demo client

- **Browsers:** DevTools → Application → Storage → *Clear site data* for the VM origin (IndexedDB holds
  the Drift DB, the outbox and the device/refresh token; the service worker may hold the old build), or
  use a fresh Incognito window for the demo.
- **Android:** Settings → Apps → the POS app → *Clear storage* (or uninstall) **before** installing the
  new APK.
- Do not try to "send" or "discard" what is left in an old outbox — see §0.

## 10. Re-provision and re-enrol

1. platform-ui (`127.0.0.1:3200` via the tunnel, as in `demo-344-checklist-2026-09-30.md` step 2) →
   create the tenant again (the code `demo-344-20261005` is free again, or pick a new one) → note the
   temp password + `enrolCode` (never into a file in the repo).
2. On a cleared client: log in as owner, change the temp password (forced), enrol with the `enrolCode`.
3. Smoke: open a shift, add a product, ring one cash sale. In psql, the new rows have UUID ids:
   `$PSQL -c "SELECT id FROM sales ORDER BY date DESC LIMIT 1;"`.
4. Write the session handoff (what ran, outputs, `.current_sha`) and add it to `INDEX.md`.

---

## Not covered / known gaps

- `server/src/sync/sync.dto.ts` (~line 140) says discard is how the owner clears an op push rejected; for a
  **non-UUID `opId`** that is false — `parseSyncDiscard` refuses it before reaching that code. Owned by
  #619; this runbook works around it by requiring empty outboxes + cleared clients.
- The shop itself still runs the Drift-only build (no cutover) and is untouched by any of this.
