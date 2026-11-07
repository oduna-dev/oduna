#!/usr/bin/env bash
# Loads the given docker-archive image tarballs into the Docker daemon.
set -euo pipefail

for image in "$@"; do
  docker load <"$image"
done
