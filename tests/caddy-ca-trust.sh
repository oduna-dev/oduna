#!/usr/bin/env bash
# Waits for Caddy's internal CA root and writes a CA bundle with the system
# roots plus that root for the test clients.
#
# Environment:
#   CADDY_PKI_ROOT   Caddy's internal root certificate
#   CADDY_CA_BUNDLE  bundle file to create
set -euo pipefail

: "${CADDY_PKI_ROOT:?}" "${CADDY_CA_BUNDLE:?}"

for _ in $(seq 1 60); do
  [ -f "$CADDY_PKI_ROOT" ] && break
  sleep 1
done
[ -f "$CADDY_PKI_ROOT" ] || {
  echo "homelab-vm-test: Caddy CA root never appeared"
  exit 1
}
install -d -m 755 "$(dirname "$CADDY_CA_BUNDLE")"
cat /etc/ssl/certs/ca-bundle.crt "$CADDY_PKI_ROOT" >"$CADDY_CA_BUNDLE"
chmod 644 "$CADDY_CA_BUNDLE"
