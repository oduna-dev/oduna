#!/usr/bin/env bash
# Dry-run validation of an instance flake: evaluates the full system
# configuration of <host> without building anything.
#
# Flake evaluation only sees Git-visible files, and sops content is only read
# as a store path during a dry-run. So: a missing secrets/secrets.yaml is
# stood in by a temporary placeholder (fresh clone, before bootstrap), and a
# present-but-untracked one is made visible via intent-to-add (staged for a
# later commit). Both changes are undone afterwards.
#
# Usage: validate.sh <host>   (run from the instance directory)
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <host>" >&2
  exit 1
fi
host="$1"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap-helpers.sh
source "$here/lib/bootstrap-helpers.sh"
cd "$(instance_dir)"

secrets="secrets/secrets.yaml"
created=0
staged=0

if [ ! -f "$secrets" ]; then
  created=1
  echo "dummy: ci-eval-placeholder" > "$secrets"
fi
if [ -z "$(git ls-files -- "$secrets")" ]; then
  staged=1
  git add -N "$secrets"
fi

cleanup() {
  if [ "$created" -eq 1 ]; then
    rm -f "$secrets"
  fi
  if [ "$staged" -eq 1 ]; then
    git restore --staged "$secrets"
  fi
}
trap cleanup EXIT

nix build --dry-run ".#$host"
