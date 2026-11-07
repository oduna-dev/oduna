#!/usr/bin/env bash
# Setup script for cloud agent sessions (Claude Code on the web): makes the
# container behave like the workstation for the rules in AGENTS.md. The cloud
# environment runs it from the directory above the checkouts, once per session
# start, as root. Every step is idempotent and a failing step never stops the
# session from starting.
set -uo pipefail

# Nix on the PATH of non-login shells: agent shells do not source the profile
# that adds it.
nix_bin=/nix/var/nix/profiles/default/bin
if [ -d "$nix_bin" ]; then
  for tool in "$nix_bin"/*; do
    ln -sf "$tool" "/usr/local/bin/$(basename "$tool")" || true
  done
fi

# Tracking refs of every branch: a clone fetches only the default branch, so
# stacked branches and reviews of other branches show up as unpushed or missing.
for repo in */; do
  [ -d "$repo/.git" ] || continue
  git -C "$repo" remote set-branches origin '*' || true
  git -C "$repo" fetch --quiet origin || true
done
