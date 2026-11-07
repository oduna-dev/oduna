#!/usr/bin/env bash
# Post-deploy checks over SSH: services, ZFS mounts, boot health, mesh
# enrollment, TLS issuance, and (when the provider key is available) the
# Healthchecks heartbeat. Prints one ok/FAIL line per check and exits non-zero
# if anything failed.
#
# Usage: checks.sh <host-flake-name> root@<target>   (run from the instance directory)
#
# CHECK_BACKUPS=1 adds the backup checks (the nightly dumps ran recently and
# neither backup job has failed). They are off by default because a freshly
# installed host has not run its first nightly job yet.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <host-flake-name> root@<target>" >&2
  exit 1
fi
host="$1"
target="$2"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap-helpers.sh
source "$here/lib/bootstrap-helpers.sh"
homelab_dir="$(instance_dir)"
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
failures=0

check() {
  local name="$1"
  shift
  if local output; output="$("$@" 2>&1)"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n%s\n' "$name" "$output"
    failures=$((failures + 1))
  fi
}

# Remote check helper: runs the given script in the target's default shell.
remote() {
  ssh -o ConnectTimeout=10 "$target" "$1"
}

# Unit names follow the host's hostname, not the flake attribute name.
hostname="$(nix eval --raw "$homelab_dir#nixosConfigurations.${host}.config.networking.hostName")"
unit_name="gitea-runner-${hostname}_runner"
internal_domain="$(nix eval --raw "$homelab_dir#nixosConfigurations.${host}.config.homelab.internalDomain")"

# --- services active -----------------------------------------------------------
# Units that died in start-limit-hit state stay failed: switch only restarts
# units whose definition changed, so un-suppress manually with
# `systemctl reset-failed <unit> && systemctl restart <unit>` after fixing the
# root cause. This check reports them as failures until then.

auth_units=""
identity_enabled="$(nix eval "$homelab_dir#nixosConfigurations.${host}.config.homelab.identity.enable" 2>/dev/null | sed 's/"//g')"
if [ "$identity_enabled" = "true" ]; then
  auth_units="authentik-stack"
fi

check "services active" remote \
  "systemctl is-active caddy netbird forgejo vaultwarden actual beszel-hub beszel-agent $unit_name $auth_units"

# --- ZFS datasets mounted -------------------------------------------------------

check "zfs datasets mounted" remote \
  "test \"\$(zfs get -H -o value mounted fast-pool/appdata tank/backups | grep -c '^yes\$')\" -eq 2"

# --- no systemd ordering-cycle stalls -------------------------------------------

check "no ordering cycles" remote \
  "! journalctl -b --quiet --grep 'ordering cycle' | grep -q ."

# --- netbird enrolled ------------------------------------------------------------

check "netbird connected" remote \
  "netbird status | grep -q 'Management: Connected'"

# --- TLS issued through INWX (mesh vhost reachable with a valid cert) -----------

tls_ok() {
  curl -fsS --max-time 10 -o /dev/null "https://beszel.${internal_domain}"
}

check "tls for mesh vhost" tls_ok

if [ "$(nix eval "$homelab_dir#nixosConfigurations.${host}.config.homelab.converge.enable" 2>/dev/null | sed 's/"//g')" = "true" ]; then
  check "homelab converged" remote \
    "systemctl is-active homelab-converge.service homelab-converge-files.service"
fi
if [ "$identity_enabled" = "true" ]; then
  sc=$(curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' "https://auth.${internal_domain}/-/health/live/" || true)
  check "idp auth vhost healthy" test "$sc" = "200"

  # Every container of the authentik compose stack must be up (the outpost
  # only once postinstall.sh has provisioned its token).
  check "idp compose stack running" remote \
    'for n in authentik_server authentik_worker authentik_postgres authentik_outpost; do docker ps --filter "name=$n" --filter "status=running" --format "{{.Names}}" | grep -qx "$n" || exit 1; done'

  check "idp outpost forwards on music" remote \
    'curl -s -o /dev/null -w %{http_code} http://127.0.0.1:9302/outpost.goauthentik.io/ping | grep -q 200'
fi

# --- backups (opt-in, see the header) ---------------------------------------------

if [ "${CHECK_BACKUPS:-0}" = "1" ]; then
  bulk_path="$(nix eval --raw "$homelab_dir#nixosConfigurations.${host}.config.homelab.storage.bulkPath")"
  check "nightly dumps not failed" remote \
    "! systemctl is-failed --quiet backup-databases.service"
  check "nightly dumps written within 36 hours" remote \
    "test -n \"\$(find '$bulk_path/backups' -type f -mmin -2160 | head -n 1)\""
  borg_repo="$(nix eval --raw "$homelab_dir#nixosConfigurations.${host}.config.homelab.backup.storageBoxRepo")"
  if [ -n "$borg_repo" ]; then
    check "offsite backup not failed" remote \
      "! systemctl is-failed --quiet borgbackup-job-storagebox.service"
  fi
fi

# --- healthchecks heartbeat green (optional, needs the provider key) ------------

if [ -f "$homelab_dir/.bootstrap-secrets.env" ]; then
  # shellcheck source=/dev/null
  source "$homelab_dir/.bootstrap-secrets.env"
fi
if [ -n "${HEALTHCHECKS_API_KEY:-}" ]; then
  heartbeat_up() {
    curl -fsS --max-time 10 -H "X-Api-Key: ${HEALTHCHECKS_API_KEY}" \
      "https://healthchecks.io/api/v3/checks/?slug=${host}-heartbeat" \
      | grep -q '"status": "up"'
  }
  check "healthchecks heartbeat up" heartbeat_up
else
  printf 'skip healthchecks heartbeat (no HEALTHCHECKS_API_KEY)\n'
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
