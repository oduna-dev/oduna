#!/usr/bin/env bash
# Installs a Docker Compose stack's files into its state directory and brings
# the stack up. Runs as the stack unit's ExecStart with the state directory as
# the working directory; docker-compose comes from the unit's PATH.
#
# Environment:
#   STACK_DIR     state directory on the app dataset
#   COMPOSE_FILE  compose file shipped with the module
#   SECRETS_ENV   sops-managed env file, installed as the project's .env
#   EXTRA_ENV     optional env file whose entries are appended to the .env
set -euo pipefail

: "${STACK_DIR:?}" "${COMPOSE_FILE:?}" "${SECRETS_ENV:?}"

install -d -m 755 "$STACK_DIR"
install -m 644 "$COMPOSE_FILE" "$STACK_DIR/docker-compose.yml"
install -m 600 "$SECRETS_ENV" "$STACK_DIR/.env"
if [ -n "${EXTRA_ENV:-}" ]; then
  # A sops block without a trailing newline would swallow the first entry.
  [ -z "$(tail -c1 "$STACK_DIR/.env")" ] || echo >>"$STACK_DIR/.env"
  cat "$EXTRA_ENV" >>"$STACK_DIR/.env"
fi
exec docker-compose up -d
