#!/usr/bin/env bash
# Reports the result of the Borg job to Healthchecks.io: a failure ping when
# the exit status is not zero. A failed ping never fails the job.
#
# Arguments:
#   $1  file holding the ping URL
#   $2  exit status of the Borg job
set -uo pipefail

url_file=$1
status=$2

suffix=""
[ "$status" -eq 0 ] || suffix=/fail
curl -fsS -m 10 --retry 3 "$(cat "$url_file")$suffix" || true
