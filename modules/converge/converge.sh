#!/usr/bin/env bash
# shellcheck shell=bash
# homelab-converge: converges app-internal runtime state on every activation —
# IdP provisioning, runtime SSO credentials and the break-glass admin accounts.
# Everything is idempotent against live services. Constants (paths, ports,
# issuer, executable locations) and the credential file locations are injected
# as environment variables by the consuming systemd unit (modules/converge.nix);
# this file contains the steps only.
#
# Failures degrade to journal warnings ("service keeps its own login path");
# the only fatal case is an unhealthy IdP after the bounded wait, because the
# whole IdP-dependent block cannot run.
set -uo pipefail

# Helpers -------------------------------------------------------------------

warn() { echo "warning: $*" >&2; }
step() { printf -- '--- %s\n' "$1"; }

# Shared Forgejo helper: the break-glass admin and the OAuth2 auth source CLI
# talk to the same admin user subcommands under the same runtime environment.
fj() {
  runuser -u forgejo -- env \
    SSL_CERT_FILE="$IDP_CA_BUNDLE" \
    HOME="$FORGEJO_STATE_DIR" \
    FORGEJO_WORK_DIR="$FORGEJO_STATE_DIR" \
    FORGEJO_CUSTOM="$FORGEJO_STATE_DIR/custom" \
    "$FORGEJO_EXEC" admin user "$@"
}

# --- read the shared admin identity ----------------------------------------

admin_email="$(sed -n 's/^ADMIN_EMAIL=//p' "$ADMIN_ENV_FILE" 2>/dev/null || true)"
admin_password="$(sed -n 's/^ADMIN_PASSWORD=//p' "$ADMIN_ENV_FILE" 2>/dev/null || true)"
if [ -z "$admin_email" ] || [ -z "$admin_password" ]; then
  echo "converge: admin.env carries empty values; nothing converges" >&2
  exit 1
fi
admin_user="${admin_email%%@*}"

issuer="$IDP_ISSUER"
idp_enabled=true
if [ -z "$issuer" ]; then
  idp_enabled=false
fi

# --- vaultwarden converge.env staging (committed once at the end) ----------- #
# The file only changes when one of its values materially changes, so the     #
# unit restart only happens then (a random-salted argon2 re-hash would        #
# otherwise churn the file on every activation).                              #
install -d -o vaultwarden -g vaultwarden -m 700 "$VAULTWARDEN_DATA_DIR"
# Leftovers from an interrupted previous activation.
rm -f "$VAULTWARDEN_CONVERGE_ENV.converge-tmp" "$AUTHENTIK_OUTPOST_ENV.converge-tmp"
trap 'rm -f "$VAULTWARDEN_CONVERGE_ENV.converge-tmp" "$AUTHENTIK_OUTPOST_ENV.converge-tmp"' EXIT
vw_tmp="$VAULTWARDEN_CONVERGE_ENV.converge-tmp"
if [ -f "$VAULTWARDEN_CONVERGE_ENV" ]; then
  cat "$VAULTWARDEN_CONVERGE_ENV" > "$vw_tmp"
else
  : > "$vw_tmp"
fi
vw_set() {
  local value="$2"
  # sed replacement specials (the same escaping env_set_value applies).
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  if grep -q "^$1=" "$vw_tmp"; then
    sed -i "s|^$1=.*$|$1=$value|" "$vw_tmp"
  else
    printf '%s=%s\n' "$1" "$value" >> "$vw_tmp"
  fi
}
vw_commit() {
  if [ ! -f "$VAULTWARDEN_CONVERGE_ENV" ] || ! cmp -s "$vw_tmp" "$VAULTWARDEN_CONVERGE_ENV"; then
    install -m 600 -o vaultwarden -g vaultwarden "$vw_tmp" "$VAULTWARDEN_CONVERGE_ENV"
    rm -f "$vw_tmp"
    systemctl restart vaultwarden.service
    echo "vaultwarden: converge.env written (service restarted)"
  else
    rm -f "$vw_tmp"
    echo "vaultwarden: converge.env current"
  fi
}

# --- Beszel: agent key + superuser/UI admin + localhost system ----------------

beszel_hub_token=""

beszel_agent_step() {
  # The identity keys live inside the hub's data dir; the workdir root is
  # checked as a fallback so the file move between data layouts keeps
  # converging.
  hub_pub="$(ssh-keygen -y -f "$BESZEL_HUB_DATA_DIR/beszel_data/id_ed25519" 2>/dev/null \
    || ssh-keygen -y -f "$BESZEL_HUB_DATA_DIR/id_ed25519" 2>/dev/null \
    || true)"
  if [ -z "$hub_pub" ]; then
    echo "warning: could not read the beszel hub key ($BESZEL_HUB_DATA_DIR/beszel_data/id_ed25519)"
    return 0
  fi
  key_entry="KEY=$hub_pub"
  agent_env_file="$BESZEL_AGENT_ENV_FILE"
  install -d -m 700 "$(dirname "$agent_env_file")"
  if [ -f "$agent_env_file" ] && grep -qxF "$key_entry" "$agent_env_file"; then
    echo "beszel: agent key already mirrors the hub identity"
    return 0
  fi
  install -m 600 /dev/null "$agent_env_file"
  printf '%s\n' "$key_entry" > "$agent_env_file"
  systemctl restart beszel-agent.service
  echo "beszel: agent key synced from the hub identity (agent restarted)"
}

beszel_hub_step() {
  # Superuser upsert (the hub binary writes the PocketBase identity db as the
  # service user; ownership restored after root ran it, like the pipeline did).
  beszel_hub_token="$(curl -fsS -X POST http://127.0.0.1:8090/api/collections/_superusers/auth-with-password \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg id "$admin_email" --arg pw "$admin_password" '{identity: $id, password: $pw}')" \
    | jq -r '.token // empty' 2>/dev/null)" || beszel_hub_token=""
  if [ -z "$beszel_hub_token" ] && [ -d "$BESZEL_HUB_DATA_DIR/beszel_data" ]; then
    db_uid="$(stat -c %u "$BESZEL_HUB_DATA_DIR/beszel_data")"
    db_gid="$(stat -c %g "$BESZEL_HUB_DATA_DIR/beszel_data")"
    (cd "$BESZEL_HUB_DATA_DIR" && "$BESZEL_HUB_EXEC" superuser upsert "$admin_email" "$admin_password" >/dev/null)
    chown -R "$db_uid:$db_gid" "$BESZEL_HUB_DATA_DIR/beszel_data"
    beszel_hub_token="$(curl -fsS -X POST http://127.0.0.1:8090/api/collections/_superusers/auth-with-password \
      -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg id "$admin_email" --arg pw "$admin_password" '{identity: $id, password: $pw}')" \
      | jq -r '.token // empty' 2>/dev/null)" || beszel_hub_token=""
    [ -z "$beszel_hub_token" ] || echo "beszel: hub superuser converged with the shared admin"
  fi
  if [ -z "$beszel_hub_token" ]; then
    echo "warning: beszel hub superuser credentials not converged"
    return 0
  fi
  echo "beszel: hub superuser credentials accepted"
  hub_admin_id="$(curl -fsS -G http://127.0.0.1:8090/api/collections/users/records \
    -H "Authorization: $beszel_hub_token" \
    --data-urlencode "filter=(email='$admin_email')" \
    | jq -r '.items[0]?.id // empty' 2>/dev/null)" || hub_admin_id=""
  if [ -z "$hub_admin_id" ]; then
    hub_admin_id="$(curl -fsS -X POST http://127.0.0.1:8090/api/collections/users/records \
      -H 'Content-Type: application/json' -H "Authorization: $beszel_hub_token" \
      -d "$(jq -cn --arg email "$admin_email" --arg pw "$admin_password" \
        '{email: $email, password: $pw, verified: true, role: "admin"}')" \
      | jq -r '.id // empty' 2>/dev/null)" || hub_admin_id=""
    [ -z "$hub_admin_id" ] || echo "beszel: hub admin user created"
  else
    echo "beszel: hub admin user present"
  fi
  hub_system_id="$(curl -fsS -G http://127.0.0.1:8090/api/collections/systems/records \
    -H "Authorization: $beszel_hub_token" \
    --data-urlencode "filter=(host='localhost')" \
    | jq -r '.items[0]?.id // empty' 2>/dev/null)" || hub_system_id=""
  if [ -z "$hub_system_id" ]; then
    curl -fsS -X POST http://127.0.0.1:8090/api/collections/systems/records \
      -H 'Content-Type: application/json' -H "Authorization: $beszel_hub_token" \
      -d "$(jq -cn --arg name "$(cat /etc/hostname)" --arg uid "$hub_admin_id" \
        '{name: $name, host: "localhost", port: "45876", users: [$uid]}')" >/dev/null \
      && echo "beszel: system registered (localhost:45876)"
  else
    echo "beszel: system already registered"
  fi
}

# --- Forgejo: break-glass admin ----------------------------------------------

forgejo_step() {
  # Credential probes deliberately exercise the failing path first.
  fj_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -u "$admin_user:$admin_password" "http://127.0.0.1:${FORGEJO_PORT}/api/v1/user")" || fj_code=""
  if fj list | grep -qwF "$admin_user"; then
    if [ "$fj_code" = "200" ]; then
      echo "forgejo: break-glass admin accepted"
    else
      fj change-password --username "$admin_user" --password "$admin_password" >/dev/null \
        && echo "forgejo: break-glass admin password converged"
    fi
  else
    fj create --admin \
      --username "$admin_user" \
      --email "$admin_email" \
      --password "$admin_password" \
      --must-change-password=false > /dev/null \
      && echo "forgejo: break-glass admin created"
  fi
}

# --- Vaultwarden: converge the live ADMIN_TOKEN to the shared password -------
# The supplemental env file carries the runtime-only entries (admin hash,
# SSO_*); vaultwarden's sops env file keeps the relay password. The hashing
# CLI needs a tty: fed through script(1). Writing only when the live admin
# panel rejects the shared password keeps the random salt from churning the
# file across activations.
vaultwarden_step() {
  state="$(systemctl is-active vaultwarden.service 2>/dev/null || true)"
  probe="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080/admin \
    --data-urlencode "token=$admin_password")" || probe=""
  if [ "$state" = "active" ] && [ "$probe" = "303" ]; then
    echo "vaultwarden: admin password accepted by the live instance"
  elif [ "$state" = "active" ]; then
    vw_hashed="$(printf '%s\n%s\n' "$admin_password" "$admin_password" \
      | script -qec "$VAULTWARDEN_EXEC hash" /dev/null | tr -d '\r' \
      | sed -n "s/^ADMIN_TOKEN='\(.*\)'$/\1/p")" || vw_hashed=""
    case "$vw_hashed" in
      '$argon2'*)
        vw_set ADMIN_TOKEN "'$vw_hashed'"
        echo "vaultwarden: ADMIN_TOKEN re-hashed for the shared password"
        ;;
      *)
        echo "warning: vaultwarden hash generation failed (output: $vw_hashed)" >&2
        return 1
        ;;
    esac
  else
    echo "warning: vaultwarden unit inactive; ADMIN_TOKEN not rewritten" >&2
    return 1
  fi
}

# --- Immich: break-glass admin ------------------------------------------------

immich_step() {
  url="https://immich.$INTERNAL_DOMAIN"
  login="$(curl -fsS -X POST "$url/api/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg email "$admin_email" --arg pw "$admin_password" '{email: $email, password: $pw}')" \
    | jq -r '.accessToken // empty' 2>/dev/null)" || login=""
  if [ -n "$login" ]; then
    echo "immich: break-glass admin accepted"
    return 0
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$url/api/auth/admin-sign-up" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg email "$admin_email" --arg pw "$admin_password" --arg name "$admin_user" \
      '{email: $email, password: $pw, name: $name}')")" || code=""
  case "$code" in
    201)
      echo "immich: break-glass admin created"
      ;;
    400)
      # An admin exists with different credentials: converge through the
      # container's upstream forgot-password CLI (session invalidation
      # included); an identity mismatch (different admin email) stays a
      # warning.
      reset="$(printf '%s\n\n' "$admin_password" \
        | timeout 120 script -qec \
          "docker exec -it immich_server immich-admin reset-admin-password" /dev/null \
        | tr -d '\r')" || reset=""
      if grep -qF -- "$admin_email" <<<"$reset" \
        && grep -qi 'admin password has been updated' <<<"$reset"; then
        echo "immich: break-glass admin password converged"
      elif grep -q 'Found Admin' <<<"$reset"; then
        echo "warning: immich admin identity is not the shared email; rotation is manual in the UI" >&2
        echo "$reset" >&2
      else
        echo "warning: immich admin password reset failed (immich-admin output below)" >&2
        echo "$reset" >&2
      fi
      ;;
    *)
      echo "warning: immich admin signup failed (HTTP $code)" >&2
      ;;
  esac
}

# --- Actual Budget: owner (break-glass admin) ---------------------------------

actual_step() {
  url="http://127.0.0.1:${ACTUAL_PORT}"
  boot="$(curl -fsS "$url/account/needs-bootstrap" \
    | jq -r '.data.bootstrapped' 2>/dev/null)" || boot=""
  login="$(curl -fsS -X POST "$url/account/login" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg pw "$admin_password" '{loginMethod: "password", password: $pw}')" \
    | jq -r '.token // empty' 2>/dev/null)" || login=""
  if [ -n "$login" ]; then
    echo "actual: break-glass owner password accepted"
    return 0
  fi
  if [ "$boot" != "true" ]; then
    if curl -fsS -X POST "$url/account/bootstrap" -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg pw "$admin_password" '{password: $pw}')" \
      | jq -e '.token' > /dev/null; then
      echo "actual: owner (break-glass admin) bootstrapped"
      return 0
    fi
    echo "warning: actual owner bootstrap failed" >&2
    return 1
  fi
  # Rotate the stored hash: the password hash lives in the auth row of
  # method='password'. Generating with the server's own bcrypt binding
  # (inside the package's node_modules) rules out cross-library hash format
  # guessing; the sqlite surgery is what the server docs themselves document
  # for recovery access.
  actual_db="$ACTUAL_SERVER_FILES/account.sqlite"
  bcrypt_dir="$(find "$ACTUAL_PACKAGE" -maxdepth 8 -name bcrypt -type d 2>/dev/null | head -n1)"
  if [ -z "$bcrypt_dir" ]; then
    echo "warning: actual owner password rotation failed (bcrypt binding not found in the server package)" >&2
    return 1
  fi
  hash="$("$NODE_BIN" -e 'const b = require(process.argv[1]); console.log(b.hashSync(process.argv[2], 10))' \
    "$bcrypt_dir" "$admin_password" 2>&1)" || hash=""
  case "$hash" in
    '$2'*)
      runuser -u actual -- "$SQLITE" "$actual_db" \
        "UPDATE auth SET extra_data='$hash' WHERE method='password';" >/dev/null \
        || { echo "warning: actual owner hash rewrite failed" >&2; return 1; }
      recheck="$(curl -fsS -X POST "$url/account/login" -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg pw "$admin_password" '{loginMethod: "password", password: $pw}')" \
        | jq -r '.token // empty' 2>/dev/null)" || recheck=""
      if [ -n "$recheck" ]; then
        echo "actual: break-glass owner password converged"
      else
        echo "warning: actual owner password rewritten but login still fails (rotation is manual in the UI)" >&2
        return 1
      fi
      ;;
    *)
      echo "warning: actual owner password rotation failed (bcrypt hash generation returned: $hash)" >&2
      return 1
      ;;
  esac
}

# --- Navidrome: break-glass admin ----------------------------------------------

navidrome_step() {
  url="http://127.0.0.1:${NAVIDROME_PORT}"
  nav_login() {
    curl -fsS -X POST "$url/auth/login" -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg u "$admin_email" --arg p "$admin_password" '{username: $u, password: $p}')" \
      | jq -r '.token // empty' 2>/dev/null
  }
  login="$(nav_login)" || login=""
  if [ -n "$login" ]; then
    echo "navidrome: break-glass admin accepted"
    return 0
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/auth/createAdmin" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg u "$admin_email" --arg p "$admin_password" '{username: $u, password: $p}')")" || code=""
  case "$code" in
    200|201)
      echo "navidrome: break-glass admin created"
      ;;
    *)
      # The instance already has users. The CLI needs at least one admin in
      # the database (the precondition holds whenever the above ran) and the
      # prompts need a tty, fed through script(1).
      nav_cli_cmd="$(printf '%q --configfile %q' "$NAVIDROME_EXEC" "$NAVIDROME_CONF")"
      if runuser -u navidrome -- "$NAVIDROME_EXEC" --configfile "$NAVIDROME_CONF" user list \
        | grep -qwF -- "$admin_user"; then
        printf '%s\n%s\n' "$admin_password" "$admin_password" \
          | runuser -u navidrome -- timeout 60 script -qec \
            "$nav_cli_cmd user edit --user $(printf '%q' "$admin_email") --set-password" /dev/null
        recheck="$(nav_login)" || recheck=""
        if [ -n "$recheck" ]; then
          echo "navidrome: break-glass admin password converged"
        else
          echo "warning: navidrome break-glass admin password rotation failed (rotation is manual in the UI)" >&2
          return 1
        fi
      else
        echo "warning: navidrome break-glass admin not created (HTTP $code) and the shared identity is no local user; manual seeding required" >&2
        return 1
      fi
      ;;
  esac
}

# --- IdP-dependent section ------------------------------------------------------
# Groups, shared scope mapping, one application/provider pair per OIDC app plus
# the Navidrome proxy provider and outpost, then the per-app SSO
# registrations. Client credentials stay inside the IdP and the receiving
# app's own store (or the converge-owned vaultwarden env file); the outpost
# token is written to the outpost env file of the authentik stack.

immich_pair="|"
beszel_pair="|"
budget_pair="|"
git_pair="|"
vault_pair="|"
immich_login=""

idp_health() {
  # The liveness endpoint (authentik 2026.x): 404/503 until the server is
  # ready, 200 afterwards. Older releases only serve the fixed /-/health/
  # ping, accepted as a fallback so a converge runs against both.
  for _ in $(seq 1 30); do
    for path in /-/health/live/ /-/health/; do
      curl -fsS --max-time 5 "${issuer}${path}" > /dev/null 2>&1 && return 0
    done
    sleep 3
  done
  return 1
}

idp_chain() {
  if [ "$idp_enabled" != "true" ]; then
    echo "sso: no IdP issuer configured; skipping identity provisioning"
    return 0
  fi
  if ! idp_health; then
    echo "warning: IdP not healthy at $issuer after the bounded wait; rerunning the unit converges once it is" >&2
    return 1
  fi
  ak_token="$(sed -n 's/^AUTHENTIK_BOOTSTRAP_TOKEN=//p' "$AUTHENTIK_ENV_FILE" 2>/dev/null || true)"
  # Any non-2xx response (notably authentik's 400 validation errors, which name
  # the offending fields) is printed to the journal before the step degrades.
  ak_call() {
    local method="$1" path="$2" resp code body
    local -a args=(
      -sS -w $'\n%{http_code}' -X "$method"
      -H "Authorization: Bearer $ak_token" -H 'Content-Type: application/json'
    )
    [ $# -gt 2 ] && args+=(--data "$3")
    if resp="$(curl "${args[@]}" "$issuer$path" 2>/dev/null)"; then
      code="${resp##*$'\n'}"
      body="${resp%$'\n'*}"
      case "$code" in
        [2]*) printf '%s\n' "$body" && return 0 ;;
        *) warn "authentik API $method $path -> $code: ${body:-<empty body>}" ;;
      esac
    else
      warn "authentik API $method $path -> transport failure"
    fi
    return 1
  }
  api() { ak_call GET "$1"; }
  api_post() { ak_call POST "$1" "$2"; }

  ensure_group() {
    if [ -z "$(api "/api/v3/core/groups/?name=$1" | jq -r '.results[0].pk // empty' 2>/dev/null)" ]; then
      api_post '/api/v3/core/groups/' "$(jq -cn --arg name "$1" '{name: $name}')" > /dev/null \
        && echo "group:$1: created"
    else
      echo "group:$1: present"
    fi
  }
  ensure_group family
  ensure_group admins

  # Shared scope mapping: authentik's default email scope returns
  # email_verified: false, which Vaultwarden and Beszel reject. (2026.x moved
  # the endpoint from .../scope/ to .../provider/scope/.)
  map_path='/api/v3/propertymappings/provider/scope/'
  mapping_pk="$(api "${map_path}?name=oauth2-email-verified" \
    | jq -r '.results[0].pk // empty' 2>/dev/null)" || mapping_pk=""
  if [ -z "$mapping_pk" ]; then
    mapping_pk="$(api_post "$map_path" \
      "$(jq -cn --arg expr 'return {"email": request.user.email, "email_verified": True}' \
        '{name: "oauth2-email-verified", scope_name: "email", expression: $expr, description: "Email claim with email_verified true; managed by homelab-converge"}')" \
      | jq -r '.pk' 2>/dev/null)" && echo "mapping:oauth2-email-verified: created" || mapping_pk=""
  else
    echo "mapping:oauth2-email-verified: present"
  fi

  defaults='["goauthentik.io/providers/oauth2/scope-openid","goauthentik.io/providers/oauth2/scope-profile","goauthentik.io/providers/oauth2/scope-email","goauthentik.io/providers/oauth2/scope-offline_access","goauthentik.io/providers/oauth2/scope-entitlements"]'
  oid_mappings="$(api '/api/v3/propertymappings/provider/scope/?page_size=1000' \
    | jq -r --argjson managed "$defaults" --arg custom "$mapping_pk" \
      '[.results[] | select(.managed != null and (.managed as $m | $managed | index($m))) | select(.managed != "goauthentik.io/providers/oauth2/scope-email") | .pk] + (if $custom == "" then [] else [$custom] end) | unique' \
    2>/dev/null)" || oid_mappings="[]"

  url() { printf 'https://%s.%s%s' "$1" "$INTERNAL_DOMAIN" "$2"; }

  # Flows are referenced by UUID in provider payloads now; the slugs only go
  # into this lookup. The default flows are applied by the worker's system
  # blueprints after a fresh IdP start, later than the liveness probe — take a
  # bounded wait so a post-boot converge run still sees them.
  flow_pk() {
    for _ in $(seq 1 30); do
      pk="$(api "/api/v3/flows/instances/?slug=$1" | jq -r '.results[0].pk // empty' 2>/dev/null)"
      [ -n "$pk" ] && { printf '%s\n' "$pk" && return 0; }
      sleep 5
    done
    warn "flow $1 not found within the bounded wait; providers not created"
    return 1
  }
  authz_flow="$(flow_pk 'default-provider-authorization-implicit-consent')"
  inval_flow="$(flow_pk 'default-provider-invalidation-flow')"

  # Provider named like the application slug; existing providers are left
  # untouched but re-read (pk|client_id|client_secret) so a lost copy
  # converges back to the current secret.
  ensure_oauth2() {
    local app="$1" rurl="$2" p
    p="$(api "/api/v3/providers/oauth2/?name=${app}" \
      | jq -r '.results[0] | "\(.pk // "")|\(.client_id // "")|\(.client_secret // "")"' 2>/dev/null)" || p="|" 
    if [ -z "$(cut -d'|' -f1 <<<"$p")" ]; then
      if [ -n "$authz_flow" ] && [ -n "$inval_flow" ]; then
        p="$(api_post '/api/v3/providers/oauth2/' \
          "$(jq -cn --arg name "$app" \
            --arg flow "$authz_flow" --arg iflow "$inval_flow" \
            --arg rurl "$rurl" --argjson maps "$oid_mappings" \
            '{name: $name, authorization_flow: $flow, invalidation_flow: $iflow, redirect_uris: [{matching_mode: "strict", url: $rurl}], sub_mode: "user_email", property_mappings: $maps, access_code_validity: "hours=1", access_token_validity: "hours=12", refresh_token_validity: "days=30"}')" \
          | jq -r '"\(.pk // "")|\(.client_id // "")|\(.client_secret // "")"' 2>/dev/null)" || p=""
      else
        echo "warning: provider $app skipped (provider flows missing)" >&2
      fi
    fi
    printf '%s\n' "$p"
  }

  ensure_application() {
    local slug="$1" pname="$2" launch="$3" provider="$4"
    if [ -z "$provider" ]; then
      echo "application:$slug: skipped (no provider)" >&2
      return 1
    fi
    if api "/api/v3/core/applications/${slug}/" > /dev/null 2>&1; then
      echo "application:$slug: present"
      return 0
    fi
    api_post '/api/v3/core/applications/' \
      "$(jq -cn --arg slug "$slug" --arg name "$pname" --arg launch "$launch" --arg provider "$provider" \
        '{name: $name, slug: $slug, meta_launch_url: $launch, provider: $provider}')" > /dev/null \
      && echo "application:$slug: created"
  }

  r="$(ensure_oauth2 immich-homelab "$(url immich /auth/login)")" && immich_pair="$r" || immich_pair=""
  ensure_application immich-homelab 'Immich' "$(url immich '')" "$(cut -d'|' -f1 <<<"$immich_pair")"

  r="$(ensure_oauth2 beszel-homelab "$(url beszel /api/oauth2-redirect)")" && beszel_pair="$r" || beszel_pair=""
  ensure_application beszel-homelab 'Beszel' "$(url beszel '')" "$(cut -d'|' -f1 <<<"$beszel_pair")"

  r="$(ensure_oauth2 budget-homelab "$(url budget /openid/callback)")" && budget_pair="$r" || budget_pair=""
  ensure_application budget-homelab 'Actual Budget' "$(url budget '')" "$(cut -d'|' -f1 <<<"$budget_pair")"

  r="$(ensure_oauth2 git-homelab "$(url git /user/oauth2/authentik/callback)")" && git_pair="$r" || git_pair=""
  ensure_application git-homelab 'Forgejo' "$(url git '')" "$(cut -d'|' -f1 <<<"$git_pair")"

  r="$(ensure_oauth2 vault-homelab "$(url vault /identity/connect/oidc-signin)")" && vault_pair="$r" || vault_pair=""
  ensure_application vault-homelab 'Vaultwarden' "$(url vault '')" "$(cut -d'|' -f1 <<<"$vault_pair")"

  # Proxy provider + outpost for the forward-auth gate (Navidrome); the proxy
  # provider assigns mappings and callback properties itself on create, so
  # only the essentials go into the POST.
  proxy_pk="$(api '/api/v3/providers/proxy/?name=navidrome-homelab' \
    | jq -r '.results[0].pk // empty' 2>/dev/null)" || proxy_pk=""
  if [ -z "$proxy_pk" ]; then
    if [ -n "$authz_flow" ] && [ -n "$inval_flow" ]; then
      proxy_pk="$(api_post '/api/v3/providers/proxy/' \
        "$(jq -cn --arg name 'navidrome-homelab' \
          --arg flow "$authz_flow" --arg iflow "$inval_flow" \
          --arg host "$(url music '')" \
          '{name: $name, authorization_flow: $flow, invalidation_flow: $iflow, external_host: $host, mode: "forward_single"}')" \
        | jq -r '.pk' 2>/dev/null)" && echo "proxy provider:navidrome-homelab: created" || proxy_pk=""
    else
      echo "warning: proxy provider skipped (provider flows missing)" >&2
    fi
  else
    echo "proxy provider:navidrome-homelab: present"
  fi
  ensure_application navidrome-homelab 'Navidrome' "$(url music '')" "$proxy_pk"

  # 2026.x moved the outpost config for service accounts to outposts/proxy/
  # (read-only); outposts themselves are managed at outposts/instances/. The
  # name filter declares multiple lookups, so the query must use the explicit
  # `name__iexact` form (a bare ?name= is silently ignored and matches any
  # outpost, including the managed embedded one).
  outpost_pk="$(api "/api/v3/outposts/instances/?name__iexact=$OUTPOST_NAME" \
    | jq -r '.results[0].pk // empty' 2>/dev/null)" || outpost_pk=""
  if [ -z "$outpost_pk" ]; then
    if [ -z "$proxy_pk" ]; then
      echo "warning: outpost skipped (no proxy provider)" >&2
    else
      outpost_pk="$(api_post '/api/v3/outposts/instances/' \
        "$(jq -cn --arg name "$OUTPOST_NAME" --arg provider "$proxy_pk" --arg host "$issuer" \
          '{name: $name, type: "proxy", providers: [$provider], config: {authentik_host: $host, authentik_host_browser: $host}}')" \
        | jq -r '.pk' 2>/dev/null)" && echo "outpost:$OUTPOST_NAME: created" || outpost_pk=""
    fi
  else
    echo "outpost:$OUTPOST_NAME: present"
  fi
  outpost_token="$(api "/api/v3/core/tokens/ak-outpost-${outpost_pk}-api/view_key/" \
    | jq -r '.key' 2>/dev/null)" || outpost_token=""

  # --- Vaultwarden SSO keys into its converge-owned env file -----------------
  # Static config keeps SSO_ONLY=false (password login stays); enablement
  # and credentials come from the env file entries.
  vault_id="$(cut -d'|' -f2 <<<"$vault_pair")"
  vault_secret="$(cut -d'|' -f3 <<<"$vault_pair")"
  if [ -n "$vault_id" ] && [ -n "$vault_secret" ]; then
    vw_set SSO_ENABLED true
    vw_set SSO_CLIENT_ID "$vault_id"
    vw_set SSO_CLIENT_SECRET "$vault_secret"
    vw_set SSO_AUTHORITY "$issuer/application/o/vault-homelab"
    echo "vaultwarden: SSO entries staged in converge.env"
  else
    echo "warning: vaultwarden SSO credentials missing; vault keeps password-only login" >&2
  fi

  # --- Beszel OIDC on the users collection -----------------------------------
  # PocketBase keeps the provider config on the `users` auth collection; a
  # partial PATCH merges the providers list by name.
  beszel_id="$(cut -d'|' -f2 <<<"$beszel_pair")"
  beszel_secret="$(cut -d'|' -f3 <<<"$beszel_pair")"
  if [ -n "$beszel_id" ] && [ -n "$beszel_secret" ] && [ -n "$beszel_hub_token" ]; then
    curl -fsS -X PATCH 'http://127.0.0.1:8090/api/collections/users' \
      -H "Authorization: $beszel_hub_token" -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg id "$beszel_id" --arg secret "$beszel_secret" --arg isu "$issuer/application/o/beszel-homelab" \
        '{oauth2: {enabled: true, providers: [{name: "oidc", clientId: $id, clientSecret: $secret, authURL: ($isu + "/authorize"), tokenURL: ($isu + "/token"), userInfoURL: ($isu + "/userinfo"), displayName: "authentik"}]}}')" \
      | jq -e '.id' > /dev/null \
      && echo "beszel: oidc provider set on the users collection" \
      || echo "warning: beszel oidc registration failed; hub keeps password login" >&2
  else
    echo "warning: beszel SSO credentials missing; hub keeps password login" >&2
  fi

  # --- Forgejo OAuth2 auth source (CLI) --------------------------------------
  git_id="$(cut -d'|' -f2 <<<"$git_pair")"
  git_secret="$(cut -d'|' -f3 <<<"$git_pair")"
  if [ -n "$git_id" ] && [ -n "$git_secret" ]; then
    # The auth source list decides skip-vs-create, exactly like the pipeline
    # version did.
    if fj auth list 2>/dev/null | grep -qw authentik; then
      echo "forgejo: auth source present"
    else
      fjauth() {
        runuser -u forgejo -- env \
          SSL_CERT_FILE="$IDP_CA_BUNDLE" \
          HOME="$FORGEJO_STATE_DIR" \
          FORGEJO_WORK_DIR="$FORGEJO_STATE_DIR" \
          FORGEJO_CUSTOM="$FORGEJO_STATE_DIR/custom" \
          "$FORGEJO_EXEC" admin auth "$@"
      }
      out="$(fjauth add-oauth --name authentik --provider openidConnect \
        --key "$git_id" --secret "$git_secret" \
        --auto-discover-url "$issuer/application/o/git-homelab/.well-known/openid-configuration" 2>&1)"
      if [ $? -eq 0 ]; then
        echo "forgejo: auth source created (redirect https://git.$INTERNAL_DOMAIN/user/oauth2/authentik/callback)"
      elif grep -qF "already exists" <<<"${out:-}"; then
        echo "forgejo: auth source present"
      else
        echo "warning: forgejo auth source registration failed: ${out:0:200}; forgejo stays on local logins" >&2
      fi
    fi
  else
    echo "warning: forgejo SSO credentials missing; Forgejo stays on local logins" >&2
  fi

  # --- Immich OAuth system config via the admin API --------------------------
  immich_id="$(cut -d'|' -f2 <<<"$immich_pair")"
  immich_secret="$(cut -d'|' -f3 <<<"$immich_pair")"
  if [ -z "$immich_login" ]; then
    immich_login="$(curl -fsS -X POST "https://immich.$INTERNAL_DOMAIN/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg email "$admin_email" --arg pw "$admin_password" '{email: $email, password: $pw}')" \
      | jq -r '.accessToken // empty' 2>/dev/null)" || immich_login=""
  fi
  if [ -z "$immich_id" ] || [ -z "$immich_secret" ]; then
    echo "warning: immich SSO credentials missing; immich stays on local logins" >&2
  elif [ -z "$immich_login" ]; then
    echo "warning: immich admin login failed; oauth config not applied" >&2
  else
    # The update endpoint takes the whole admin config schema and the config
    # GET omits the fields hidden by immich's API visibility filters, so the
    # oauth object is deep-merged over the fetched config and the config's
    # own defaults. The payloads ride files: every fetch/merge failure
    # surfaces as its own exit status instead of an empty silent capture,
    # and the PUT body reads straight from disk.
    immich_tmp="$(mktemp -d "${TMPDIR:-/tmp}/converge-immich.XXXXXX")" || immich_tmp=""
    if [ -z "$immich_tmp" ]; then
      echo "warning: immich oauth config not applied (merge workspace unavailable)" >&2
    else
      jq -cn --arg id "$immich_id" --arg secret "$immich_secret" \
        --arg isu "$issuer/application/o/immich-homelab" \
        '{enabled: true, autoRegister: true, autoLaunch: false, buttonText: "Login with authentik", clientId: $id, clientSecret: $secret, issuerUrl: $isu, scope: "openid email profile", tokenEndpointAuthMethod: "client_secret_post", signingAlgorithm: "RS256"}' \
        > "$immich_tmp/oauth" \
        && curl -fsS "https://immich.$INTERNAL_DOMAIN/api/system-config" \
          -H "Authorization: Bearer $immich_login" \
          > "$immich_tmp/current" \
        && curl -fsS "https://immich.$INTERNAL_DOMAIN/api/system-config/defaults" \
          -H "Authorization: Bearer $immich_login" \
          > "$immich_tmp/defaults" \
        && jq -c -n --slurpfile cur "$immich_tmp/current" --slurpfile def "$immich_tmp/defaults" \
          --slurpfile oauth "$immich_tmp/oauth" \
          '$def[0] * $cur[0] | .oauth = (($def[0].oauth // {}) * ($cur[0].oauth // {}) * $oauth[0])' \
          > "$immich_tmp/merged"
      if [ "$(jq -r --slurpfile want "$immich_tmp/oauth" \
        '.oauth | {enabled, autoRegister, clientId, clientSecret, issuerUrl} == ($want[0] | {enabled, autoRegister, clientId, clientSecret, issuerUrl})' \
        "$immich_tmp/current" 2>/dev/null)" = "true" ]; then
        echo "immich: oauth system config current"
      elif [ ! -s "$immich_tmp/merged" ]; then
        echo "warning: immich system config fetch or merge failed; oauth config not applied" >&2
        echo "immich merge state: oauth=$(wc -c < "$immich_tmp/oauth" 2>/dev/null || echo -) current=$(wc -c < "$immich_tmp/current" 2>/dev/null || echo -) defaults=$(wc -c < "$immich_tmp/defaults" 2>/dev/null || echo -) merged=$(wc -c < "$immich_tmp/merged" 2>/dev/null || echo -)" >&2
      else
        immich_code="$(curl -sS -o "$immich_tmp/resp" -w '%{http_code}' -X PUT \
          "https://immich.$INTERNAL_DOMAIN/api/system-config" \
          -H 'Content-Type: application/json' -H "Authorization: Bearer $immich_login" \
          --data @"$immich_tmp/merged")" || immich_code=""
        case "$immich_code" in
          200|204)
            echo "immich: oauth system config updated" ;;
          *)
            echo "warning: immich OAuth config failed (HTTP $immich_code: $(head -c 300 "$immich_tmp/resp")); immich keeps local logins" >&2
            ;;
        esac
      fi
      rm -rf "$immich_tmp"
    fi
  fi

  # --- Actual openid activation (sqlite surgery) ------------------------------
  budget_id="$(cut -d'|' -f2 <<<"$budget_pair")"
  budget_secret="$(cut -d'|' -f3 <<<"$budget_pair")"
  if [ -n "$budget_id" ] && [ -n "$budget_secret" ]; then
    actual_json="$(jq -cn --arg issuer "$issuer/application/o/budget-homelab" --arg cid "$budget_id" --arg cs "$budget_secret" \
      --arg host "https://budget.$INTERNAL_DOMAIN" \
      '{issuer: $issuer, client_id: $cid, client_secret: $cs, server_hostname: $host}')"
    actual_db="$ACTUAL_SERVER_FILES/account.sqlite"
    current="$(runuser -u actual -- "$SQLITE" "$actual_db" "SELECT extra_data FROM auth WHERE method='openid';" 2>/dev/null)" \
      || current=""
    if [ "$current" = "$actual_json" ]; then
      echo "actual: openid config current"
    else
      runuser -u actual -- "$SQLITE" "$actual_db" \
        "BEGIN; DELETE FROM auth WHERE method='openid'; UPDATE auth SET active=0; INSERT INTO auth (method, display_name, extra_data, active) VALUES ('openid', 'OpenID', '$(printf "%s" "$actual_json" | sed "s/'/''/g")', 1); COMMIT;" >/dev/null \
        && echo "actual: openid config bootstrapped" \
        || echo "warning: actual openid activation failed; budget stays on password login" >&2
    fi
  else
    echo "warning: actual SSO credentials missing; Actual stays on password login" >&2
  fi

  # --- Outpost token into the stack's outpost env file ------------------------
  # The consuming authentik module owns the file path and reads it via
  # compose env_file; converge only supplies content and re-ups the outpost
  # container when the token changed.
  if [ -z "$outpost_token" ]; then
    echo "warning: outpost token missing; Navidrome forward-auth stays disabled" >&2
  else
    outpost_tmp="$AUTHENTIK_OUTPOST_ENV.converge-tmp"
    printf 'AUTHENTIK_TOKEN=%s\n' "$outpost_token" > "$outpost_tmp"
    if [ -f "$AUTHENTIK_OUTPOST_ENV" ] && cmp -s "$outpost_tmp" "$AUTHENTIK_OUTPOST_ENV"; then
      rm -f "$outpost_tmp"
      echo "authentik: outpost token current"
    else
      install -m 600 "$outpost_tmp" "$AUTHENTIK_OUTPOST_ENV"
      rm -f "$outpost_tmp"
      # Recreate even when the compose config is unchanged (the changed env
      # file alone would be a no-op): the first creation can predate the CA
      # bundle the outpost container mounts.
      (cd "$AUTHENTIK_DIR" && docker-compose up -d --no-deps --force-recreate outpost > /dev/null 2>&1) \
        && echo "authentik: outpost token deployed (outpost re-upped)" \
        || echo "warning: authentik outpost re-up failed" >&2
    fi
  fi
}

# --- Run ----------------------------------------------------------------------

step "beszel agent key"
beszel_agent_step || warn "beszel agent step failed"
step "beszel hub admin"
beszel_hub_step || warn "beszel hub step failed"
step "forgejo break-glass admin"
forgejo_step || warn "forgejo break-glass step failed"
step "vaultwarden admin hash"
vaultwarden_step || warn "vaultwarden admin step failed"
step "immich break-glass"
immich_step || warn "immich break-glass step failed"
step "actual owner"
actual_step || warn "actual step failed"
step "navidrome break-glass"
navidrome_step || warn "navidrome step failed"
step "IdP provisioning"
# The unhealthy-after-bounded-wait IdP is the one unit-fatal case (per the
# header): everything else in the chain degrades to warnings.
idp_chain || { warn "IdP provisioning failed; rerunning the unit converges once it is healthy"; exit 1; }
vw_commit
echo "converge: done"
