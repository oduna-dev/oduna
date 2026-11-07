#!/usr/bin/env bash
# Creates the per-app data directories on the app datasets for the apps named
# as arguments.
#
# Environment:
#   APPDATA  base directory of the app datasets
set -euo pipefail

: "${APPDATA:?}"

for app in "$@"; do
  case "$app" in
    vaultwarden)
      # Vaultwarden keeps its database and keys directly in the dataset root.
      install -d -o vaultwarden -g vaultwarden -m 700 "$APPDATA/vaultwarden"
      ;;
    actual-budget)
      # Actual Budget runs as the static system user "actual".
      install -d -o actual -g actual -m 750 "$APPDATA/actual-budget/server-files"
      install -d -o actual -g actual -m 750 "$APPDATA/actual-budget/user-files"
      ;;
    *)
      echo "appdata-dirs: unknown app $app" >&2
      exit 1
      ;;
  esac
done
