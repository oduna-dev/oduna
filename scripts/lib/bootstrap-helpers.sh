#!/usr/bin/env bash
# Shared helpers for the provisioning scripts (sourced, not executed): the
# instance directory, the pre-seed file, plaintext secrets materialization,
# and the sops decrypt/patch/encrypt round-trip used by bootstrap.sh,
# fetch-secrets.sh and postinstall.sh.
#
# Two roots: the product root (this repository: templates, sibling scripts)
# and the instance directory the pipeline operates on (its flake.nix,
# .sops.yaml, secrets/ and pre-seed). The instance is the current directory
# unless ODUNA_INSTANCE names it.
# shellcheck shell=bash

# The agent/CI shell is non-login and may not carry the Nix profile on PATH.
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

oduna_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

instance_dir() {
  local dir="${ODUNA_INSTANCE:-$PWD}"
  if [ ! -f "$dir/flake.nix" ] || [ ! -f "$dir/.sops.yaml" ]; then
    echo "error: $dir is not an instance directory (flake.nix and .sops.yaml expected); run from the instance or set ODUNA_INSTANCE" >&2
    return 1
  fi
  cd "$dir" && pwd
}

# Directory of <host> relative to the instance root, as declared by the host
# configuration (homelab.instance.hostDir).
host_dir() {
  nix eval --raw "$(instance_dir)#nixosConfigurations.$1.config.homelab.instance.hostDir"
}

bootstrap_preseed_path() {
  printf '%s/.bootstrap-secrets.env' "$(instance_dir)"
}

# Creates the pre-seed file from the committed
# `.bootstrap-secrets.env.example` template (per-key comments live in that
# file) when missing, keeps it untracked, and refuses to run if the values
# for <required-key...> are still empty.
require_preseed() {
  local preseed
  preseed="$(bootstrap_preseed_path)"

  if [ ! -f "$preseed" ]; then
    cp "$(oduna_root)/.bootstrap-secrets.env.example" "$preseed"
    chmod 600 "$preseed"
  fi

  if [ -f .gitignore ] && ! grep -qxF '.bootstrap-secrets.env' .gitignore; then
    printf '%s\n' '.bootstrap-secrets.env' >> .gitignore
  fi
  if [ -f .git/info/exclude ] && ! grep -qxF '.bootstrap-secrets.env' .git/info/exclude; then
    printf '%s\n' '.bootstrap-secrets.env' >> .git/info/exclude
  fi

  if git ls-files --error-unmatch "$preseed" >/dev/null 2>&1; then
    echo "refusing to continue: pre-seed file $preseed is tracked by git" >&2
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$preseed"
  set +a

  local missing=()
  local key
  for key in "$@"; do
    [ -n "${!key:-}" ] || missing+=("$key")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "pre-seed file $preseed is missing values; edit it and re-run:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
}

# String helpers over the plaintext (pre-sops-encryption) secrets yaml.
# Top-level "key: value" entries (borg_passphrase, smtp_password,
# netbird_setup_key, forgejo_runner_token).
yaml_get_value() {
  local file="$1" key="$2"
  sed -n -E "s/^${key}: (.*)$/\1/p" "$file" | head -n 1
}

yaml_set_value() {
  local file="$1" key="$2" value="$3"
  sed -i "s|^${key}: .*|${key}: ${value}|" "$file"
}

# Tree entries under the healthchecks key (four-space indentation as written
# in secrets.example.yaml; sops-nix resolves key subpaths like
# "healthchecks/heartbeat").
tree_get_value() {
  local file="$1" key="$2"
  sed -n -E "s/^    ${key}: (.*)$/\1/p" "$file" | head -n 1
}

tree_set_value() {
  local file="$1" key="$2" value="$3"
  sed -i "s|^    ${key}: .*|    ${key}: ${value}|" "$file"
}

# dotenv block entries (two-space indented KEY=value lines inside the
# caddy_inwx.env / vaultwarden.env / immich.env blocks).
# The indentation is matched loosely: it is two spaces in the freshly
# materialized template but four after a sops encrypt/decrypt round-trip
# (sops re-marshals the YAML).
env_get_value() {
  local file="$1" key="$2"
  sed -n -E "s/^ +${key}=(.*)$/\1/p" "$file" | head -n 1
}

env_set_value() {
  local file="$1" key="$2" value="$3"
  # Escape the sed replacement specials; the divider '|' is kept because
  # every possible value (SSH pubkeys, argon2 PHC, base64) excludes it.
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  sed -i -E "s|^( +)${key}=.*$|\1${key}=${value}|" "$file"
}

# Ensures the KEY=value line exists inside the dotenv block, reading the
# indentation from the anchor entry of that block (env_set_value alone
# cannot create a line in an older committed enterprise secrets.yaml that
# never carried the entry). Keys and anchors are alnum plus underscores.
env_ensure_value() {
  local file="$1" key="$2" value="$3" anchor="$4"
  if [ "$(env_get_value "$file" "$key")" != "" ]; then
    env_set_value "$file" "$key" "$value"
    return
  fi
  local indent
  indent="$(sed -n -E "s/^( +)${anchor}=.*$/\1/p" "$file" | head -n 1)"
  if [ -z "$indent" ]; then
    echo "missing anchor entry '${anchor}' in $file" >&2
    return 1
  fi
  sed -i -E "s|^( +${anchor}=.*)$|&\n${indent}${key}=|" "$file"
  env_set_value "$file" "$key" "$value"
}

# Ensures a top-level dotenv block (like `authentik.env: |`) exists by
# appending it at the end of the document when the tree predates the key.
# Body lines are already indented as given.
yaml_ensure_block() {
  local file="$1" block="$2"
  shift 2
  if grep -qE "^${block}: *\\|" "$file"; then
    return
  fi
  printf '%s: |\n' "$block" >> "$file"
  local line
  for line in "$@"; do
    printf '  %s\n' "$line" >> "$file"
  done
}


# Fills every locally generatable / pre-seed-backed value. Idempotent: keys
# that no longer carry the '...' placeholder are left untouched.
apply_preseed_values() {
  local file="$1"

  if [ "$(yaml_get_value "$file" borg_passphrase)" = "..." ]; then
    if [ -n "${BORG_PASSPHRASE:-}" ]; then
      yaml_set_value "$file" borg_passphrase "${BORG_PASSPHRASE}"
    else
      yaml_set_value "$file" borg_passphrase "$(openssl rand -base64 24)"
    fi
  fi
  if [ "$(env_get_value "$file" INWX_USERNAME)" = "..." ]; then
    env_set_value "$file" INWX_USERNAME "$INWX_USERNAME"
  fi
  if [ "$(env_get_value "$file" INWX_PASSWORD)" = "..." ]; then
    env_set_value "$file" INWX_PASSWORD "$INWX_PASSWORD"
  fi
  if [ "$(yaml_get_value "$file" smtp_password)" = "..." ]; then
    yaml_set_value "$file" smtp_password "'${SMTP_PASSWORD}'"
  fi
  if [ "$(env_get_value "$file" SMTP_PASSWORD)" = "..." ]; then
    env_set_value "$file" SMTP_PASSWORD "$SMTP_PASSWORD"
  fi
  # Shared break-glass admin: older committed trees may predate admin.env.
  yaml_ensure_block "$file" "admin.env" "ADMIN_EMAIL=..." "ADMIN_PASSWORD=..."
  if [ "$(env_get_value "$file" ADMIN_EMAIL)" = "..." ]; then
    env_set_value "$file" ADMIN_EMAIL "$ADMIN_EMAIL"
  fi
  if [ "$(env_get_value "$file" ADMIN_PASSWORD)" = "..." ]; then
    env_set_value "$file" ADMIN_PASSWORD "$ADMIN_PASSWORD"
  fi
  if [ "$(env_get_value "$file" DB_PASSWORD)" = "..." ]; then
    env_set_value "$file" DB_PASSWORD "$(openssl rand -hex 24)"
  fi
  if [ "$(env_get_value "$file" JWT_SECRET)" = "..." ]; then
    env_set_value "$file" JWT_SECRET "$(openssl rand -hex 24)"
  fi
  if [ "$(env_get_value "$file" SECRET_KEY)" = "..." ]; then
    env_set_value "$file" SECRET_KEY "$(openssl rand -hex 32)"
  fi
  # The stack database password must exist in every tree the compose file
  # runs on (the :? guard fails the stack up otherwise), including ones
  # whose authentik.env block predates the entry and only carries the
  # earlier keys.
  if [ "$(env_get_value "$file" AUTHENTIK_PG_PASSWORD)" = "..." ]; then
    env_set_value "$file" AUTHENTIK_PG_PASSWORD "$(openssl rand -hex 24)"
  elif [ -z "$(env_get_value "$file" AUTHENTIK_PG_PASSWORD)" ] && [ -n "$(env_get_value "$file" SECRET_KEY)" ]; then
    env_ensure_value "$file" AUTHENTIK_PG_PASSWORD "$(openssl rand -hex 24)" SECRET_KEY
  fi
  if [ "$(env_get_value "$file" AUTHENTIK_BOOTSTRAP_TOKEN)" = "..." ]; then
    env_set_value "$file" AUTHENTIK_BOOTSTRAP_TOKEN "$(openssl rand -hex 20)"
  fi
  if [ "$(env_get_value "$file" AUTHENTIK_BOOTSTRAP_PASSWORD)" = "..." ]; then
    env_set_value "$file" AUTHENTIK_BOOTSTRAP_PASSWORD \
      "${AUTHENTIK_BOOTSTRAP_PASSWORD:-$(openssl rand -base64 24)}"
  fi
  if [ "$(env_get_value "$file" AUTHENTIK_EMAIL__PASSWORD)" = "..." ]; then
    env_set_value "$file" AUTHENTIK_EMAIL__PASSWORD "$SMTP_PASSWORD"
  fi
}

# Fills the values that come from provider APIs. Stage-1-only providers: the
# NetBird setup key and the three Healthchecks checks (created when missing;
# the Borg check is paused right away while the Borg job is disabled). Skips
# entries that are already set. Uses the NETBIRD_API_TOKEN /
# HEALTHCHECKS_API_KEY pre-seed values.
fetch_provider_values() {
  local file="$1" host="$2"

  export NETBIRD_API_TOKEN HEALTHCHECKS_API_KEY

  if [ "$(yaml_get_value "$file" netbird_setup_key)" = "..." ]; then
    if [ -z "$NETBIRD_API_TOKEN" ]; then
      echo "netbird: NETBIRD_API_TOKEN missing from the pre-seed file" >&2
      return 1
    fi
    local resp
    resp="$(curl -fsS -X POST "${NETBIRD_API_URL:-https://api.netbird.io}/api/setup-keys" \
      -H 'Accept: application/json' -H 'Content-Type: application/json' \
      -H "Authorization: Token ${NETBIRD_API_TOKEN}" \
      --data "{\"name\": \"${host}-bootstrap\", \"type\": \"one-off\", \
        \"expires_in\": 86400, \"auto_groups\": [], \"usage_limit\": 1}")" \
      || { echo "netbird: setup key creation failed" >&2; return 1; }
    local nb_key
    nb_key="$(printf '%s' "$resp" | nix shell nixpkgs#jq -c jq -r '.key // empty')"
    [ -n "$nb_key" ] || { echo "netbird: no key in API response" >&2; return 1; }
    yaml_set_value "$file" netbird_setup_key "$nb_key"
  fi

  local body response_code slug_url
  local tree_keys=("heartbeat" "hotbackup" "borg")
  local slugs=("${host}-heartbeat" "${host}-hotbackup" "${host}-borg")
  local specs=(
    "\"name\": \"${host}-heartbeat\", \"slug\": \"${host}-heartbeat\", \"unique\": [\"slug\"], \"timezone\": \"Europe/Berlin\", \"period\": 300, \"grace\": 120"
    "\"name\": \"${host}-hotbackup\", \"slug\": \"${host}-hotbackup\", \"unique\": [\"slug\"], \"timezone\": \"Europe/Berlin\", \"schedule\": \"30 2 * * *\", \"grace\": 3600"
    "\"name\": \"${host}-borg\", \"slug\": \"${host}-borg\", \"unique\": [\"slug\"], \"timezone\": \"Europe/Berlin\", \"schedule\": \"30 3 * * *\", \"grace\": 7200"
  )
  local i
  for i in 0 1 2; do
    local tree_key="${tree_keys[$i]}" slug="${slugs[$i]}"
    if [ "$(tree_get_value "$file" "$tree_key")" != "..." ]; then
      continue
    fi
    if [ -z "$HEALTHCHECKS_API_KEY" ]; then
      echo "healthchecks: HEALTHCHECKS_API_KEY missing from the pre-seed file" >&2
      return 1
    fi
    body="$(mktemp)"
    local payload="{${specs[$i]}}"
    response_code=$(curl -sS -o "$body" -w '%{http_code}' \
      -X POST https://healthchecks.io/api/v3/checks/ \
      -H 'Content-Type: application/json' \
      -H "X-Api-Key: ${HEALTHCHECKS_API_KEY}" \
      --data "$payload") || {
        echo "healthchecks: API call for $slug failed" >&2
        return 1
      }
    case "$response_code" in
      200|201) ;;
      *) echo "healthchecks: creating $slug failed (HTTP $response_code): $(cat "$body")" >&2; rm -f "$body"; return 1 ;;
    esac
    slug_url="$(nix shell nixpkgs#jq -c jq -r '.ping_url' "$body")"
    tree_set_value "$file" "$tree_key" "$slug_url"
    if [ "$response_code" = "201" ] && [ "$tree_key" = "borg" ]; then
      # The Borg offsite job is disabled until storageBoxRepo is set: pause the
      # freshly created check so it does not alert "down" from day zero.
      curl -sS -X POST "${slug_url%/}/pause" \
        -H "X-Api-Key: ${HEALTHCHECKS_API_KEY}" --data '' >/dev/null || {
          echo "healthchecks: pausing $slug failed" >&2
          return 1
        }
    fi
    rm -f "$body"
  done
}

# sops decrypt/encrypt wrappers run inside the homelab directory so that the
# file lookup in .sops.yaml resolves.
decrypt_secrets_to() {
  local out="$1"
  (cd "$(instance_dir)" && nix run nixpkgs#sops -- -d secrets/secrets.yaml > "$out")
}

# Replaces the instance's secrets/secrets.yaml with an sops-encrypted copy of the
# given plaintext (in-place in the target path so that .sops.yaml's
# creation_rules match).
install_encrypted_secrets() {
  local plainfile="$1"
  local target
  target="$(instance_dir)/secrets/secrets.yaml"
  mkdir -p "$(dirname "$target")"
  cp "$plainfile" "$target"
  (cd "$(instance_dir)" && nix run nixpkgs#sops -- encrypt -i secrets/secrets.yaml)
}
