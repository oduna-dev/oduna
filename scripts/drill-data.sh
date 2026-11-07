#!/usr/bin/env bash
# Seeds known data into the apps of a host before a backup, and verifies it
# after a restore (restore drill, see docs/restore-drill.md). Covers the apps
# that can be driven through an API with the shared admin identity: Forgejo (a
# repository with two commits) and Immich (one photo). Vaultwarden and Actual
# Budget need their client-side encryption or sync protocol and stay manual.
#
# Usage: drill-data.sh <seed|verify> <host-flake-name> root@<target>
#   (run from the instance directory)
#
# `seed` stores a manifest (repository head, photo id and hash) in
# .drill-manifest.json in the instance directory, outside the host and the
# backup, and refuses to overwrite it. `verify` compares the live apps with that
# manifest and exits non-zero if anything differs.
set -euo pipefail

if [ "$#" -ne 3 ] || { [ "$1" != "seed" ] && [ "$1" != "verify" ]; }; then
  echo "usage: $0 <seed|verify> <host-flake-name> root@<target>" >&2
  exit 1
fi
mode="$1"
host="$2"
target="$3"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap-helpers.sh
source "$here/lib/bootstrap-helpers.sh"
homelab_dir="$(instance_dir)"

ev() {
  nix eval --raw "$homelab_dir#nixosConfigurations.${host}.config.$1"
}
internal_domain="$(ev homelab.internalDomain)"
forgejo_enabled="$(nix eval "$homelab_dir#nixosConfigurations.${host}.config.homelab.apps.forgejo.enable")"
immich_enabled="$(nix eval "$homelab_dir#nixosConfigurations.${host}.config.homelab.apps.immich.enable")"
forgejo_port="$(nix eval "$homelab_dir#nixosConfigurations.${host}.config.homelab.apps.forgejo.ingress.port")"

manifest_file="$homelab_dir/.drill-manifest.json"
if [ -f "$homelab_dir/.gitignore" ] && ! grep -qxF '.drill-manifest.json' "$homelab_dir/.gitignore"; then
  printf '%s\n' '.drill-manifest.json' >> "$homelab_dir/.gitignore"
fi
manifest=""
if [ "$mode" = "seed" ]; then
  [ ! -e "$manifest_file" ] || {
    echo "refusing to seed again: $manifest_file exists (delete it to start over)" >&2
    exit 1
  }
else
  [ -f "$manifest_file" ] || {
    echo "no $manifest_file; run seed first" >&2
    exit 1
  }
  manifest="$(cat "$manifest_file")"
fi

# The remote part runs as root on the host with its parameters in the
# environment; the admin secret never leaves the host.
rc=0
out="$(ssh -o ConnectTimeout=10 "$target" \
  "MODE='$mode' INTERNAL_DOMAIN='$internal_domain' FORGEJO_ENABLED='$forgejo_enabled' IMMICH_ENABLED='$immich_enabled' FORGEJO_PORT='$forgejo_port' MANIFEST='$manifest' bash -s" \
  < "$here/lib/drill-data-remote.sh")" || rc=$?
if [ "$mode" = "seed" ]; then
  [ "$rc" -eq 0 ] || exit "$rc"
  printf '%s\n' "$out" > "$manifest_file"
  echo "seeded; manifest saved to $manifest_file"
else
  printf '%s\n' "$out"
  exit "$rc"
fi
