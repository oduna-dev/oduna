#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# Forgejo: break-glass admin and the OAuth2 auth source.
# Sourced by converge.sh when the app is enabled; hooks: forgejo_init,
# forgejo_breakglass, forgejo_idp_provider, forgejo_idp_sso, forgejo_finish.

git_pair="|"

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

forgejo_breakglass() {
  step "forgejo break-glass admin"
  forgejo_step || warn "forgejo break-glass step failed"
}

forgejo_idp_provider() {
  r="$(ensure_oauth2 git-homelab "$(url git /user/oauth2/authentik/callback)")" && git_pair="$r" || git_pair=""
  ensure_application git-homelab 'Forgejo' "$(url git '')" "$(cut -d'|' -f1 <<<"$git_pair")"
}

forgejo_idp_sso() {
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
}
