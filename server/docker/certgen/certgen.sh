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
# Idempotent: a second run with a good certificate changes nothing. CERTS_DIR/CA_DIR exist only
# for deploy/scripts/test/certgen.test.sh.
set -eu

CERTS_DIR="${CERTS_DIR:-/certs}"
CA_DIR="${CA_DIR:-/ca}"
# localhost / 127.0.0.1: dev and platform-ui (proxy_ssl_name localhost). 172.30.58.20: mob04.
# Changing this list reissues the server cert on the next run; the CA stays.
SAN="DNS:localhost,IP:127.0.0.1,IP:172.30.58.20"

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
cp "$tmp/server.crt" "$CERTS_DIR/server.crt"
chmod 644 "$CERTS_DIR/server.crt"
echo "certgen: issued a new server certificate ($SAN)"
