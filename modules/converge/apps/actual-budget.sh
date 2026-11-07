#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154
# Actual Budget: owner (break-glass admin) and the openid activation.
# Sourced by converge.sh when the app is enabled; hooks: actual_budget_init,
# actual_budget_breakglass, actual_budget_idp_provider, actual_budget_idp_sso, actual_budget_finish.

budget_pair="|"

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

actual_budget_breakglass() {
  step "actual owner"
  actual_step || warn "actual step failed"
}

actual_budget_idp_provider() {
  r="$(ensure_oauth2 budget-homelab "$(url budget /openid/callback)")" && budget_pair="$r" || budget_pair=""
  ensure_application budget-homelab 'Actual Budget' "$(url budget '')" "$(cut -d'|' -f1 <<<"$budget_pair")"
}

actual_budget_idp_sso() {
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
}
