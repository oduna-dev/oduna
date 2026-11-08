#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# Immich: break-glass admin and the OAuth system config.
# Sourced by converge.sh when the app is enabled; hooks: immich_init,
# immich_breakglass, immich_idp_provider, immich_idp_sso, immich_finish.

immich_pair="|"
immich_login=""

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

immich_breakglass() {
  step "immich break-glass"
  immich_step || warn "immich break-glass step failed"
}

immich_idp_provider() {
  r="$(ensure_oauth2 immich-homelab "$(url immich /auth/login)")" && immich_pair="$r" || immich_pair=""
  ensure_application immich-homelab 'Immich' "$(url immich '')" "$(cut -d'|' -f1 <<<"$immich_pair")"
}

immich_idp_sso() {
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
        --arg isu "$issuer/application/o/immich-homelab/" \
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
}
