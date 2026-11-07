#!/usr/bin/env bash
# docker-compose wrapper for the VM test: drops the image digest pins from the
# staged compose file, because a docker-archive load carries no registry digest
# and the daemon could not resolve the pinned reference locally. The Immich
# machine-learning service is not started: its image is not loaded in the test.
#
# Environment:
#   REAL_DOCKER_COMPOSE  the docker-compose executable to run
set -euo pipefail

: "${REAL_DOCKER_COMPOSE:?}"

sed -i -E 's/@sha256:[0-9a-f]{64}//' docker-compose.yml
args=("$@")
if [ "${1:-}" = up ] && grep -q '^  immich-machine-learning:' docker-compose.yml; then
  # Naming the services to start leaves the machine-learning service out of
  # the run entirely; a zero scale would still make compose look for its
  # image.
  mapfile -t services < <("$REAL_DOCKER_COMPOSE" config --services | grep -vx immich-machine-learning)
  args+=("${services[@]}")
fi
exec "$REAL_DOCKER_COMPOSE" "${args[@]}"
