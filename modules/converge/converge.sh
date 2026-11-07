#!/usr/bin/env bash
# shellcheck shell=bash
# homelab-converge: converges app-internal runtime state on every activation —
# IdP provisioning, runtime SSO credentials and the break-glass admin accounts.
# Everything is idempotent against live services. Constants (paths, ports,
# issuer, executable locations) and the credential file locations are injected
# as environment variables by the consuming systemd unit (modules/converge.nix).
# This file orchestrates; the steps live in lib.sh, idp.sh and one fragment per
# app in apps/ (hooks: init, breakglass, idp_provider, idp_sso, finish).
#
# Failures degrade to journal warnings ("service keeps its own login path");
# the only fatal case is an unhealthy IdP after the bounded wait, because the
# whole IdP-dependent block cannot run.
set -uo pipefail

# Environment (besides the app constants of modules/converge.nix):
#   CONVERGE_LIB_DIR  directory holding lib.sh, idp.sh and apps/<app>.sh
#   CONVERGE_APPS     enabled apps in run order, space separated
: "${CONVERGE_LIB_DIR:?}" "${CONVERGE_APPS-}"

# shellcheck source=lib.sh
. "$CONVERGE_LIB_DIR/lib.sh"
# shellcheck source=idp.sh
. "$CONVERGE_LIB_DIR/idp.sh"
for app in $CONVERGE_APPS; do
  # shellcheck source=/dev/null
  . "$CONVERGE_LIB_DIR/apps/$app.sh"
done

# Runs the given hook of every enabled app that defines it.
run_hooks() {
  local app id
  for app in $CONVERGE_APPS; do
    id="${app//-/_}"
    if declare -F "${id}_$1" > /dev/null; then "${id}_$1"; fi
  done
}

# --- Run ----------------------------------------------------------------------

run_hooks init
run_hooks breakglass
step "IdP provisioning"
# The unhealthy-after-bounded-wait IdP is the one unit-fatal case (per the
# header): everything else in the chain degrades to warnings.
idp_chain || { warn "IdP provisioning failed; rerunning the unit converges once it is healthy"; exit 1; }
run_hooks finish
echo "converge: done"
