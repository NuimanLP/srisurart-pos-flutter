#!/usr/bin/env bash
# Tests for deploy/scripts/backup-db.sh's dump step (a failed dump must not leave a
# pos_backup_*.sql.gz behind). Runs against stub `docker`/`pg_dump` binaries: no Docker or
# Postgres needed. Usage: deploy/scripts/test/backup-db.test.sh
# BACKUP_SCRIPT overrides the script under test (used to prove the test fails on the old script).
set -uo pipefail

SCRIPT="${BACKUP_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backup-db.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# `docker compose ps --services` succeeds with no services, so the script falls through to pg_dump.
printf '#!/bin/sh\nexit 0\n' > "$STUBS/docker"
# pg_dump: STUB_PG_DUMP_FAIL=1 writes a little output, then fails (like a dropped connection).
cat > "$STUBS/pg_dump" <<'STUB'
#!/bin/sh
echo "-- partial dump"
[ "${STUB_PG_DUMP_FAIL:-0}" = 1 ] && { echo "pg_dump: error: connection failed" >&2; exit 1; }
echo "CREATE TABLE t ();"
STUB
chmod +x "$STUBS/docker" "$STUBS/pg_dump"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

rc=0
run_backup() { # dir, fail-flag, [images dir], [sale photos dir] ; sets rc
  env -u POSTGRES_DB -u POSTGRES_USER -u BACKUP_KEEP_DAYS -u BACKUP_RCLONE_CONFIG -u BACKUP_VOLUMES \
    -u BACKUP_PRE_MIGRATE_KEEP_DAYS ${BACKUP_PRE_MIGRATE_KEEP_DAYS:+"BACKUP_PRE_MIGRATE_KEEP_DAYS=$BACKUP_PRE_MIGRATE_KEEP_DAYS"} \
    PATH="$STUBS:$PATH" IMAGE_TAG=test BACKUP_RCLONE_REMOTE='' STUB_PG_DUMP_FAIL="$2" \
    BACKUP_TEXTFILE_DIR="${TEXTFILE_DIR:-$WORK/no-textfile-dir}" ${BACKUP_VOLUMES:+"BACKUP_VOLUMES=$BACKUP_VOLUMES"} \
    PRODUCT_IMAGES_DIR="${3:-}" SALE_PHOTOS_DIR="${4:-}" \
    bash "$SCRIPT" "$1" >"$1.log" 2>&1
  rc=$?
}
count() { find "$1" -maxdepth 1 -name "$2" | wc -l | tr -d ' '; }

# 1. failing dump: non-zero exit, nothing that looks like a backup remains (no .partial either).
D="$WORK/fail"
mkdir -p "$D"
run_backup "$D" 1
check "failed dump exits non-zero" test "$rc" -ne 0
check "failed dump leaves no pos_backup_*.sql.gz" test "$(count "$D" 'pos_backup_*.sql.gz')" = 0
check "failed dump leaves no .partial" test "$(count "$D" '*.partial')" = 0
check "failed dump writes no .sha256" test "$(count "$D" '*.sha256')" = 0

# 2. good dump: exit 0, a valid gz + sha256 sidecar for the final file, no .partial.
D="$WORK/ok"
mkdir -p "$D"
run_backup "$D" 0
check "good dump exits 0" test "$rc" -eq 0
check "good dump produces one pos_backup_*.sql.gz" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
f="$(find "$D" -maxdepth 1 -name 'pos_backup_*.sql.gz' | head -1)"
check "good dump passes gzip -t" gzip -t "$f"
has_dump_and_ceiling() { gzip -dc "$1" | grep -q 'CREATE TABLE t' && gzip -dc "$1" | grep -q 'ALTER ROLE pos_app'; }
check "good dump contains the dump and the role ceiling block" has_dump_and_ceiling "$f"
check "good dump has a sha256 sidecar for the final file" test "$(count "$D" 'pos_backup_*.sql.gz.sha256')" = 1
check "good dump leaves no .partial" test "$(count "$D" '*.partial')" = 0

# 3. prune: a stale .partial (SIGKILL leftover) is removed by age, a fresh one is kept.
D="$WORK/prune"
mkdir -p "$D"
touch -t 202001010000 "$D/pos_backup_old.sql.gz.partial"
touch "$D/pos_backup_new.sql.gz.partial"
run_backup "$D" 0
check "prune run exits 0" test "$rc" -eq 0
check "stale .partial is pruned" test ! -e "$D/pos_backup_old.sql.gz.partial"
check "fresh .partial is kept" test -e "$D/pos_backup_new.sql.gz.partial"

# 3b. no product-images volume anywhere: a warning, no images archive, still exit 0.
D="$WORK/noimages"
mkdir -p "$D"
run_backup "$D" 0
check "no images volume exits 0" test "$rc" -eq 0
check "no images volume writes no images archive" test "$(count "$D" 'pos_images_*')" = 0
check "no images volume warns" grep -q '::warning::No product-images volume' "$D.log"
check "no sale-photos volume writes no sale-photos archive" test "$(count "$D" 'pos_sale_photos_*')" = 0
check "no sale-photos volume warns" grep -q '::warning::No sale-photos volume' "$D.log"

# 3c. product images (contract §2): a tar.gz of the volume with a sha256 sidecar, no .partial.
IMG="$WORK/images-src"
mkdir -p "$IMG/0192f000-0000-7000-8000-000000000001"
printf 'thumb' > "$IMG/0192f000-0000-7000-8000-000000000001/aaaaaaaabbbbbbbbccccccccdddddddd_t.webp"
D="$WORK/images"
mkdir -p "$D"
run_backup "$D" 0 "$IMG"
check "images run exits 0" test "$rc" -eq 0
check "images run writes one pos_images_*.tar.gz" test "$(count "$D" 'pos_images_*.tar.gz')" = 1
img="$(find "$D" -maxdepth 1 -name 'pos_images_*.tar.gz' | head -1)"
has_image() { tar -tzf "$1" | grep -q 'aaaaaaaabbbbbbbbccccccccdddddddd_t.webp'; }
check "images archive holds the image file" has_image "$img"
check "images archive has a sha256 sidecar" test "$(count "$D" 'pos_images_*.tar.gz.sha256')" = 1
sidecar_ok() { (cd "$D" && sha256sum -c "$(basename "$img").sha256" >/dev/null 2>&1); }
check "images sha256 sidecar verifies" sidecar_ok
check "images run leaves no .partial" test "$(count "$D" '*.partial')" = 0
check "images run still writes the database dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
check "images run without sale photos writes no sale-photos archive" test "$(count "$D" 'pos_sale_photos_*')" = 0

# 3c'. sale photos (10_SALE_PHOTO_EVIDENCE.md §5.4): their own tar.gz + sidecar, never mixed into
# the product-images archive, no .partial.
SP="$WORK/sale-photos-src"
mkdir -p "$SP/0192f000-0000-7000-8000-000000000001"
printf 'evidence' > "$SP/0192f000-0000-7000-8000-000000000001/eeeeeeeeffffffff0000000011111111_p.webp"
D="$WORK/salephotos"
mkdir -p "$D"
run_backup "$D" 0 "$IMG" "$SP"
check "sale photos run exits 0" test "$rc" -eq 0
check "sale photos run writes one pos_sale_photos_*.tar.gz" test "$(count "$D" 'pos_sale_photos_*.tar.gz')" = 1
sp="$(find "$D" -maxdepth 1 -name 'pos_sale_photos_*.tar.gz' | head -1)"
has_photo() { tar -tzf "$1" | grep -q 'eeeeeeeeffffffff0000000011111111_p.webp'; }
check "sale photos archive holds the photo" has_photo "$sp"
not_in_images() { ! tar -tzf "$(find "$D" -maxdepth 1 -name 'pos_images_*.tar.gz' | head -1)" | grep -q 'eeeeeeee'; }
check "the product-images archive does not hold the photo" not_in_images
check "sale photos archive has a sha256 sidecar" test "$(count "$D" 'pos_sale_photos_*.tar.gz.sha256')" = 1
sp_sidecar_ok() { (cd "$D" && sha256sum -c "$(basename "$sp").sha256" >/dev/null 2>&1); }
check "sale photos sha256 sidecar verifies" sp_sidecar_ok
check "sale photos run leaves no .partial" test "$(count "$D" '*.partial')" = 0

# 3c''. prune: old sale-photos archives, sidecars and a stale .partial age out too.
D="$WORK/spprune"
mkdir -p "$D"
for f in pos_sale_photos_old.tar.gz pos_sale_photos_old.tar.gz.sha256 pos_sale_photos_old.tar.gz.partial; do
  touch -t 202001010000 "$D/$f"
done
run_backup "$D" 0 "" "$SP"
check "sale photos prune run exits 0" test "$rc" -eq 0
check "old sale-photos archive + sidecar + .partial are pruned" test "$(count "$D" 'pos_sale_photos_old*')" = 0
check "this run's sale-photos archive is kept" test "$(count "$D" 'pos_sale_photos_*.tar.gz')" = 1

# 3d. prune: images archives and their sidecars age out with the dump; a stale images .partial too.
D="$WORK/imgprune"
mkdir -p "$D"
for f in pos_images_old.tar.gz pos_images_old.tar.gz.sha256 pos_images_old.tar.gz.partial; do
  touch -t 202001010000 "$D/$f"
done
run_backup "$D" 0 "$IMG"
check "images prune run exits 0" test "$rc" -eq 0
check "old images archive + sidecar + .partial are pruned" test "$(count "$D" 'pos_images_old*')" = 0
check "this run's images archive is kept" test "$(count "$D" 'pos_images_*.tar.gz')" = 1

# 3e. an images archive that is attempted and fails: the dump is kept, no images file, exit != 0.
cat > "$STUBS/tar" <<'STUB'
#!/bin/sh
echo "tar: write error" >&2
exit 2
STUB
chmod +x "$STUBS/tar"
D="$WORK/imgfail"
mkdir -p "$D"
run_backup "$D" 0 "$IMG"
rm -f "$STUBS/tar"
check "failed images archive exits non-zero" test "$rc" -ne 0
check "failed images archive leaves no pos_images_* (no .partial)" test "$(count "$D" 'pos_images_*')" = 0
check "failed images archive keeps the database dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
check "failed images archive says so" grep -q '::error::PRODUCT IMAGES ARCHIVE FAILED' "$D.log"

# 3f. a sale-photos archive that is attempted and fails (product images absent): same guarantees.
cat > "$STUBS/tar" <<'STUB'
#!/bin/sh
echo "tar: write error" >&2
exit 2
STUB
chmod +x "$STUBS/tar"
D="$WORK/spfail"
mkdir -p "$D"
run_backup "$D" 0 "" "$SP"
rm -f "$STUBS/tar"
check "failed sale-photos archive exits non-zero" test "$rc" -ne 0
check "failed sale-photos archive leaves no pos_sale_photos_* (no .partial)" test "$(count "$D" 'pos_sale_photos_*')" = 0
check "failed sale-photos archive keeps the database dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
check "failed sale-photos archive says so" grep -q '::error::SALE PHOTOS ARCHIVE FAILED' "$D.log"

# 3g. backup freshness gauge (07 §10, Grafana rule "backup stale"): a green nightly run writes
# pos_backup_last_success_timestamp_seconds for node-exporter's textfile collector, 0644, no tmp
# left behind; a failed run, and a DB-only run (BACKUP_VOLUMES=0, the pre-migrate dump), never do.
TF="$WORK/textfile"
mkdir -p "$TF"
D="$WORK/gauge"
mkdir -p "$D"
before="$(date -u +%s)"
TEXTFILE_DIR="$TF" run_backup "$D" 0
gauge_value() { awk '$1 == "pos_backup_last_success_timestamp_seconds" { print $2 }' "$TF/pos_backup.prom"; }
check "gauge run exits 0" test "$rc" -eq 0
check "gauge file is written" test -f "$TF/pos_backup.prom"
check "gauge value is this run's unix time" test "$(gauge_value)" -ge "$before"
check "gauge file declares a gauge" grep -qx '# TYPE pos_backup_last_success_timestamp_seconds gauge' "$TF/pos_backup.prom"
mode_ok() { [ "$(stat -c %a "$TF/pos_backup.prom" 2>/dev/null || stat -f %Lp "$TF/pos_backup.prom")" = 644 ]; }
check "gauge file is world-readable (0644) for node-exporter" mode_ok
check "gauge write leaves no tmp file" test "$(find "$TF" -name '.pos_backup.prom.*' | wc -l | tr -d ' ')" = 0
printf 'pos_backup_last_success_timestamp_seconds 1\n' > "$TF/pos_backup.prom"
D="$WORK/gauge-dbonly"
mkdir -p "$D"
TEXTFILE_DIR="$TF" BACKUP_VOLUMES=0 run_backup "$D" 0
check "DB-only run exits 0" test "$rc" -eq 0
check "DB-only run (BACKUP_VOLUMES=0) does not touch the gauge" test "$(gauge_value)" = 1
D="$WORK/gauge-fail"
mkdir -p "$D"
TEXTFILE_DIR="$TF" run_backup "$D" 1
check "failed run does not touch the gauge" test "$(gauge_value)" = 1
D="$WORK/gauge-nodir"
mkdir -p "$D"
run_backup "$D" 0
check "missing textfile dir still exits 0" test "$rc" -eq 0
check "missing textfile dir warns" grep -q 'backup freshness gauge was not written' "$D.log"
# A textfile dir this user cannot write in (created by hand as root): the backup is still green.
# Skipped where chmod does not stop the owner writing (root, Git Bash on Windows).
RO="$WORK/textfile-ro"
mkdir -p "$RO"
chmod 0555 "$RO"
if ! (: >"$RO/.probe") 2>/dev/null; then
  D="$WORK/gauge-rodir"
  mkdir -p "$D"
  TEXTFILE_DIR="$RO" run_backup "$D" 0
  check "unwritable textfile dir still exits 0" test "$rc" -eq 0
  check "unwritable textfile dir warns" grep -q 'backup freshness gauge was not written' "$D.log"
else
  echo "skip - unwritable textfile dir (this user can write through 0555)"
fi
chmod 0755 "$RO"

# 4. the real mob04 path: compose lists a postgres service, `exec` fails -> same guarantees.
cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
case "$*" in
  *"ps --services"*) echo postgres; exit 0 ;;
  *exec*) echo "Error: service postgres is not running" >&2; exit 1 ;;
esac
exit 0
STUB
D="$WORK/compose"
mkdir -p "$D"
run_backup "$D" 0
check "failed compose exec exits non-zero" test "$rc" -ne 0
check "failed compose exec leaves no .sql.gz/.partial" test "$(count "$D" 'pos_backup_*')" = 0

# 5. the mob04 path for images: compose runs postgres AND nginx; the images are read through
# `exec -T nginx tar` from the read-only /srv/product-images mount.
cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
case "$*" in
  *"ps --services"*) printf 'postgres\nnginx\nworker\n'; exit 0 ;;
  *"exec -T postgres pg_dump"*) echo "CREATE TABLE t ();"; exit 0 ;;
  *"exec -T nginx test -d /srv/product-images"*) exit 0 ;;
  *"exec -T nginx tar -cf - -C /srv/product-images ."*) tar -cf - -C "$STUB_IMG" . ; exit $? ;;
  *"exec -T worker test -d /app/sale-photos"*) exit 0 ;;
  *"exec -T worker tar -cf - -C /app/sale-photos ."*) tar -cf - -C "$STUB_SP" . ; exit $? ;;
esac
exit 1
STUB
D="$WORK/vm"
mkdir -p "$D"
STUB_IMG="$IMG" STUB_SP="$SP" run_backup "$D" 0
check "vm path exits 0" test "$rc" -eq 0
check "vm path archives the images through nginx" has_image "$(find "$D" -maxdepth 1 -name 'pos_images_*.tar.gz' | head -1)"
check "vm path archives the sale photos through the worker" has_photo "$(find "$D" -maxdepth 1 -name 'pos_sale_photos_*.tar.gz' | head -1)"

# 6. compose lists the worker but `exec` into it fails: the sale photos are a FAILED archive
# (loud, non-zero), never "no volume" — the dump and the product-images archive are kept.
cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
case "$*" in
  *"ps --services"*) printf 'postgres\nnginx\nworker\n'; exit 0 ;;
  *"exec -T postgres pg_dump"*) echo "CREATE TABLE t ();"; exit 0 ;;
  *"exec -T nginx test -d /srv/product-images"*) exit 0 ;;
  *"exec -T nginx tar -cf - -C /srv/product-images ."*) tar -cf - -C "$STUB_IMG" . ; exit $? ;;
  *"exec -T worker"*) echo "Error: service worker is not running" >&2; exit 1 ;;
esac
exit 1
STUB
D="$WORK/vmworkerdown"
mkdir -p "$D"
STUB_IMG="$IMG" run_backup "$D" 0 "" "$SP"
check "worker exec failure exits non-zero" test "$rc" -ne 0
check "worker exec failure says SALE PHOTOS ARCHIVE FAILED" grep -q '::error::SALE PHOTOS ARCHIVE FAILED' "$D.log"
check "worker exec failure is not reported as a missing volume" test -z "$(grep '::warning::No sale-photos volume' "$D.log")"
check "worker exec failure writes no pos_sale_photos_* (no .partial)" test "$(count "$D" 'pos_sale_photos_*')" = 0
check "worker exec failure keeps the database dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
check "worker exec failure keeps the product-images archive" test "$(count "$D" 'pos_images_*.tar.gz')" = 1

# 7. BACKUP_VOLUMES=0 (the pre-migration dump): dump only, even with both volume dirs present;
# the default (unset) and BACKUP_VOLUMES=1 still archive them.
printf '#!/bin/sh\nexit 0\n' > "$STUBS/docker" # neutral stub again (section 6 replaced it)
D="$WORK/dbonly"
mkdir -p "$D" "$WORK/v_img" "$WORK/v_sp"
echo x > "$WORK/v_img/a.webp"
echo y > "$WORK/v_sp/b.webp"
BACKUP_VOLUMES=0 run_backup "$D" 0 "$WORK/v_img" "$WORK/v_sp"
check "BACKUP_VOLUMES=0 exits 0" test "$rc" -eq 0
check "BACKUP_VOLUMES=0 still writes the dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
check "BACKUP_VOLUMES=0 archives no product images" test "$(count "$D" 'pos_images_*')" = 0
check "BACKUP_VOLUMES=0 archives no sale photos" test "$(count "$D" 'pos_sale_photos_*')" = 0
check "BACKUP_VOLUMES=0 does not warn about a missing volume" test -z "$(grep 'No product-images volume\|No sale-photos volume' "$D.log")"
D="$WORK/dbonly_fail"
mkdir -p "$D"
BACKUP_VOLUMES=0 run_backup "$D" 1
check "BACKUP_VOLUMES=0 with a failing dump exits non-zero" test "$rc" -ne 0
check "BACKUP_VOLUMES=0 with a failing dump leaves no dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 0
D="$WORK/vol_default"
mkdir -p "$D"
run_backup "$D" 0 "$WORK/v_img" "$WORK/v_sp"
check "default still archives product images" test "$(count "$D" 'pos_images_*.tar.gz')" = 1
check "default still archives sale photos" test "$(count "$D" 'pos_sale_photos_*.tar.gz')" = 1

# 8. BACKUP_VOLUMES=0 on the mob04 compose path, mid-deploy: compose lists nginx and a worker
# that cannot be exec'd into (the old release's worker). The dump must not touch either service.
cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_CALLS"
case "$*" in
  *"ps --services"*) printf 'postgres\nnginx\nworker\n'; exit 0 ;;
  *"exec -T postgres pg_dump"*) echo "CREATE TABLE t ();"; exit 0 ;;
  *"exec -T worker"*) echo "Error: service worker is not running" >&2; exit 1 ;;
esac
exit 1
STUB
D="$WORK/dbonly_vm"
mkdir -p "$D"
: > "$WORK/dbonly_vm.calls"
STUB_CALLS="$WORK/dbonly_vm.calls" BACKUP_VOLUMES=0 run_backup "$D" 0
check "BACKUP_VOLUMES=0 on the compose path exits 0 with an unreachable worker" test "$rc" -eq 0
check "BACKUP_VOLUMES=0 on the compose path writes the dump" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
check "BACKUP_VOLUMES=0 never execs into nginx or the worker" test -z "$(grep -E 'exec -T (nginx|worker)' "$WORK/dbonly_vm.calls")"

# 9. the nightly run also ages out $APP_DIR/backups-pre-migrate (default 30 days): top level only,
# only this script's file names; a BACKUP_VOLUMES=0 (pre-migrate) run never prunes it from outside.
printf '#!/bin/sh\nexit 0\n' > "$STUBS/docker" # neutral stub again (section 8 replaced it)
A="$WORK/app9"
PM="$A/backups-pre-migrate"
mkdir -p "$A/backups" "$PM/nested"
seed_pre_migrate() {
  touch -t 202001010000 "$PM/pos_backup_old.sql.gz" "$PM/pos_backup_old.sql.gz.sha256" \
    "$PM/pos_backup_old.sql.gz.partial" "$PM/nested/pos_backup_deep.sql.gz" "$PM/notes.txt"
  touch "$PM/pos_backup_new.sql.gz" "$PM/pos_backup_new.sql.gz.sha256"
}
seed_pre_migrate
APP_DIR="$A" BACKUP_VOLUMES=0 run_backup "$WORK/app9_other" 0
check "BACKUP_VOLUMES=0 run exits 0" test "$rc" -eq 0
check "BACKUP_VOLUMES=0 run leaves pre-migrate dumps to their own run" test -e "$PM/pos_backup_old.sql.gz"
APP_DIR="$A" run_backup "$A/backups" 0
check "nightly run exits 0" test "$rc" -eq 0
check "nightly run prunes a pre-migrate dump older than 30 days" test ! -e "$PM/pos_backup_old.sql.gz"
check "nightly run prunes its sha256 sidecar and stale .partial" \
  test ! -e "$PM/pos_backup_old.sql.gz.sha256" -a ! -e "$PM/pos_backup_old.sql.gz.partial"
check "nightly run keeps a fresh pre-migrate dump + sidecar" \
  test -e "$PM/pos_backup_new.sql.gz" -a -e "$PM/pos_backup_new.sql.gz.sha256"
check "nightly run never descends below backups-pre-migrate" test -e "$PM/nested/pos_backup_deep.sql.gz"
check "nightly run never removes a file it did not write" test -e "$PM/notes.txt"
seed_pre_migrate
APP_DIR="$A" BACKUP_PRE_MIGRATE_KEEP_DAYS=0 run_backup "$A/backups" 0
check "BACKUP_PRE_MIGRATE_KEEP_DAYS=0 disables the pre-migrate prune" test -e "$PM/pos_backup_old.sql.gz"

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
