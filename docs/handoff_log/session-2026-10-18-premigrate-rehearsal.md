# Pre-migrate dump rehearsal (2026-10-18)

Goal: run once, on a throwaway local stack, the path `deploy/ansible/deploy.yml` takes before migrating
("Check whether database migrations are pending" -> "Back up the database before applying migrations",
`07_CICD_DEPLOY.md` §6 step 3b). It had never run for real on `mob04`. Nothing touched `mob04`.

## Setup
- Docker Desktop on the dev PC; GHCR images, no build. Old = `ec311218…` (25 migrations, no `SalePhotos`),
  new = `21ad9358…` (26). Compose project `premigrate-rehearsal-19480` (own volume `pgdata`).
- APP_DIR laid out like `/opt/pos` (`docker-compose.yml`, `vm.override.yml`, `docker/postgres/init`, dev
  `.env` from `server/.env.example`). Only postgres + migrate were started.
- Deviation: the compose file pins subnet `172.30.0.0/24`, which collides with the dev PC's own running
  `srisurart-pos` stack. In the TEMP copy of `docker-compose.yml` only, I changed it to `172.31.77.0/24`.
  The repo file is untouched. That stack was left running and untouched throughout.
- `COMPOSE_PROJECT_NAME` was put in the temp `.env` so `backup-db.sh` (which passes no `-p`) hit my project
  and not `srisurart-pos` (`vm.override.yml` has `name: srisurart-pos`). On `mob04` that name is what you want.

## Run (all rc as observed)
1. Old image `migrate` -> 25 applied; `migrate.js status` -> "up to date". Inserted tenant row `rehearsal`.
2. New image: `run --rm migrate node dist/db/migrate.js status` -> "pending migrations exist", **rc=1**.
3. `backup-db.sh <APP_DIR>/backups-pre-migrate` with `BACKUP_VOLUMES=0 BACKUP_KEEP_DAYS=30
   BACKUP_RCLONE_REMOTE="" IMAGE_TAG APP_DIR` -> rc=0, `pos_backup_<ts>.sql.gz` (10 KB) + `.sha256` (101 B).
   `gzip -t` ok; `sha256sum -c` OK; dump holds the `rehearsal` tenant and the `ALTER ROLE pos_app … 25s/5s`
   lines; offsite `::warning::` printed; `node-textfile/` stayed EMPTY (gauge NOT written, as intended).
4. `migrate` (up) with the new image -> `applied: SalePhotos1788652805200`, rc=0; status "up to date";
   `sale_photos` exists.
5. `restore-db.sh <dump>` (in place, `--clean --create`: the rollback path): checksum verified, SQL applied,
   `pos_app` ceiling 25s/5s verified, tenant back, `sale_photos` gone, 25 migration rows.
6. Failure path, both exit 1, no file left behind (only the good dump + sidecar remain):
   A. postgres up, `POSTGRES_DB=doesnotexist` -> `pg_dump: … database "doesnotexist" does not exist`, rc=1.
   B. postgres stopped -> `::error::Neither active docker compose postgres container nor local pg_dump
      command found.`, rc=1.
   `deploy.yml` has no `ignore_errors` on the dump task, so either stops the deploy before `migrate`.
7. Teardown: `docker compose -p premigrate-rehearsal-19480 down -v --remove-orphans`; no container, volume
   or network with that name is left.

## BUG FOUND: `restore-db.sh` exits 1 after a fully successful restore
Last step runs `SELECT COUNT(*) FROM typeorm_migrations;` (`deploy/scripts/restore-db.sh:156`). The table
is `migrations` (TypeORM default; no `migrationsTableName` anywhere in `server/src`). Observed:
`ERROR: relation "typeorm_migrations" does not exist` -> `restore rc=1`, and the "Restore & Verification
Succeeded" line is never printed. The data itself was restored correctly (verified by hand). Impact: a
real restore reads as failed, in the one moment someone is under pressure. Not fixed here (rehearsal PR,
docs only). One-line fix: `migrations`. Worth a restore test that checks the exit code.

## Proven / not proven
Proven: pending-detection rc, dump + checksum + prune call, gauge skipped, migrate up, restore of that
dump to the pre-migrate state, failure exits. Not proven: anything on `mob04` itself (Ansible `script`
module shipping the file, `/opt/pos` permissions for `deploy` user, real volume sizes/time), a restore into
a *separate* database (the dump is `--create --clean`, so it replaces `pos`), a Linux host run (I ran it
from Git Bash on Windows), and the `rc != 0` check treating a docker error the same as "pending"
(it does; that is safe-side, it just takes a dump).
