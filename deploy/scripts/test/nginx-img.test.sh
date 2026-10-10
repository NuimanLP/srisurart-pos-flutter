#!/usr/bin/env bash
# Functional test of server/docker/nginx/nginx.conf's product-image and import locations
# (contract §2/§4) against the real nginx image: /img/ serves exactly
# /img/<tenant uuid>/<32 hex>_{t,p}.webp from the volume with the immutable headers, refuses
# everything else, and the import locations — only they — take a body past 10m.
# Needs docker, openssl, curl. Usage: deploy/scripts/test/nginx-img.test.sh
# NGINX_IMAGE overrides the image (keep it the docker-compose.yml one).
set -uo pipefail
# The Windows MSYS shell rewrites anything that looks like a path (`/CN=…`, container paths);
# host paths for `docker -v` go through `host_path` instead. No effect elsewhere.
export MSYS_NO_PATHCONV=1
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
IMAGE="${NGINX_IMAGE:-nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de}"
WORK="$(mktemp -d "$ROOT/.tmp-nginx-img.XXXXXX")"
NAME="nginx-img-test-$$"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

TENANT="0192f000-0000-7000-8000-000000000001"
KEY="aaaaaaaabbbbbbbbccccccccdddddddd"
mkdir -p "$WORK/certs" "$WORK/auth" "$WORK/images/$TENANT"
# Relative paths: a native openssl on Windows cannot open an MSYS-style /d/… path.
(cd "$WORK/certs" && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -keyout server.key -out server.crt >/dev/null 2>&1) || { echo "FAIL - openssl"; exit 1; }
printf 'dummy:%s\n' "$(openssl passwd -apr1 dummy)" > "$WORK/auth/k6-remote-write.htpasswd"
printf 'thumb-bytes' > "$WORK/images/$TENANT/${KEY}_t.webp"
printf 'preview-bytes' > "$WORK/images/$TENANT/${KEY}_p.webp"
chmod -R a+rX "$WORK"

docker run -d --name "$NAME" -p 127.0.0.1::443 \
  -v "$(host_path "$ROOT/server/docker/nginx/nginx.conf"):/etc/nginx/nginx.conf:ro" \
  -v "$(host_path "$WORK/certs"):/etc/nginx/certs:ro" \
  -v "$(host_path "$WORK/auth"):/etc/nginx/auth:ro" \
  -v "$(host_path "$WORK/images"):/srv/product-images:ro" \
  "$IMAGE" >/dev/null || { echo "FAIL - nginx container did not start"; exit 1; }

PORT=""
for _ in $(seq 1 50); do
  PORT="$(docker port "$NAME" 443/tcp 2>/dev/null | head -1 | sed 's/.*://')"
  [[ -n "$PORT" ]] && curl -sk -o /dev/null "https://127.0.0.1:$PORT/" && break
  sleep 0.2
done
if [[ -z "$PORT" ]]; then
  docker logs "$NAME"
  echo "FAIL - nginx never answered"
  exit 1
fi
BASE="https://127.0.0.1:$PORT"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}
status() { curl -sk --path-as-is -o /dev/null -w '%{http_code}' "$@"; }
header() { curl -sk --path-as-is -D - -o /dev/null "$1" | tr -d '\r' | grep -i "^$2:" | head -1 | cut -d' ' -f2-; }

T="$BASE/img/$TENANT/${KEY}_t.webp"
check "thumbnail: 200" test "$(status "$T")" = 200
check "thumbnail: the file's bytes" test "$(curl -sk "$T")" = thumb-bytes
check "preview: 200 with its bytes" test "$(curl -sk "$BASE/img/$TENANT/${KEY}_p.webp")" = preview-bytes
check "Content-Type image/webp" test "$(header "$T" Content-Type)" = image/webp
check "Cache-Control immutable for a year" test "$(header "$T" Cache-Control)" = "public, max-age=31536000, immutable"
check "X-Content-Type-Options nosniff" test "$(header "$T" X-Content-Type-Options)" = nosniff
check "HEAD: 200" test "$(status -I "$T")" = 200
check "POST: refused (403)" test "$(status -X POST "$T")" = 403
check "PUT: refused (403)" test "$(status -X PUT --data x "$T")" = 403

MISSING="$BASE/img/$TENANT/ffffffffffffffffffffffffffffffff_t.webp"
check "missing file: 404" test "$(status "$MISSING")" = 404
check "missing file: no long-cache header" test -z "$(header "$MISSING" Cache-Control | grep immutable)"
check "tenant directory: 404 (no listing)" test "$(status "$BASE/img/$TENANT/")" = 404
check "volume root: 404" test "$(status "$BASE/img/")" = 404
check "non-uuid tenant: 404" test "$(status "$BASE/img/not-a-tenant/${KEY}_t.webp")" = 404
check "upper-case key: 404" test "$(status "$BASE/img/$TENANT/${KEY^^}_t.webp")" = 404
check "unknown variant: 404" test "$(status "$BASE/img/$TENANT/${KEY}_x.webp")" = 404
check "other extension: 404" test "$(status "$BASE/img/$TENANT/${KEY}_t.png")" = 404
# nginx normalises `..` before matching, so a traversal can only land on another /img/ path of
# the same shape — or leave /img/ entirely, where no volume file is reachable.
no_passwd() { ! curl -sk --path-as-is "$1" | grep -q 'root:'; }
check "traversal out of the volume: no host file" no_passwd "$BASE/img/$TENANT/../../../../etc/passwd"
check "encoded traversal: not served" test "$(status "$BASE/img/$TENANT/%2e%2e/${KEY}_t.webp")" != 200

# Body limits: 11 MB is past the server-level 10m. Only the import locations let it through to
# the (absent, so 502) upstream; everywhere else nginx answers 413 itself.
head -c $((11 * 1024 * 1024)) /dev/zero > "$WORK/big.bin"
# Relative @file: a native curl on Windows cannot open an MSYS-style /d/… path.
post_big() { (cd "$WORK" && status -X POST -H 'Content-Type: application/zip' --data-binary @big.bin "$BASE$1"); }
check "11 MB to /api/v1/backup/import: not refused by nginx" test "$(post_big /api/v1/backup/import)" != 413
check "11 MB to /api/v1/products: 413" test "$(post_big /api/v1/products)" = 413
check "11 MB to /api/v1/backup/import/<job>: 413 (exact location only)" test "$(post_big /api/v1/backup/import/$TENANT)" = 413
# The platform import regex repeats the admin allowlist: a client from the docker bridge is refused.
check "platform import from a non-admin IP: 403" test "$(status -X POST "$BASE/api/v1/platform/tenants/$TENANT/import")" = 403

if [ "$fails" -eq 0 ]; then echo "all passed"; else docker logs "$NAME" 2>&1 | tail -20; echo "$fails failed"; exit 1; fi
