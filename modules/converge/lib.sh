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
