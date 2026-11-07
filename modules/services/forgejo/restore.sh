#!/usr/bin/env bash
# Puts a Forgejo dump (`forgejo dump`, see dump.sh) back: repositories, data
# directory and the SQLite database. homelab-restore runs it as the forgejo
# user while the service is stopped.
#
# Environment:
#   RESTORE_IN          dump file to restore
#   FORGEJO_WORK_DIR    Forgejo state directory
#   FORGEJO_CONFIG      app.ini of the instance
#   FORGEJO_REPO_ROOT   directory holding the Git repositories
#   FORGEJO_DB          path of the SQLite database
set -euo pipefail

: "${RESTORE_IN:?}" "${FORGEJO_WORK_DIR:?}" "${FORGEJO_CONFIG:?}" "${FORGEJO_REPO_ROOT:?}" "${FORGEJO_DB:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q "$RESTORE_IN" -d "$tmp"

# The dump keeps the repositories in repos/, the data directory in data/ and
# the database as an SQL script named <app>-db.sql.
sql="$(find "$tmp" -maxdepth 1 -name '*-db.sql' | head -n 1)"
[ -n "$sql" ] || {
  echo "no *-db.sql in the dump; its layout:" >&2
  ls -la "$tmp" >&2
  exit 1
}
[ -d "$tmp/repos" ] || {
  echo "no repos/ in the dump; its layout:" >&2
  ls -la "$tmp" >&2
  exit 1
}

mkdir -p "$FORGEJO_REPO_ROOT" "$(dirname "$FORGEJO_DB")"
find "$FORGEJO_REPO_ROOT" -mindepth 1 -delete
cp -a "$tmp/repos/." "$FORGEJO_REPO_ROOT/"
if [ -d "$tmp/data" ]; then
  cp -a "$tmp/data/." "$FORGEJO_WORK_DIR/data/"
fi

rm -f "$FORGEJO_DB" "$FORGEJO_DB-wal" "$FORGEJO_DB-shm"
sqlite3 "$FORGEJO_DB" <"$sql"
chmod 600 "$FORGEJO_DB"

# Repository hook scripts point into the store path of the system that took
# the dump.
forgejo admin regenerate hooks -c "$FORGEJO_CONFIG"
echo "forgejo restored from $RESTORE_IN"
