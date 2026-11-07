#!/usr/bin/env bash
# Pings the Healthchecks.io heartbeat check.
#
# Environment:
#   HC_URL_FILE  file holding the ping URL
set -euo pipefail

: "${HC_URL_FILE:?}"

url="$(cat "$HC_URL_FILE")"
exec curl -fsS -m 10 --retry 3 "$url"
