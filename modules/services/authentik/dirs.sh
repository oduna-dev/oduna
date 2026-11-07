#!/usr/bin/env bash
# Creates the authentik data directories on the app dataset.
#
# Environment:
#   AUTHENTIK_DIR  state directory of the authentik stack
set -euo pipefail

: "${AUTHENTIK_DIR:?}"

# PostgreSQL data directory (alpine postgres user 70), chowned before the
# cluster initdb.
install -d -o 70 -g 70 -m 700 "$AUTHENTIK_DIR/postgres"
# Media/user uploads (flow backgrounds and similar) and the data directory
# (geoip updates), shared between server and worker (container user 1000).
install -d -o 1000 -g 1000 -m 750 "$AUTHENTIK_DIR/media"
install -d -o 1000 -g 1000 -m 750 "$AUTHENTIK_DIR/data"
# Outpost env file: empty stub ahead of compose, filled by homelab-converge
# with the provisioned AUTHENTIK_TOKEN.
[ -f "$AUTHENTIK_DIR/outpost.env" ] || : >"$AUTHENTIK_DIR/outpost.env"
chmod 600 "$AUTHENTIK_DIR/outpost.env"
