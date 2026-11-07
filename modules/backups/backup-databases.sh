#!/usr/bin/env bash
# Nightly dumps of the app databases into the local backup root, driven by the
# manifest the backups module generates from the app registry. Each dump goes
# to <root>/<app>/<file>; files older than the retention are removed at the
# end. Progress is reported to Healthchecks.io when HC_URL_FILE is set.
#
# Environment:
#   BACKUP_MANIFEST  JSON manifest: { retentionDays, dumps: [ { app, file,
#                    type, stopUnits, ... } ] }
#   BACKUP_ROOT      local backup root
#   HC_URL_FILE      optional file holding the Healthchecks.io ping URL
set -Eeuo pipefail

: "${BACKUP_MANIFEST:?}" "${BACKUP_ROOT:?}"

date="$(date +%F)"
stopped=()
tmp_dirs=()

ping() {
  [ -n "${HC_URL_FILE:-}" ] || return 0
  curl -fsS -m 10 --retry 3 "$(cat "$HC_URL_FILE")$1" || true
}

cleanup() {
  local rc=$? unit dir
  for unit in "${stopped[@]}"; do
    systemctl start "$unit" || true
  done
  for dir in "${tmp_dirs[@]}"; do
    rm -rf "$dir"
  done
  if [ "$rc" -ne 0 ]; then
    ping /fail
  fi
}

# Consistent copy of a SQLite database, read from a dedicated ZFS snapshot of
# the dataset mounted at $1. A previous run that failed between snapshot and
# destroy leaves the snapshot behind, so it is dropped before a fresh one.
dump_sqlite() {
  local dir=$1 db=$2 out=$3 dataset
  [ "$(findmnt -n -o TARGET --target "$dir")" = "$dir" ] || {
    echo "$dir is not the mountpoint of a dataset" >&2
    return 1
  }
  dataset="$(findmnt -n -o SOURCE --target "$dir")"
  zfs destroy "$dataset@backup-snap" 2>/dev/null || true
  zfs snapshot "$dataset@backup-snap"
  sqlite3 "file:$dir/.zfs/snapshot/backup-snap/$db?mode=ro" ".backup '$out'"
  zfs destroy "$dataset@backup-snap"
}

# Logical dump from a running PostgreSQL container: custom-format pg_dump of
# one database, or the gzip-compressed pg_dumpall of the whole cluster.
dump_postgres() {
  local container=$1 user=$2 database=$3 out=$4
  if [ -n "$database" ]; then
    docker exec "$container" pg_dump --format=custom -U "$user" "$database" >"$out"
  else
    docker exec "$container" pg_dumpall -c --if-exists -U "$user" | gzip >"$out"
  fi
}

# The executable writes the dump to $BACKUP_OUT inside a private directory
# that is handed to its user.
dump_command() {
  local exec=$1 user=$2 out=$3 dir
  dir="$(mktemp -d)"
  tmp_dirs+=("$dir")
  if [ -n "$user" ]; then
    chown "$user" "$dir"
    runuser -u "$user" -- env BACKUP_OUT="$dir/dump" "$exec"
  else
    BACKUP_OUT="$dir/dump" "$exec"
  fi
  mv "$dir/dump" "$out"
}

trap cleanup EXIT
ping /start

mkdir -p "$BACKUP_ROOT"

while IFS= read -r dump; do
  field() { jq -r --arg k "$1" '.[$k] // empty' <<<"$dump"; }
  app="$(field app)"
  file="$(field file)"
  file="${file//'{date}'/$date}"
  mkdir -p "$BACKUP_ROOT/$app"
  out="$BACKUP_ROOT/$app/$file"

  # Stopped units come back even when the dump fails (see cleanup).
  mapfile -t stopped < <(jq -r '.stopUnits[]?' <<<"$dump")
  for unit in "${stopped[@]}"; do
    systemctl stop "$unit"
  done

  case "$(field type)" in
    sqlite) dump_sqlite "$(field dataDir)" "$(field db)" "$out" ;;
    postgres-container) dump_postgres "$(field container)" "$(field user)" "$(field database)" "$out" ;;
    command) dump_command "$(field exec)" "$(field user)" "$out" ;;
    *)
      echo "unknown dump type for $app" >&2
      exit 1
      ;;
  esac

  for unit in "${stopped[@]}"; do
    systemctl start "$unit"
  done
  stopped=()
done < <(jq -c '.dumps[]' "$BACKUP_MANIFEST")

# Retain the configured days locally; offsite retention is governed by Borg.
find "$BACKUP_ROOT" -type f -mtime +"$(jq -r '.retentionDays' "$BACKUP_MANIFEST")" -delete

ping ""
