#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# Shared helpers of homelab-converge, sourced by converge.sh: logging, the
# Forgejo CLI wrapper, the shared break-glass identity and the temp file
# registry. Variables set here (admin_*, issuer, idp_enabled) are read by the
# app fragments.

# Helpers -------------------------------------------------------------------

warn() { echo "warning: $*" >&2; }
step() { printf -- '--- %s\n' "$1"; }

# Shared Forgejo helper: the break-glass admin and the OAuth2 auth source CLI
# talk to the same admin user subcommands under the same runtime environment.
fj() {
  runuser -u forgejo -- env \
    SSL_CERT_FILE="$IDP_CA_BUNDLE" \
    HOME="$FORGEJO_STATE_DIR" \
    FORGEJO_WORK_DIR="$FORGEJO_STATE_DIR" \
    FORGEJO_CUSTOM="$FORGEJO_STATE_DIR/custom" \
    "$FORGEJO_EXEC" admin user "$@"
}

# Waits until Caddy serves a verifiable certificate for the private vhosts.
# On a fresh host the wildcard certificate is issued minutes after boot (DNS
# challenge plus propagation wait), while converge starts at activation; the
# steps that talk to the apps through their hostnames would fail until then.
# The probe name resolves to the host itself and only needs a completed TLS
# handshake, any HTTP status will do. Bounded: the steps degrade to warnings.
wait_for_tls() {
  local _
  for _ in $(seq 1 72); do
    curl -sS --max-time 5 -o /dev/null \
      --resolve "tls-probe.$INTERNAL_DOMAIN:443:127.0.0.1" \
      "https://tls-probe.$INTERNAL_DOMAIN/" 2> /dev/null && return 0
    sleep 5
  done
  warn "no usable TLS certificate for *.$INTERNAL_DOMAIN after the bounded wait"
  return 1
}

# --- read the shared admin identity ----------------------------------------

admin_email="$(sed -n 's/^ADMIN_EMAIL=//p' "$ADMIN_ENV_FILE" 2>/dev/null || true)"
admin_password="$(sed -n 's/^ADMIN_PASSWORD=//p' "$ADMIN_ENV_FILE" 2>/dev/null || true)"
if [ -z "$admin_email" ] || [ -z "$admin_password" ]; then
  echo "converge: admin.env carries empty values; nothing converges" >&2
  exit 1
fi
admin_user="${admin_email%%@*}"

issuer="$IDP_ISSUER"
idp_enabled=true
if [ -z "$issuer" ]; then
  idp_enabled=false
fi

# Temp files an interrupted previous run may have left behind; removed at
# exit as well.
tmp_files=()
register_tmp() {
  rm -f "$1"
  tmp_files+=("$1")
}
trap 'rm -f "${tmp_files[@]}"' EXIT
