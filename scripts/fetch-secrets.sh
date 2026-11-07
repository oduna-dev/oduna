#!/usr/bin/env bash
# Fills the provider-API-owned secrets (NetBird setup key, Healthchecks checks)
# into the sops-managed secrets. Two modes:
#
#   fetch-secrets.sh --host <host> <plain-yaml-file>   # bootstrap stage-1: the
#                       file is a plaintext copy that bootstrap.sh encrypts
#                       afterwards
#   fetch-secrets.sh --live                          # refresh an already
#                       committed, sops-encrypted secrets/secrets.yaml in place
#   fetch-secrets.sh --host <host> --live --fresh   # same as --live, plus
#                       re-creating the Healthchecks checks (after a wipe or
#                       when the check naming changed)
#   fetch-secrets.sh --host <host> --live --adopt-preseed
#                       # same as --live, plus replacing the human-owned
#                       # credentials (INWX, SMTP, the shared admin password)
#                       # from the preseed file
#   fetch-secrets.sh --host <host> --live --full   # --adopt-preseed + --fresh:
#                       # the full preseed reconciliation for a rebuild
#
# Values that are already set (no '...' placeholder) are left untouched.
set -euo pipefail

mode=""
host=""
plainfile=""
fresh=0
adopt=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || { echo "usage: $0 --host <host> <plainfile>|--live" >&2; exit 1; }
      host="$2"; shift 2 ;;
    --live) mode="live"; shift ;;
    --fresh)
      mode="live"; fresh=1; shift ;;
    --adopt-preseed)
      mode="live"; adopt=1; shift ;;
    --full)
      mode="live"; adopt=1; fresh=1; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) plainfile="$1"; shift ;;
  esac
done

if [ -z "$mode" ] && [ -n "$plainfile" ]; then
  mode="plain"
  [ -f "$plainfile" ] || { echo "plaintext file not found: $plainfile" >&2; exit 1; }
fi
[ -n "$host" ] || { echo "usage: $0 --host <host> <plainfile>|--live" >&2; exit 1; }
[ -n "$mode" ] || { echo "usage: $0 --host <host> <plainfile>|--live" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap-helpers.sh
source "$here/lib/bootstrap-helpers.sh"
cd "$(instance_dir)"

require_preseed NETBIRD_API_TOKEN HEALTHCHECKS_API_KEY
if [ "$adopt" = "1" ]; then
  require_preseed INWX_USERNAME INWX_PASSWORD SMTP_PASSWORD \
    ADMIN_EMAIL ADMIN_PASSWORD
fi

if [ "$mode" = "plain" ]; then
  apply_preseed_values "$plainfile"
  fetch_provider_values "$plainfile" "$host"
  exit 0
fi

# --live: round-trip the committed secrets file. Only the provider-owned keys
# are touched; other placeholders (postinstall-owned) stay untouched. The
# NetBird setup key is always re-minted: one-off keys are single-use, so a
# stale key from a previous enrollment is worthless. --fresh additionally
# re-creates the Healthchecks checks (use it when the check names changed,
# e.g. after adopting the ${host}-prefixed slug scheme). --adopt-preseed
# replaces the human-owned credentials (INWX, SMTP) from the current preseed
# file: use it after changing them portal-side, where sops would otherwise
# keep the outdated copies.
tmp="$(mktemp)"
decrypt_secrets_to "$tmp"
yaml_set_value "$tmp" netbird_setup_key "..."
if [ "$adopt" = "1" ]; then
  yaml_set_value "$tmp" smtp_password "'${SMTP_PASSWORD}'"
  env_set_value "$tmp" SMTP_PASSWORD "$SMTP_PASSWORD"
  env_set_value "$tmp" INWX_USERNAME "$INWX_USERNAME"
  env_set_value "$tmp" INWX_PASSWORD "$INWX_PASSWORD"
  yaml_ensure_block "$tmp" "admin.env" "ADMIN_EMAIL=..." "ADMIN_PASSWORD=..."
  env_set_value "$tmp" ADMIN_EMAIL "$ADMIN_EMAIL"
  env_set_value "$tmp" ADMIN_PASSWORD "$ADMIN_PASSWORD"
  if [ -n "${BORG_PASSPHRASE:-}" ]; then
    yaml_set_value "$tmp" borg_passphrase "${BORG_PASSPHRASE}"
  fi
fi
if [ "$fresh" = "1" ]; then
  for heart_key in heartbeat hotbackup borg; do
    tree_set_value "$tmp" "$heart_key" "..."
  done
fi
apply_preseed_values "$tmp"
fetch_provider_values "$tmp" "$host"
install_encrypted_secrets "$tmp"
git add -N secrets/secrets.yaml
echo "secrets.yaml refreshed for the fetched providers." >&2
