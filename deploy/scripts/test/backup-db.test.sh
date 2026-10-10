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
run_backup() { # dir, fail-flag, [images dir] ; sets rc
  env -u POSTGRES_DB -u POSTGRES_USER -u BACKUP_KEEP_DAYS -u BACKUP_RCLONE_CONFIG \
    PATH="$STUBS:$PATH" IMAGE_TAG=test BACKUP_RCLONE_REMOTE='' STUB_PG_DUMP_FAIL="$2" \
    PRODUCT_IMAGES_DIR="${3:-}" \
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
  *"ps --services"*) printf 'postgres\nnginx\n'; exit 0 ;;
  *"exec -T postgres pg_dump"*) echo "CREATE TABLE t ();"; exit 0 ;;
  *"exec -T nginx test -d /srv/product-images"*) exit 0 ;;
  *"exec -T nginx tar -cf - -C /srv/product-images ."*) tar -cf - -C "$STUB_IMG" . ; exit $? ;;
esac
exit 1
STUB
D="$WORK/vm"
mkdir -p "$D"
STUB_IMG="$IMG" run_backup "$D" 0
check "vm path exits 0" test "$rc" -eq 0
check "vm path archives the images through nginx" has_image "$(find "$D" -maxdepth 1 -name 'pos_images_*.tar.gz' | head -1)"

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
