#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# Navidrome: break-glass admin, the forward-auth proxy provider with its outpost, and the outpost token deployment.
# Sourced by converge.sh when the app is enabled; hooks: navidrome_init,
# navidrome_breakglass, navidrome_idp_provider, navidrome_idp_sso, navidrome_finish.

# The outpost env file is written by the outpost token deployment below.
navidrome_init() {
  register_tmp "$AUTHENTIK_OUTPOST_ENV.converge-tmp"
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

navidrome_breakglass() {
  step "navidrome break-glass"
  navidrome_step || warn "navidrome step failed"
}

navidrome_idp_provider() {
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
}

navidrome_idp_sso() {
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
