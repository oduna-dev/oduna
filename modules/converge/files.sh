#!/usr/bin/env bash
# Creates the stub env files that the consuming units reference, ahead of
# their first start, for the apps named as arguments.
#
# Environment:
#   BESZEL_AGENT_ENV_FILE      Beszel agent env: root-owned stub (DynamicUser
#                              parses via pid1); homelab-converge supplies KEY
#   VAULTWARDEN_DATA_DIR       Vaultwarden data directory
#   VAULTWARDEN_CONVERGE_ENV   Vaultwarden converge env: staged admin hash and
#                              SSO_* entries
set -euo pipefail

for app in "$@"; do
  case "$app" in
    beszel)
      : "${BESZEL_AGENT_ENV_FILE:?}"
      install -d -m 700 "$(dirname "$BESZEL_AGENT_ENV_FILE")"
      [ -f "$BESZEL_AGENT_ENV_FILE" ] || : >"$BESZEL_AGENT_ENV_FILE"
      ;;
    vaultwarden)
      : "${VAULTWARDEN_DATA_DIR:?}" "${VAULTWARDEN_CONVERGE_ENV:?}"
      install -d -o vaultwarden -g vaultwarden -m 700 "$VAULTWARDEN_DATA_DIR"
      [ -f "$VAULTWARDEN_CONVERGE_ENV" ] || : >"$VAULTWARDEN_CONVERGE_ENV"
      ;;
    *)
      echo "converge-files: unknown app $app" >&2
      exit 1
      ;;
  esac
done
