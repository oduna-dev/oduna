#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# IdP provisioning chain of homelab-converge, sourced by converge.sh: the
# shared authentik plumbing (health wait, API helpers, groups, scope mapping,
# flows, provider and application helpers). The apps register their own
# provider and SSO steps as <app>_idp_provider and <app>_idp_sso hooks.

# --- IdP-dependent section ------------------------------------------------------
# Groups, shared scope mapping, one application/provider pair per OIDC app plus
# the Navidrome proxy provider and outpost, then the per-app SSO
# registrations. Client credentials stay inside the IdP and the receiving
# app's own store (or the converge-owned vaultwarden env file); the outpost
# token is written to the outpost env file of the authentik stack.

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
  # The liveness endpoint answers before the bootstrap token exists (the API
  # then replies 403 "Token invalid/expired"), so wait for it to be accepted.
  for _ in $(seq 1 20); do
    curl -fsS --max-time 5 -H "Authorization: Bearer $ak_token" \
      "$issuer/api/v3/core/users/me/" > /dev/null 2>&1 && break
    sleep 3
  done
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
  api_patch() { ak_call PATCH "$1" "$2"; }

  ensure_group() {
    if [ -z "$(api "/api/v3/core/groups/?name=$1" | jq -r '.results[0].pk // empty' 2>/dev/null)" ]; then
      api_post '/api/v3/core/groups/' "$(jq -cn --arg name "$1" '{name: $name}')" > /dev/null \
        && echo "group:$1: created"
    else
      echo "group:$1: present"
    fi
  }
  ensure_group "$IDP_USER_GROUP"
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

  # Providers without a signing key sign ID tokens with HS256 and publish an
  # empty JWKS, which Vaultwarden's discovery rejects; every provider gets
  # authentik's self-signed key pair (RS256).
  signing_key="$(api '/api/v3/crypto/certificatekeypairs/?has_key=true&page_size=100' \
    | jq -r '[.results[] | select(.name == "authentik Self-signed Certificate")][0].pk // empty' 2>/dev/null)" || signing_key=""
  [ -n "$signing_key" ] || warn "authentik self-signed signing key not found; providers keep HS256"

  # Authentik leaves the allowed grant types of an API-created provider
  # empty, which rejects every authorization-code login.
  oauth2_grants='["authorization_code","refresh_token"]'

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
    local app="$1" rurl="$2" p cur
    p="$(api "/api/v3/providers/oauth2/?name=${app}" \
      | jq -r '.results[0] | "\(.pk // "")|\(.client_id // "")|\(.client_secret // "")"' 2>/dev/null)" || p="|" 
    # Existing providers: repair a missing signing key and empty grant types.
    cur="$(api "/api/v3/providers/oauth2/?name=${app}" \
      | jq -c --arg key "$signing_key" --argjson grants "$oauth2_grants" \
        '.results[0] | select(. != null) | {pk}
          + (if .signing_key == null and $key != "" then {signing_key: $key} else {} end)
          + (if (.grant_types // []) == [] then {grant_types: $grants} else {} end)' 2>/dev/null)" || cur=""
    if [ -n "$cur" ] && [ "$(jq 'length' <<<"$cur")" -gt 1 ]; then
      api_patch "/api/v3/providers/oauth2/$(jq -r .pk <<<"$cur")/" "$(jq -c 'del(.pk)' <<<"$cur")" > /dev/null \
        && echo "provider:$app: signing key / grant types repaired" >&2
    fi
    if [ -z "$(cut -d'|' -f1 <<<"$p")" ]; then
      if [ -n "$authz_flow" ] && [ -n "$inval_flow" ]; then
        p="$(api_post '/api/v3/providers/oauth2/' \
          "$(jq -cn --arg name "$app" \
            --arg flow "$authz_flow" --arg iflow "$inval_flow" \
            --arg rurl "$rurl" --argjson maps "$oid_mappings" --arg key "$signing_key" --argjson grants "$oauth2_grants" \
            '{name: $name, authorization_flow: $flow, invalidation_flow: $iflow, redirect_uris: [{matching_mode: "strict", url: $rurl}], sub_mode: "user_email", property_mappings: $maps, access_code_validity: "hours=1", access_token_validity: "hours=12", refresh_token_validity: "days=30", grant_types: $grants} + (if $key == "" then {} else {signing_key: $key} end)')" \
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

  # Per-app provider/application pairs, then the per-app SSO registrations.
  local app id
  for app in $CONVERGE_APPS; do
    id="${app//-/_}"
    if declare -F "${id}_idp_provider" > /dev/null; then "${id}_idp_provider"; fi
  done
  for app in $CONVERGE_APPS; do
    id="${app//-/_}"
    if declare -F "${id}_idp_sso" > /dev/null; then "${id}_idp_sso"; fi
  done
  # Failing steps degrade to warnings; only an unhealthy IdP is fatal.
  return 0
}
