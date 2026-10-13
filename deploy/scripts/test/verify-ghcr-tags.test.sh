#!/usr/bin/env bash
# Tests for deploy/scripts/verify-ghcr-tags.sh against a stub `curl`: no network, no registry.
# Usage: deploy/scripts/test/verify-ghcr-tags.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify-ghcr-tags.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# The token request (…/token?…) answers a token. A manifest request answers STUB_<SERVER|WEB>_CODE
# (default 200) on -w's stdout and writes STUB_<SERVER|WEB>_BODY (a file) to -o. CURL_LOG gets argv.
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CURL_LOG"
out='' prev='' url=''
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"
  prev="$a"
  url="$a"
done
if [[ "$url" == *"/token?"* ]]; then
  echo '{"token":"stub-token"}'
  exit 0
fi
case "$url" in
  *srisurart-pos-server*) code="${STUB_SERVER_CODE:-200}" body="${STUB_SERVER_BODY:-}" ;;
  *srisurart-pos-web*) code="${STUB_WEB_CODE:-200}" body="${STUB_WEB_BODY:-}" ;;
  *) code=500 body='' ;;
esac
if [[ -n "$out" ]]; then
  if [[ -n "$body" ]]; then cat "$body" > "$out"; else : > "$out"; fi
fi
printf '%s' "$code"
STUB
chmod +x "$STUBS/curl"

# Manifest bodies, shaped like GHCR's answers.
INDEX_BOTH="$WORK/index-both.json"      # OCI index, pretty-printed, with buildx attestations
cat > "$INDEX_BOTH" <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    { "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:aa", "size": 1,
      "platform": { "architecture": "amd64", "os": "linux" } },
    { "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:bb", "size": 1,
      "platform": { "architecture": "arm64", "os": "linux" } },
    { "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:cc", "size": 1,
      "annotations": { "vnd.docker.reference.type": "attestation-manifest" },
      "platform": { "architecture": "unknown", "os": "unknown" } }
  ]
}
JSON
LIST_AMD64="$WORK/list-amd64.json"      # Docker manifest list, compact, amd64 only
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","manifests":[{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"sha256:aa","size":1,"platform":{"architecture":"amd64","os":"linux"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:cc","size":1,"platform":{"architecture":"unknown","os":"unknown"}}]}' > "$LIST_AMD64"
LIST_V8="$WORK/list-v8.json"            # Docker manifest list, arm64 spelled with its variant, os first
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","manifests":[{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"sha256:aa","size":1,"platform":{"os":"linux","architecture":"amd64"}},{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"sha256:bb","size":1,"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}' > "$LIST_V8"
SINGLE="$WORK/single.json"              # a legacy single-image tag (every pre-multi-arch release)
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","size":1,"digest":"sha256:dd"},"layers":[]}' > "$SINGLE"
GARBAGE="$WORK/garbage.json"
printf '%s' '<html>proxy error</html>' > "$GARBAGE"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

rc=0
out=''
run() { # args... ; the stub's env comes from the RUN_ENV array
  export CURL_LOG="$WORK/curl.log"
  : > "$CURL_LOG"
  out="$(env PATH="$STUBS:$PATH" "${RUN_ENV[@]}" bash "$SCRIPT" "$@" 2>&1)"
  rc=$?
}
has() { grep -qF -- "$1" <<<"$out"; }

# 1. no platform arg = today's behaviour: 404 → 1, 500 → 2, 200 → 0 whatever the body.
RUN_ENV=(STUB_SERVER_CODE=404)
run abc123
check "no arg: a missing server image exits 1" test "$rc" -eq 1
check "no arg: says 'not both on GHCR yet'" has "are not both on GHCR yet"
RUN_ENV=(STUB_WEB_CODE=500)
run abc123
check "no arg: HTTP 500 exits 2" test "$rc" -eq 2
check "no arg: says it could not verify" has "Could not verify the release images"
RUN_ENV=(STUB_SERVER_BODY="$SINGLE" STUB_WEB_BODY="$INDEX_BOTH")
run abc123
check "no arg: a single manifest and an index both exit 0" test "$rc" -eq 0
check "no arg: prints the unchanged success line" has "Both server and web images for tag 'abc123' are verified on GHCR."
RUN_ENV=(STUB_SERVER_BODY="$GARBAGE" STUB_WEB_BODY="$GARBAGE")
run abc123
check "no arg: the body is never parsed (200 alone is enough)" test "$rc" -eq 0
accepts_lists() { grep -q 'manifest.list.v2+json' "$CURL_LOG" && grep -q 'oci.image.index.v1+json' "$CURL_LOG"; }
check "both list media types are in Accept" accepts_lists

# 2. platform arg.
RUN_ENV=(STUB_SERVER_BODY="$INDEX_BOTH" STUB_WEB_BODY="$INDEX_BOTH")
run abc123 linux/arm64
check "index with both: arm64 exits 0" test "$rc" -eq 0
check "index with both: success line names the platform" has "verified on GHCR for linux/arm64"
run abc123 linux/amd64
check "index with both: amd64 exits 0" test "$rc" -eq 0

RUN_ENV=(STUB_SERVER_BODY="$INDEX_BOTH" STUB_WEB_BODY="$LIST_AMD64")
run abc123 linux/arm64
check "index missing arm64: exits 2" test "$rc" -eq 2
check "index missing arm64: distinct 'not built for' message" has "was not built for linux/arm64"
check "index missing arm64: lists what it has, attestation left out" has "holds no linux/arm64 image (has: linux/amd64)"

RUN_ENV=(STUB_SERVER_BODY="$LIST_V8" STUB_WEB_BODY="$LIST_V8")
run abc123 linux/arm64
check "linux/arm64/v8 counts as linux/arm64" test "$rc" -eq 0

RUN_ENV=(STUB_SERVER_BODY="$LIST_AMD64" STUB_WEB_BODY="$LIST_AMD64")
run abc123 linux/amd64
check "attestation entry ignored: amd64-only list exits 0 for amd64" test "$rc" -eq 0

RUN_ENV=(STUB_SERVER_BODY="$SINGLE" STUB_WEB_BODY="$SINGLE")
run abc123 linux/amd64
check "legacy single manifest: amd64 exits 0" test "$rc" -eq 0
run abc123 linux/arm64
check "legacy single manifest: arm64 exits 2" test "$rc" -eq 2
check "legacy single manifest: arm64 says not built for it" has "was not built for linux/arm64"

RUN_ENV=(STUB_SERVER_BODY="$GARBAGE" STUB_WEB_BODY="$INDEX_BOTH")
run abc123 linux/amd64
check "unreadable manifest with a platform: exits 2" test "$rc" -eq 2

RUN_ENV=(STUB_SERVER_CODE=404 STUB_WEB_BODY="$INDEX_BOTH")
run abc123 linux/arm64
check "platform arg: a missing image is still 'not yet' (1)" test "$rc" -eq 1

RUN_ENV=(STUB_SERVER_CODE=500 STUB_WEB_BODY="$SINGLE")
run abc123 linux/arm64
check "platform arg: a registry error beats a missing platform (2, could not verify)" has "Could not verify the release images"

# 3. usage.
RUN_ENV=()
run
check "no tag: exits 2" test "$rc" -eq 2
run abc123 linux/riscv64
check "unknown platform: exits 2" test "$rc" -eq 2
run abc123 linux/amd64 extra
check "three args: exits 2" test "$rc" -eq 2

if [[ "$fails" -ne 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all verify-ghcr-tags.sh checks passed"
