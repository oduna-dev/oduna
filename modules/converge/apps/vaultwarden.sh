#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# Vaultwarden: break-glass admin token and the SSO keys in the converge-owned env file.
# Sourced by converge.sh when the app is enabled; hooks: vaultwarden_init,
# vaultwarden_breakglass, vaultwarden_idp_provider, vaultwarden_idp_sso, vaultwarden_finish.

vault_pair="|"

# --- converge.env staging (committed once at the end) ----------------------- #
# The file only changes when one of its values materially changes, so the     #
# unit restart only happens then (a random-salted argon2 re-hash would        #
# otherwise churn the file on every activation).                              #
vw_tmp="$VAULTWARDEN_CONVERGE_ENV.converge-tmp"
vaultwarden_init() {
  install -d -o vaultwarden -g vaultwarden -m 700 "$VAULTWARDEN_DATA_DIR"
  register_tmp "$vw_tmp"
  if [ -f "$VAULTWARDEN_CONVERGE_ENV" ]; then
    cat "$VAULTWARDEN_CONVERGE_ENV" > "$vw_tmp"
  else
    : > "$vw_tmp"
  fi
}

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
vaultwarden_finish() {
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

vaultwarden_breakglass() {
  step "vaultwarden admin hash"
  vaultwarden_step || warn "vaultwarden admin step failed"
}

vaultwarden_idp_provider() {
  r="$(ensure_oauth2 vault-homelab "$(url vault /identity/connect/oidc-signin)")" && vault_pair="$r" || vault_pair=""
  ensure_application vault-homelab 'Vaultwarden' "$(url vault '')" "$(cut -d'|' -f1 <<<"$vault_pair")"
}

vaultwarden_idp_sso() {
  # --- Vaultwarden SSO keys into its converge-owned env file -----------------
  # Static config keeps SSO_ONLY=false (password login stays); enablement
  # and credentials come from the env file entries.
  vault_id="$(cut -d'|' -f2 <<<"$vault_pair")"
  vault_secret="$(cut -d'|' -f3 <<<"$vault_pair")"
  if [ -n "$vault_id" ] && [ -n "$vault_secret" ]; then
    vw_set SSO_ENABLED true
    vw_set SSO_CLIENT_ID "$vault_id"
    vw_set SSO_CLIENT_SECRET "$vault_secret"
    vw_set SSO_AUTHORITY "$issuer/application/o/vault-homelab/"
    echo "vaultwarden: SSO entries staged in converge.env"
  else
    echo "warning: vaultwarden SSO credentials missing; vault keeps password-only login" >&2
  fi
}
