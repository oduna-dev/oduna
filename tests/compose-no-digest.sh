#!/usr/bin/env bash
# docker-compose wrapper for the VM test: drops the image digest pins from the
# staged compose file, because a docker-archive load carries no registry digest
# and the daemon could not resolve the pinned reference locally.
#
# Environment:
#   REAL_DOCKER_COMPOSE  the docker-compose executable to run
set -euo pipefail

: "${REAL_DOCKER_COMPOSE:?}"

sed -i -E 's/@sha256:[0-9a-f]{64}//' docker-compose.yml
exec "$REAL_DOCKER_COMPOSE" "$@"
