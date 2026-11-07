#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# Beszel: agent key, hub superuser, UI admin and the localhost system; OIDC on the users collection.
# Sourced by converge.sh when the app is enabled; hooks: beszel_init,
# beszel_breakglass, beszel_idp_provider, beszel_idp_sso, beszel_finish.

beszel_pair="|"

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

beszel_breakglass() {
  step "beszel agent key"
  beszel_agent_step || warn "beszel agent step failed"
  step "beszel hub admin"
  beszel_hub_step || warn "beszel hub step failed"
}

beszel_idp_provider() {
  r="$(ensure_oauth2 beszel-homelab "$(url beszel /api/oauth2-redirect)")" && beszel_pair="$r" || beszel_pair=""
  ensure_application beszel-homelab 'Beszel' "$(url beszel '')" "$(cut -d'|' -f1 <<<"$beszel_pair")"
}

beszel_idp_sso() {
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
}
