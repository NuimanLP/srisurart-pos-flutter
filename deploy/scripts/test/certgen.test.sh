#!/usr/bin/env bash
# Tests for server/docker/certgen/certgen.sh against the host's openssl (3.x): a fresh volume gets
# a CA + a server cert it signs with the mob04 IP in its SAN, a re-run changes nothing, and an
# existing volume holding the old CN=localhost self-signed cert gets a CA-signed one without the
# CA changing. Usage: deploy/scripts/test/certgen.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/server/docker/certgen/certgen.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CERTS_DIR="$WORK/certs" CA_DIR="$WORK/ca"
mkdir -p "$CERTS_DIR" "$CA_DIR"
# Git Bash only: keep "/CN=..." from being rewritten into a Windows path. No-op on Linux.
export MSYS2_ARG_CONV_EXCL="/CN"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}
run_certgen() { sh "$SCRIPT" >"$WORK/out" 2>&1 || { cat "$WORK/out"; return 1; }; }
verifies() { openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/server.crt" >/dev/null 2>&1; }
not_verifies() { ! verifies; }
san() { openssl x509 -in "$CERTS_DIR/server.crt" -noout -ext subjectAltName | sed -n '2s/^ *//p'; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }
key_matches_cert() {
  [ "$(openssl pkey -in "$CERTS_DIR/server.key" -pubout)" = \
    "$(openssl x509 -in "$CERTS_DIR/server.crt" -noout -pubkey)" ]
}
is_ca() { openssl x509 -in "$1" -noout -ext basicConstraints | grep -q 'CA:TRUE'; }
not_ca() { openssl x509 -in "$1" -noout -ext basicConstraints | grep -q 'CA:FALSE'; }

# 1. Fresh volumes.
check "fresh run succeeds" run_certgen
check "server cert verifies against the CA" verifies
check "SAN is localhost, 127.0.0.1 and 172.30.58.20" \
  test "$(san)" = "DNS:localhost, IP Address:127.0.0.1, IP Address:172.30.58.20"
check "server key matches server cert" key_matches_cert
check "CA cert is a CA" is_ca "$CA_DIR/ca.crt"
check "server cert is not a CA" not_ca "$CERTS_DIR/server.crt"
check "CA key never lands in the nginx-readable volume" test ! -e "$CERTS_DIR/ca.key"
check "ca.crt copied for platform-ui" cmp -s "$CA_DIR/ca.crt" "$CERTS_DIR/ca.crt"

# 2. Re-run with a good cert is a no-op.
ca_fp="$(fp "$CA_DIR/ca.crt")"
leaf_fp="$(fp "$CERTS_DIR/server.crt")"
check "re-run succeeds" run_certgen
check "re-run keeps the server cert" test "$(fp "$CERTS_DIR/server.crt")" = "$leaf_fp"
check "re-run keeps the CA" test "$(fp "$CA_DIR/ca.crt")" = "$ca_fp"

# 3. Upgrade: the volume still holds certgen's old self-signed CN=localhost cert (no SAN).
rm -f "$CERTS_DIR/server.crt" "$CERTS_DIR/server.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=localhost" \
  -keyout "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.crt" >/dev/null 2>&1
check "old self-signed cert does not verify (precondition)" not_verifies
check "upgrade run succeeds" run_certgen
check "upgraded cert verifies against the unchanged CA" verifies
check "upgrade kept the CA" test "$(fp "$CA_DIR/ca.crt")" = "$ca_fp"
check "upgraded SAN is localhost, 127.0.0.1 and 172.30.58.20" \
  test "$(san)" = "DNS:localhost, IP Address:127.0.0.1, IP Address:172.30.58.20"
check "upgraded key matches cert" key_matches_cert

# 4. A cert from some other CA (e.g. a CA volume that was lost and recreated) is replaced.
mkdir -p "$WORK/other"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=other CA" \
  -keyout "$WORK/other/ca.key" -out "$WORK/other/ca.crt" >/dev/null 2>&1
cp "$WORK/other/ca.crt" "$CERTS_DIR/server.crt"
check "foreign cert run succeeds" run_certgen
check "foreign cert replaced by one this CA signed" verifies

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all certgen checks passed"
