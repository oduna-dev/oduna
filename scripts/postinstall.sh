#!/usr/bin/env bash
# Post-install convergence (bootstrap stage 2): after the host is back and
# services are up, commit the values that can only exist once the stack runs:
#   - Forgejo Actions runner registration (uuid into the host config, token
#     into sops)
#   - StorageBox Borg key install + repo URL
# Everything app-internal (IdP provisioning, runtime SSO credentials,
# break-glass admin accounts) is owned by the host-side homelab-converge
# service (modules/converge.nix): it runs at every activation and on
# consumer-secret rotation, postinstall only triggers it here.
# Then deploys once and ends at a review/commit stop-point.
#
# The authentik dotenv block may be missing in older committed trees; the
# pre-seed adoption below keeps the locally-generatable entries converged
# even for them.
#
# Usage: postinstall.sh <host> root@<target>   (run from the instance directory)
#
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <host> root@<target>" >&2
  exit 1
fi

host="$1"
target="$2"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap-helpers.sh
source "$here/lib/bootstrap-helpers.sh"

repo_root="$(instance_dir)"
cd "$repo_root"

require_preseed ADMIN_EMAIL ADMIN_PASSWORD STORAGEBOX_USERNAME STORAGEBOX_PASSWORD

# StorageBox interaction needs sshpass; run it from nixpkgs instead of
# requiring a workstation install.
sshpass() { nix run nixpkgs#sshpass -- "$@"; }

if ! ssh -o ConnectTimeout=5 "$target" true; then
  echo "target $target unreachable; run this after bootstrap finished" >&2
  exit 1
fi

# Reviews and commits: secrets plus .sops.yaml (bootstrap stage 1 rewrites
# the &nas age key there; without committing it, fresh clones cannot decrypt).
changed_files=(secrets/secrets.yaml .sops.yaml)
host_file="$(host_dir "$host")/default.nix"

# Single decrypt/edit/encrypt round over the committed secrets file.
plain="$(mktemp)"
trap 'rm -f "$plain"' EXIT
decrypt_secrets_to "$plain"

# --- 1. Forgejo Actions runner ----------------------------------------------------------------
forgejo_exe="$(ssh "$target" 'systemctl cat forgejo | grep "^ExecStart=" | cut -d= -f2 | awk "{print \$1}"')"
fj_work="$(nix eval --raw "$repo_root#nixosConfigurations.${host}.config.homelab.storage.appdataPath")/forgejo"
fj_custom="$fj_work/custom"

# The pre-seed values are interpolated into remote command strings via
# printf %q, which produces self-contained shell quoting; anything further
# wrapped around that output (extra single quotes) breaks on values with
# apostrophes or backslashes.
forgejo_remote="sudo -u forgejo env \
  HOME=$(printf '%q' "$fj_work") \
  FORGEJO_WORK_DIR=$(printf '%q' "$fj_work") \
  FORGEJO_CUSTOM=$(printf '%q' "$fj_custom") \
  $(printf '%q' "$forgejo_exe")"

# The server-side `forgejo-cli actions register` is idempotent and keys the
# runner on its (name, token) pair, so reaching for it unconditionally
# converges both a wiped Forgejo (stale committed uuid/token) and the
# rerun-with-values case.
runner_secret="$(yaml_get_value "$plain" forgejo_runner_token)"
# sops re-encrypts the placeholder as the quoted scalar '...' (a bare ...
# matches YAML's document-end marker, so the emitter is forced to quote it);
# the quote wrapper must come off before the placeholder comparison, like the
# vaultwarden ADMIN_TOKEN handling above.
runner_secret="${runner_secret#\'}"
runner_secret="${runner_secret%\'}"
if [ "$runner_secret" = "..." ] || [ -z "$runner_secret" ]; then
  runner_secret="$(openssl rand -hex 20)"
  yaml_set_value "$plain" forgejo_runner_token "$runner_secret"
fi
uuid="$(ssh "$target" "$forgejo_remote forgejo-cli actions register \
  --name $(printf '%q' "${host}-runner") --secret $(printf '%q' "$runner_secret") | tail -n1")"
if ! grep -qE '^[0-9a-f-]{36}$' <<<"$uuid"; then
  echo "error: forgejo runner registration failed (output: $uuid)" >&2
  exit 1
fi
if grep -q "uuid = \"$uuid\";" "$repo_root/$host_file"; then
  echo "forgejo runner: registration current (uuid $uuid)"
else
  sed -i "s|uuid = \".*\";|uuid = \"$uuid\";|" "$repo_root/$host_file"
  changed_files+=("$host_file")
  echo "forgejo runner: uuid updated to $uuid"
fi

# --- 2. StorageBox: Borg key install + repo URL ------------------------------

if grep -q 'storageBoxRepo = "ssh://' "$repo_root/$host_file"; then
  echo "storagebox: repo URL already configured"
else
  install_key_ok=1
  sshpass -p "$STORAGEBOX_PASSWORD" ssh -p 23 \
    -o 'StrictHostKeyChecking=accept-new' \
    "${STORAGEBOX_USERNAME}@${STORAGEBOX_USERNAME}.your-storagebox.de" install-ssh-key \
    < <(ssh "$target" 'cat /etc/ssh/borg_append_only_key.pub') \
    || install_key_ok=0
  if [ "$install_key_ok" = "1" ]; then
    # The restricted StorageBox shell rejects absolute paths ("/" is
    # read-only); create the repo directory relative to the session's cwd.
    # The directory is named after the first label of the instance domain.
    domain="$(nix eval --raw "$repo_root#nixosConfigurations.${host}.config.homelab.domain")"
    repo_dir="${domain%%.*}-backup"
    sshpass -p "$STORAGEBOX_PASSWORD" ssh -p 23 \
      "${STORAGEBOX_USERNAME}@${STORAGEBOX_USERNAME}.your-storagebox.de" \
      "mkdir -p ./$repo_dir"
    repo_url="ssh://${STORAGEBOX_USERNAME}@${STORAGEBOX_USERNAME}.your-storagebox.de:23/./$repo_dir"
    sed -i "/^  config = {$/a\\
    homelab.backup.storageBoxRepo = \"$repo_url\";" "$repo_root/$host_file"
    changed_files+=("$host_file")
    echo "storagebox: key installed, repo path created"
  else
    echo "warning: storagebox key install failed; Borg job stays disabled" >&2
  fi
fi

# --- 3. Host-side convergence ---------------------------------------------------
# IdP provisioning, runtime SSO credentials and the break-glass admin accounts
# live in the host configuration (modules/converge.nix): they run at every
# activation and whenever a consumed secret rotates, so this run only triggers
# the unit explicitly and shows its journal for the review below.
if ssh "$target" systemctl restart --no-ask-password homelab-converge.service; then
  echo "converge: unit ran (restarted, since a finished oneshot would make a bare start a no-op); journal excerpt:"
  ssh "$target" 'journalctl -u homelab-converge.service --no-pager -n 40'
else
  echo "warning: homelab-converge failed; see its full journal on the host" >&2
  ssh "$target" 'journalctl -u homelab-converge.service --no-pager -n 40' >&2 || true
fi

# --- 4. Write secrets back and deploy ------------------------------------------

yaml_ensure_block "$plain" "authentik.env" \
  "SECRET_KEY=..." \
  "AUTHENTIK_PG_PASSWORD=..." \
  "AUTHENTIK_BOOTSTRAP_PASSWORD=..." \
  "AUTHENTIK_BOOTSTRAP_TOKEN=..." \
  "AUTHENTIK_EMAIL__PASSWORD=..."
apply_preseed_values "$plain"


install_encrypted_secrets "$plain"
git add -N secrets/secrets.yaml

nix fmt >/dev/null 2>&1 </dev/null || true

echo "deploying the updated configuration..."
( cd "$repo_root" && nix run nixpkgs#nixos-rebuild -- \
  switch --flake "$repo_root#$host" \
  --target-host "$target" --build-host "$target" )

# --- 5. Final sweep + review/commit stop-point --------------------------------

printf '\nPost-deploy checks:\n'
if ! "$here/checks.sh" "$host" "$target"; then
  echo "warning: post-deploy checks reported failures (see above)" >&2
fi

printf '\nRepo changes for review:\n'
git status --short
git diff -- "${changed_files[@]}" 2>/dev/null || git diff

read -r -p "Commit these changes now? [y/N] " commit_answer
if [ "$commit_answer" = "y" ] || [ "$commit_answer" = "Y" ]; then
  git add -- "${changed_files[@]}"
  git commit -m "postinstall convergence for ${host}"
else
  echo "not committed; review and commit manually (values are already deployed and active)"
fi
