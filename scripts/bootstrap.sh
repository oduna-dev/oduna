#!/usr/bin/env bash
# Provision a homelab host from scratch: generate identities, encrypt secrets,
# and run nixos-anywhere to partition the disks, install NixOS, and reboot
# into the deployed configuration.
#
# Usage: bootstrap.sh <host> root@<live-ip>
#
# The instance's .sops.yaml carries the host's age key as a `- &<host> <key>`
# entry, which this script fills in.
#
# Run from the instance directory (or set ODUNA_INSTANCE) on the workstation
# with Nix installed. The target must be booted into
# the NixOS minimal ISO with root SSH reachable (set a temporary root password
# on the ISO console first).
#
# Set BUILD_ON_REMOTE=1 when the workstation cannot build x86_64-linux
# derivations (e.g. macOS) so the closure is built on the target.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <host> root@<live-ip>" >&2
  exit 1
fi

host="$1"
target="$2"
# A reinstall re-keys the target twice (live ISO vs installed system); the
# stale known_hosts entries must go up front or ssh prompts and the pipeline
# hangs on an unattended read.
ssh-keygen -R "${target#*@}" >/dev/null 2>&1 || true
ssh-keygen -R "[${target#*@}]:22" >/dev/null 2>&1 || true
# The staging tree holds freshly generated secrets; it is kept (not cleaned up)
# so the escrow step below stays possible after the script exits. Delete it
# manually once the keys are escrowed.
staging="$(mktemp -d)"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap-helpers.sh
source "$here/lib/bootstrap-helpers.sh"

repo_root="$(instance_dir)"
cd "$repo_root"

# --- Pre-seed ----------------------------------------------------------------

# The pre-seed file carries values that only a human knows (registrar
# credentials, relay password) plus the API tokens the fetchers need. It is
# workstation-local and gitignored; created on first run.
require_preseed INWX_USERNAME INWX_PASSWORD SMTP_PASSWORD \
  NETBIRD_API_TOKEN HEALTHCHECKS_API_KEY \
  ADMIN_EMAIL ADMIN_PASSWORD \
  STORAGEBOX_USERNAME STORAGEBOX_PASSWORD

# --- Preflight --------------------------------------------------------------

disko_file="$(host_dir "$host")/disko.nix"
if grep -qE 'SERIAL|XXXXXXXX' "$disko_file"; then
  echo "Disk serials are not set yet; current inventory on $target:" >&2
  ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$target" 'ls -l /dev/disk/by-id/' >&2
  echo "Set the by-id paths in $disko_file and re-run." >&2
  exit 1
fi

printf 'This wipes every disk on %s and installs NixOS from %s.\n' "$target" "$repo_root"
read -r -p "Type 'WIPE' to continue: " confirmation
[ "$confirmation" = "WIPE" ] || { echo "aborted" >&2; exit 1; }

# --- Identities -------------------------------------------------------------

install -d -m 700 "$staging/etc/ssh"

# Host SSH identity, generated on every run; its public key derives the age key
# that decrypts the sops secrets at boot.
ssh-keygen -t ed25519 -N "" -C "$host" -f "$staging/etc/ssh/ssh_host_ed25519_key"
host_age_key="$(nix run nixpkgs#ssh-to-age -- < "$staging/etc/ssh/ssh_host_ed25519_key.pub")"

# Dedicated key for the append-only Borg repository on the StorageBox; add its
# public key as the StorageBox forced-command key (borg serve --append-only).
# postinstall.sh installs it only while the host config has no repository URL;
# a reinstall against an existing repository authorises it by hand.
ssh-keygen -t ed25519 -N "" -C "$host-borg" -f "$staging/etc/ssh/borg_append_only_key"

# ZFS encryption keys, one per pool.
install -d -m 700 "$staging/etc/zfs/keys"
for pool in fast-pool tank; do
  dd if=/dev/urandom of="$staging/etc/zfs/keys/$pool.key" bs=32 count=1
  chmod 400 "$staging/etc/zfs/keys/$pool.key"
done

printf '\nEscrow before continuing:\n'
printf '  - etc/ssh/ssh_host_ed25519_key*  (host identity)\n'
printf '  - etc/ssh/borg_append_only_key   (Borg StorageBox key)\n'
printf '  - etc/zfs/keys/{fast-pool,tank}.key (pool encryption)\n'
printf 'Store them in the offline recovery vault; they are printed from %s.\n\n' "$staging"
"$here/print-escrow.sh" "$staging"

# The escrow values cannot be reproduced once the run regenerates identities
# on a retry; gate here so the operator cannot proceed without having stored
# them. The staging dir stays on disk (kept deliberately) for a missed copy.
read -r -p "Escrow stored in the recovery vault? Type 'ESCROW' to continue: " escrow_gate
if [ "$escrow_gate" != "ESCROW" ]; then
  echo "aborted; the staging dir is kept at $staging for retrieving the values" >&2
  exit 1
fi

# --- Secrets ----------------------------------------------------------------

# Every run generates a fresh host key, so the &<host> key must be re-written
# each time; leaving a stale key in place would leave the installed host
# unable to decrypt the secrets at boot. A missing or empty file (truncated
# in preparation for a from-scratch rebuild) triggers a full re-materialization
# from the example template + pre-seed instead of re-keying.
if ! grep -qF -- "- &$host " .sops.yaml; then
  echo ".sops.yaml is missing the '&$host' age key entry" >&2
  exit 1
fi
# The host name is a literal in the sed expression as well.
host_re="$(printf '%s' "$host" | sed 's/[][\.*^$|/]/\\&/g')"
sed -i "s|\(- &$host_re \).*|\1$host_age_key|" .sops.yaml

if [ ! -s secrets/secrets.yaml ]; then

  # Materialize the full plaintext: locally generated + pre-seed-backed
  # values, then the provider-API values (NetBird setup key, Healthchecks
  # checks). postinstall.sh fills the remaining placeholder (Forgejo runner
  # token) once the host is up; the Vaultwarden admin token and Beszel agent
  # key are derived at runtime by homelab-converge.
  plainfile="$staging/secrets-plain.yaml"
  cp "$(oduna_root)/secrets/secrets.example.yaml" "$plainfile"
  chmod 600 "$plainfile"
  apply_preseed_values "$plainfile"
  "$here/fetch-secrets.sh" --host "$host" "$plainfile"

  install_encrypted_secrets "$plainfile"
  git add -N secrets/secrets.yaml
else
  nix run nixpkgs#sops -- updatekeys secrets/secrets.yaml
  git add -N secrets/secrets.yaml
  # The committed values are stale for a new install by definition: the
  # netbird setup key is single-use, the portal-side credentials may have
  # rotated, and the Healthchecks checks may be missing. Reconcile the
  # whole preseed into sops before the install so the first boot converges
  # without an additional deploy cycle.
  "$here/fetch-secrets.sh" --host "$host" --live --full
fi

# --- Pre-flight build -------------------------------------------------------

# Evaluate the complete system configuration before touching any disks.
nix build --dry-run "$repo_root#$host"

# --- Stale mesh peers -------------------------------------------------------

# After the WIPE gate: the old install of this host is about to disappear.
remove_stale_netbird_peers "$host" "$repo_root"

# --- Provision --------------------------------------------------------------

# The live ISO needs the ZFS keys before disko creates the pools; the same
# files reach the installed system via --extra-files.
ssh -o StrictHostKeyChecking=accept-new "$target" 'mkdir -p /etc/zfs/keys'
scp -o StrictHostKeyChecking=accept-new "$staging/etc/zfs/keys/fast-pool.key" "$staging/etc/zfs/keys/tank.key" "$target:/etc/zfs/keys/"
ssh "$target" 'chmod 700 /etc/zfs/keys && chmod 400 /etc/zfs/keys/*.key'

extra_args=()
if [ "${BUILD_ON_REMOTE:-0}" = "1" ]; then
  extra_args+=(--build-on-remote)
fi

nix run nixpkgs#nixos-anywhere -- \
  --flake "$repo_root#$host" \
  --extra-files "$staging" \
  ${extra_args[@]+"${extra_args[@]}"} \
  "$target"

# --- Aftercare --------------------------------------------------------------

# The reinstalled host presents the key generated in staging; verify it
# server-side with ssh-keyscan (no interactive prompt, no MITM window) and
# refresh known_hosts so every later pipeline ssh call passes silently.
printf 'Install finished; waiting for the host to come back...\n'
staged_pub="$(awk '{print $1, $2}' "$staging/etc/ssh/ssh_host_ed25519_key.pub")"
host_back=0
scan=""
for _ in $(seq 1 60); do
  scan="$(ssh-keyscan -T 5 -t ed25519 "${target#*@}" 2>/dev/null | grep -m1 ' ssh-ed25519 ' || true)"
  if [ "$(awk '{print $2, $3; exit}' <<<"$scan")" = "$staged_pub" ]; then
    host_back=1
    break
  fi
  sleep 10
done
if [ "$host_back" = "0" ]; then
  echo "warning: host did not come back within 10 minutes (or its key did not match the staged identity)" >&2
  exit 1
fi
ssh-keygen -R "${target#*@}" >/dev/null 2>&1 || true
mkdir -p "$HOME/.ssh"
printf '%s\n' "$scan" >> "$HOME/.ssh/known_hosts"
echo "Host is back; host key verified against the staged identity."
if [ "${SKIP_POSTINSTALL:-0}" = "1" ]; then
  echo "SKIP_POSTINSTALL=1 set; run postinstall ${host} ${target} manually."
  exit 0
fi
exec "$here/postinstall.sh" "$host" "$target"
