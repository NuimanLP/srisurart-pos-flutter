#!/bin/sh
# certgen: a private CA plus a server certificate it signs, for Nginx's TLS.
#
# Why a CA and not one self-signed cert: the Android API build reaches mob04 as
# https://172.30.58.20, and Dart's HttpClient refuses a cert it cannot chain to a trusted root or
# whose SAN lacks that IP. The app bundles ca.crt (frontend/assets/certs/pos-ca.crt) and trusts it
# next to the system roots — never a badCertificateCallback (07_CICD_DEPLOY.md, "TLS").
#
#  - CA ($CA_DIR, volume `certs-ca`, mounted ONLY here): created once, never replaced, because
#    every built APK pins its public half. Its key never reaches Nginx, git or CI.
#  - Server cert ($CERTS_DIR, volume `certs`, read by nginx and platform-ui): reissued whenever it
#    is missing, not signed by this CA, carries a different SAN list, or expires within 30 days.
#    That is what moves an existing volume off the old CN=localhost self-signed cert: the
#    volume's contents are never re-created by a config change on their own.
#
# CERT_SAN_IPS (optional) lists the host's LAN IPs for the SAN; see the SAN block below.
#
# Idempotent: a second run with a good certificate changes nothing. CERTS_DIR/CA_DIR exist only
# for deploy/scripts/test/certgen.test.sh.
set -eu

CERTS_DIR="${CERTS_DIR:-/certs}"
CA_DIR="${CA_DIR:-/ca}"
# localhost / 127.0.0.1: dev and platform-ui (proxy_ssl_name localhost). The host IPs come from
# CERT_SAN_IPS (comma-separated IPv4, set in the host .env); unset or empty = 172.30.58.20
# (mob04), so the SAN string is unchanged there and nothing is reissued. Whitespace is trimmed,
# duplicates dropped (input order kept). Changing the list reissues the server cert on the next
# run; the CA stays. Every entry is validated before any file is touched: a bad one exits 1.
ips="${CERT_SAN_IPS:-}"
[ -n "$(printf '%s' "$ips" | tr -d ' \t\r,')" ] || ips="172.30.58.20"
SAN="DNS:localhost,IP:127.0.0.1"
seen=","
old_ifs="$IFS"
IFS=","
# No globbing while splitting: an entry such as '*' must be rejected, not expanded to file names.
set -f
for ip in $ips; do
  # \r too: a CRLF-edited .env must not change the SAN (or reissue the cert on mob04).
  ip=$(printf '%s' "$ip" | tr -d ' \t\r')
  [ -n "$ip" ] || continue
  # The `case` rejects anything but digits and dots first: grep matches line by line, so an
  # embedded newline ("1.2.3.4<LF>foo") would otherwise pass and land in the openssl ext file.
  if case "$ip" in *[!0-9.]*) true ;; *) false ;; esac ||
    ! printf '%s' "$ip" | grep -Eq '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' ||
    [ "$(printf '%s' "$ip" | tr '.' '\n' | sort -n | tail -n 1)" -gt 255 ]; then
    echo "certgen: CERT_SAN_IPS entry '$ip' is not a dotted IPv4 address" >&2
    exit 1
  fi
  case "$seen" in *",$ip,"*) continue ;; esac
  seen="$seen$ip,"
  SAN="$SAN,IP:$ip"
done
set +f
IFS="$old_ifs"

if [ ! -s "$CA_DIR/ca.key" ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -subj "/CN=Srisurart POS private CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt"
  chmod 600 "$CA_DIR/ca.key"
  echo "certgen: created a new CA in $CA_DIR"
fi
# platform-ui trusts the CA by this path (docker/platform-ui/nginx.conf).
cp "$CA_DIR/ca.crt" "$CERTS_DIR/ca.crt"
chmod 644 "$CERTS_DIR/ca.crt"

# The SAN as `openssl x509 -ext` prints it, e.g. "DNS:localhost, IP Address:127.0.0.1".
want_san=$(echo "$SAN" | sed 's/,/, /g; s/IP:/IP Address:/g')
if [ -s "$CERTS_DIR/server.crt" ] && [ -s "$CERTS_DIR/server.key" ] &&
  openssl verify -CAfile "$CA_DIR/ca.crt" "$CERTS_DIR/server.crt" >/dev/null 2>&1 &&
  openssl x509 -in "$CERTS_DIR/server.crt" -noout -checkend 2592000 >/dev/null &&
  [ "$(openssl x509 -in "$CERTS_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null |
    sed -n '2s/^ *//p')" = "$want_san" ]; then
  echo "certgen: server certificate is current"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' \
  "basicConstraints=critical,CA:FALSE" \
  "keyUsage=critical,digitalSignature,keyEncipherment" \
  "extendedKeyUsage=serverAuth" \
  "subjectAltName=$SAN" >"$tmp/ext"
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=localhost" \
  -keyout "$tmp/server.key" -out "$tmp/server.csr"
openssl x509 -req -sha256 -days 825 -in "$tmp/server.csr" \
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
  -extfile "$tmp/ext" -out "$tmp/server.crt"

# Certificate removed first and written last: an interrupted run leaves no cert, so the next
# run reissues instead of keeping a cert that does not match the key beside it.
rm -f "$CERTS_DIR/server.crt"
cp "$tmp/server.key" "$CERTS_DIR/server.key"
chmod 600 "$CERTS_DIR/server.key"
# Full chain, leaf first (what nginx's ssl_certificate expects). The CA travelling inside
# server.crt keeps a rollback safe: platform-ui configs from before the CA trusted server.crt
# itself, and still verify through the CA in it. Every check above reads the first cert only.
cat "$tmp/server.crt" "$CA_DIR/ca.crt" >"$CERTS_DIR/server.crt"
chmod 644 "$CERTS_DIR/server.crt"
echo "certgen: issued a new server certificate ($SAN)"
