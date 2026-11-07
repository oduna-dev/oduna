#!/usr/bin/env bash
# Writes a Forgejo repository dump to $BACKUP_OUT. The backup engine runs it
# as the forgejo user while the service is stopped.
#
# Environment:
#   BACKUP_OUT          dump file to create
#   FORGEJO_WORK_DIR    Forgejo state directory
#   FORGEJO_CONFIG      app.ini of the instance
set -euo pipefail

: "${BACKUP_OUT:?}" "${FORGEJO_WORK_DIR:?}" "${FORGEJO_CONFIG:?}"

exec forgejo dump -c "$FORGEJO_CONFIG" -f "$BACKUP_OUT"
