#!/usr/bin/env bash
# Loads the given docker-archive image tarballs into the Docker daemon and
# reports how long each one took (the unit journal carries the lines).
set -euo pipefail

for image in "$@"; do
  start=$SECONDS
  docker load <"$image"
  echo "load-images: $(basename "$image") loaded in $((SECONDS - start))s"
done
