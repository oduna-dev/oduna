#!/usr/bin/env bash
# Formats every tracked or untracked-but-not-ignored Nix file of the
# repository with nixfmt. Enumerates the files itself: nixfmt without file
# arguments would read stdin.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
files="$(git ls-files -co --exclude-standard '*.nix')"
if [ -n "$files" ]; then
  printf '%s\n' "$files" | xargs nixfmt
fi
