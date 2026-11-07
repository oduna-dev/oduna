#!/usr/bin/env bash
# Restores apps from the offsite backup and the local dumps, driven by the same
# manifest as the nightly job: stop what writes, fetch files and dumps from
# Borg, put every dump back by its type, start what was stopped.
#
# Usage: homelab-restore [--yes] [--no-fetch] [--archive NAME] [--list] [APP...]
#   --list          list the archives of the offsite repository and exit
#   --archive NAME  archive to fetch from (default: the newest)
#   --no-fetch      skip Borg; use the dumps and files already on this host
#   --yes           do it; without it the plan is printed and nothing changes
#   APP...          apps to restore (default: every app with a dump or paths)
#
# Environment:
#   BACKUP_MANIFEST  JSON manifest of the backup module (backupRoot, appPaths,
#                    instancePaths, dumps)
set -Eeuo pipefail

: "${BACKUP_MANIFEST:?}"

# Name the failing command: the stopped units start again in the EXIT trap, and
# without this the only trace of a failure would be the exit status.
trap 'echo "homelab-restore: line $LINENO: $BASH_COMMAND failed (exit $?)" >&2' ERR

yes=0
fetch=1
archive=""
list_only=0
apps=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) yes=1 ;;
    --no-fetch) fetch=0 ;;
    --list) list_only=1 ;;
    --archive)
      archive="${2:?--archive needs a name}"
      shift
      ;;
    -*)
      echo "unknown option $1" >&2
      exit 2
      ;;
    *) apps+=("$1") ;;
  esac
  shift
done

if [ "$list_only" = 1 ]; then
  exec borg-job-storagebox list --short
fi

# Progress lines carry the seconds since the start: a restore on real hardware
# shows which step takes the time.
note() { printf '[%ss] %s\n' "$SECONDS" "$*"; }

manifest() { jq -r "$@" "$BACKUP_MANIFEST"; }
backup_root="$(manifest .backupRoot)"

if [ "${#apps[@]}" -eq 0 ]; then
  mapfile -t apps < <(manifest '([.dumps[].app] + (.appPaths | keys)) | unique[]')
fi
selected() { jq -c --argjson apps "$(printf '%s\n' "${apps[@]}" | jq -R . | jq -sc .)" \
  '.dumps[] | select(.app as $a | $apps | index($a))' "$BACKUP_MANIFEST"; }

# Newest dump of a manifest entry: {date} in the file name becomes a glob.
latest_dump() {
  local app=$1 file=$2
  find "$backup_root/$app" -maxdepth 1 -type f -name "${file//'{date}'/*}" 2>/dev/null \
    | sort | tail -n 1 || true
}

# --- plan -----------------------------------------------------------------------

echo "apps: ${apps[*]}"
if [ "$fetch" = 1 ]; then
  command -v borg-job-storagebox >/dev/null || {
    echo "no offsite job on this host; use --no-fetch" >&2
    exit 1
  }
  [ -n "$archive" ] || archive="$(borg-job-storagebox list --short --last 1)"
  [ -n "$archive" ] || {
    echo "the offsite repository has no archive" >&2
    exit 1
  }
  echo "fetch: archive $archive -> $backup_root and the paths of the selected apps"
else
  echo "fetch: skipped, using the local files"
fi
while IFS= read -r dump; do
  field() { jq -r --arg k "$1" '.[$k] // empty' <<<"$dump"; }
  echo "restore: $(field app) <- $(field file) ($(field type))"
done < <(selected)
if [ "$yes" != 1 ]; then
  echo "plan only; run again with --yes to apply it"
  exit 0
fi

# --- quiesce --------------------------------------------------------------------

stopped_units=()
stopped_containers=()
cleanup() {
  local unit container
  for unit in "${stopped_units[@]}"; do
    systemctl start "$unit" || true
  done
  for container in "${stopped_containers[@]}"; do
    docker start "$container" >/dev/null || true
  done
}
trap cleanup EXIT

while IFS= read -r dump; do
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    systemctl stop "$unit"
    stopped_units+=("$unit")
  done < <(jq -r '.restore.stopUnits[]?' <<<"$dump")
done < <(selected)

note "services stopped"

# --- fetch ----------------------------------------------------------------------

if [ "$fetch" = 1 ]; then
  patterns=("${backup_root#/}")
  for app in "${apps[@]}"; do
    while IFS= read -r path; do
      patterns+=("${path#/}")
    done < <(jq -r --arg app "$app" '.appPaths[$app][]?' "$BACKUP_MANIFEST")
  done
  # Archive paths are absolute without the leading slash: extracting from /
  # puts files back where they were.
  (cd / && borg-job-storagebox extract "::$archive" "${patterns[@]}")
  note "fetched $archive"
fi

# --- restore by type ------------------------------------------------------------

restore_sqlite() {
  local dump=$1 file=$2 target owner mode
  target="$(jq -r '.dataDir + "/" + .db' <<<"$dump")"
  # The directory that holds the database decides the owner: for Actual that is
  # server-files, not the data directory above it.
  owner="$(stat -c %u:%g "$(dirname "$target")")"
  mode="$(stat -c %a "$target" 2>/dev/null || echo 600)"
  rm -f "$target-wal" "$target-shm"
  install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$file" "$target.restore"
  mv -f "$target.restore" "$target"
}

restore_postgres() {
  local dump=$1 file=$2 app container user database stack
  app="$(jq -r .app <<<"$dump")"
  container="$(jq -r .container <<<"$dump")"
  user="$(jq -r .user <<<"$dump")"
  database="$(jq -r '.database // empty' <<<"$dump")"
  stack="$(jq -r '.stackUnit' <<<"$dump")"
  systemctl start "$stack"
  until docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1; do sleep 2; done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    docker stop "$name" >/dev/null
    stopped_containers+=("$name")
  done < <(jq -r '.restore.stopContainers[]?' <<<"$dump")
  if [ -n "$database" ]; then
    docker exec -i "$container" pg_restore --clean --if-exists -U "$user" -d "$database" <"$file"
  else
    # pg_dumpall -c also tries to drop the connected role; that error is
    # expected and not fatal.
    gunzip -c "$file" | docker exec -i "$container" psql -U "$user" >/dev/null
  fi
  note "$app: database restored"
}

restore_command() {
  local dump=$1 file=$2 exec user
  exec="$(jq -r '.restore.exec // empty' <<<"$dump")"
  user="$(jq -r '.user // empty' <<<"$dump")"
  [ -n "$exec" ] || {
    echo "$(jq -r .app <<<"$dump"): no restore executable declared" >&2
    return 1
  }
  if [ -n "$user" ]; then
    runuser -u "$user" -- env RESTORE_IN="$file" "$exec"
  else
    RESTORE_IN="$file" "$exec"
  fi
}

while IFS= read -r dump; do
  app="$(jq -r .app <<<"$dump")"
  file="$(latest_dump "$app" "$(jq -r .file <<<"$dump")")"
  [ -n "$file" ] || {
    echo "$app: no dump in $backup_root/$app" >&2
    exit 1
  }
  note "$app: restoring $file"
  case "$(jq -r .type <<<"$dump")" in
    sqlite) restore_sqlite "$dump" "$file" ;;
    postgres-container) restore_postgres "$dump" "$file" ;;
    command) restore_command "$dump" "$file" ;;
    *)
      echo "unknown dump type for $app" >&2
      exit 1
      ;;
  esac
done < <(selected)

note "restore finished; the stopped units and containers start now"
