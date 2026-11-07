# Drive script of the VM boot test: boots the demo instance's host
# configuration under QEMU and asserts the built system's runtime state. The
# guest is the demo host configuration itself with ./testvm.nix stacked on
# top — not a copy. The flake substitutes the
# @internalDomain@ and @outpostName@ placeholders from the evaluated host.
#
# Artifacts the boot depends on (compose images, the sops fixture) ride the
# system closure the VM profile wires in; nothing here needs network access.
# The environment stage (./testvm.nix) neutralizes the physical host's
# externals: Borg → StorageBox, Healthchecks.io heartbeats, NetBird and the
# INWX DNS-01 TLS issuance.

start_all()

machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("docker.service")
machine.wait_for_unit("immich-stack.service")
machine.wait_for_unit("authentik-stack.service")
machine.wait_for_unit("caddy.service")
machine.wait_for_unit("forgejo.service")
machine.wait_for_unit("vaultwarden.service")
machine.wait_for_unit("navidrome.service")
machine.wait_for_unit("actual.service")
machine.wait_for_unit("beszel-hub.service")
machine.wait_for_unit("beszel-agent.service")

# Core assertion: converge runs with every consumer up. The boot-time run of
# the unit may lose the IdP's readiness race on a fresh IdP database — the
# unit is by design re-runnable ("rerunning the unit converges once it is
# healthy") — so the asserted run is this restart once the IdP answers, plus
# an idempotency run from the converged state. The converge-managed env stubs
# then carry the provisioned runtime state.
machine.wait_for_unit("caddy-ca-trust.service")
machine.wait_until_succeeds(
    "curl --cacert /run/homelab-vm-test/caddy-ca-bundle.crt -fsS https://auth.@internalDomain@/-/health/live/ > /dev/null",
    timeout=900,
)
machine.succeed("systemctl restart homelab-converge.service")
machine.succeed("systemctl is-active --quiet homelab-converge.service")
machine.succeed(
    "test -s /run/homelab-vm-test/caddy-ca-bundle.crt",
    # The converge-managed env stubs now carry the provisioned runtime state:
    # the outpost token (proxied by the Navidrome forward-auth) and the
    # vaultwarden SSO registration.
    "test -s /mnt/fast-pool/appdata/authentik/outpost.env",
    "grep -q '^AUTHENTIK_TOKEN=.' /mnt/fast-pool/appdata/authentik/outpost.env",
    "grep -q '^SSO_ENABLED=true$' /mnt/fast-pool/appdata/vaultwarden/converge.env",
    "grep -q '^SSO_CLIENT_ID=.' /mnt/fast-pool/appdata/vaultwarden/converge.env",
)

# Idempotency: restart the converged unit; it must converge again exit-0 —
# with the chain in place this run logs "present"/"current" instead of
# recreating (the journal then proves every IdP step converged on its own).
machine.succeed("systemctl restart homelab-converge.service")
machine.succeed("systemctl is-active --quiet homelab-converge.service")
machine.succeed(
    """journalctl -u homelab-converge.service --no-pager | grep -qF 'group:users: present'""",
    """journalctl -u homelab-converge.service --no-pager | grep -qE 'mapping:oauth2-email-verified: (created|present)'""",
    """journalctl -u homelab-converge.service --no-pager | grep -qF 'proxy provider:navidrome-homelab: present'""",
    """journalctl -u homelab-converge.service --no-pager | grep -qF 'outpost:@outpostName@: present'""",
    """journalctl -u homelab-converge.service --no-pager | grep -qF 'vaultwarden: SSO entries staged in converge.env'""",
    "echo converge idempotency: all provisioning steps present" ,
)

# The service tree: every unit the boot flow creates must stay healthy.
machine.succeed(
    "systemctl is-active caddy.service",
    "systemctl is-active forgejo.service",
    "systemctl is-active vaultwarden.service",
    "systemctl is-active navidrome.service",
    "systemctl is-active actual.service",
    "systemctl is-active beszel-hub.service",
    "systemctl is-active beszel-agent.service",
    "systemctl is-active immich-stack.service",
    "systemctl is-active authentik-stack.service",
    "systemctl is-active appdata-dirs.service",
    "systemctl is-active homelab-converge-files.service",
)

# Every compose container of both stacks must run (the outpost token comes
# from converge; the stack restarts the container into a healthy state).
machine.succeed(
    """for ctr in authentik_server authentik_worker authentik_postgres \\
      immich_server immich_machine_learning immich_redis immich_postgres; do
      state="$(docker inspect -f '{{.State.Running}}' "$ctr")"
      [ "$state" = "true" ] || { echo "container $ctr not running (state=$state)"; exit 1; }
    done""",
    "echo compose containers: all running",
    """state="$(docker inspect -f '{{.State.Running}}' authentik_outpost)"
    [ "$state" = "true" ] || {
      journalctl -u authentik-stack.service --no-pager | grep -E "outpost|token" | tail -20
      echo "container authentik_outpost not running (state=$state)"; exit 1;
    }""",
    "echo compose containers: outpost running",
)

# Both pools must be imported with unlocked keys and the declared datasets
# mounted at exactly the production mountpoints.
machine.succeed(
    "zpool list -H fast-pool tank",
    # Production vdev layouts: mirrored SSDs, raidz2 HDDs (not a stripe).
    "zpool status fast-pool | grep -qE '^\\s+mirror-0\\s'",
    "zpool status tank | grep -qE '^\\s+raidz2-0\\s'",
    """for ds in \\
      fast-pool/appdata \\
      fast-pool/appdata/vaultwarden \\
      fast-pool/appdata/actual-budget \\
      fast-pool/appdata/authentik \\
      fast-pool/appdata/immich/postgres \\
      fast-pool/appdata/forgejo \\
      fast-pool/appdata/navidrome \\
      tank/immich \\
      tank/media/home-videos \\
      tank/media/movies \\
      tank/media/music \\
      tank/storage/users \\
      tank/backups \\
      tank/staging; do
      [ "$(zfs get -H -o value mounted "$ds")" = yes ] || { echo "dataset $ds not mounted"; exit 1; }
    done""",
    "echo zfs: all declared datasets mounted",
)

# The physical host's externals stay neutralized in the guest.
machine.fail("systemctl is-active netbird.service")
machine.fail("systemctl is-active healthchecks-heartbeat.service")

# Smoke HTTP. Vhosts resolve via /etc/hosts and present Caddy's internal CA
# (the bundle the test profile exports from the Caddy state directory).
CA = "/run/homelab-vm-test/caddy-ca-bundle.crt"

# Authentik: health endpoint without credentials, and the converge-used API
# surface (bearer-authed reachability; the guest has no python, so the JSON
# assertions ride plain curl+grep).
machine.succeed(
    f"curl --cacert {CA} -fsS https://auth.@internalDomain@/-/health/live/ > /dev/null",
    "ak_token=$(sed -n 's/^AUTHENTIK_BOOTSTRAP_TOKEN=//p' /run/secrets/authentik.env) && "
    f"code=$(curl --cacert {CA} -s -o /dev/null -w '%{{http_code}}' "
    "-H \"Authorization: Bearer $ak_token\" https://auth.@internalDomain@/api/v3/flows/instances/) && "
    "case $code in 200) ;; *) echo \"auth API smoke got $code\"; exit 1;; esac; echo \"api smoke: $code\"",
    # The provisioned IdP surface (route set of the pinned 2026.8): all six
    # per-app applications and the outpost, listed through the same API
    # converge provisions with.
    "ak_token=$(sed -n 's/^AUTHENTIK_BOOTSTRAP_TOKEN=//p' /run/secrets/authentik.env) && "
    f"apps=$(curl --cacert {CA} -sS -H \"Authorization: Bearer $ak_token\" "
    "https://auth.@internalDomain@/api/v3/core/applications/) && "
    "for s in immich-homelab beszel-homelab budget-homelab git-homelab vault-homelab navidrome-homelab; do "
    "echo \"$apps\" | grep -qF \"$s\" || { echo \"application $s missing\"; exit 1; }; done",
    "ak_token=$(sed -n 's/^AUTHENTIK_BOOTSTRAP_TOKEN=//p' /run/secrets/authentik.env) && "
    f"curl --cacert {CA} -sS -H \"Authorization: Bearer $ak_token\" "
    "'https://auth.@internalDomain@/api/v3/outposts/instances/?name=@outpostName@' | grep -q '@outpostName@'",
)

machine.succeed(
    f"curl --cacert {CA} -fsS https://vault.@internalDomain@/ > /dev/null",
    f"curl --cacert {CA} -fsS https://git.@internalDomain@/ > /dev/null",
    f"curl --cacert {CA} -fsS https://immich.@internalDomain@/api/server/version > /dev/null",
)

# Navidrome: the forward-auth gate routes through converge's outpost; once
# the outpost is provisioned and running, the gate bounces the anonymous
# visit to the authentik authorization flow.
machine.succeed(
    """code="$(curl --cacert /run/homelab-vm-test/caddy-ca-bundle.crt \\
      -o /dev/null -w '%{http_code}' https://music.@internalDomain@/)" && \\
      case $code in 200|302) ;; *) echo "music gate smoke got $code"; exit 1;; esac""",
    "curl -fsS --max-time 10 http://127.0.0.1:9302/outpost.goauthentik.io/ping > /dev/null",
)

machine.succeed(
    f"curl --cacert {CA} -fsS https://beszel.@internalDomain@/api/health > /dev/null",
)

# Actual Budget and Navidrome local surfaces (converge seeded the owner
# identities against the live services).
machine.succeed("curl -fsS http://127.0.0.1:5006/account/needs-bootstrap > /dev/null")
machine.succeed("curl -fsS http://127.0.0.1:4533/ > /dev/null")

# Restore drill data: the seed script's host half writes a Forgejo repository
# and an Immich photo through the apps' APIs before the dumps are taken, so the
# dumps below hold known data and the round trip further down can check it.
machine.wait_until_succeeds("docker exec immich_postgres pg_isready -U postgres")
machine.wait_until_succeeds("docker exec authentik_postgres pg_isready -U authentik")
DRILL = (
    f"CURL_CA_BUNDLE={CA} INTERNAL_DOMAIN=@internalDomain@ FORGEJO_PORT=3000 "
    "FORGEJO_ENABLED=true IMMICH_ENABLED=true "
)
manifest = machine.succeed(DRILL + "MODE=seed bash /etc/drill-data-remote.sh").strip()
machine.succeed(
    "MANIFEST='" + manifest + "' " + DRILL + "MODE=verify bash /etc/drill-data-remote.sh"
)

# Nightly dumps: run the job once and check that every app's dump landed,
# that the stopped forgejo is back, and that no backup snapshot is left.
machine.succeed("systemctl start backup-databases.service")
machine.succeed(
    """for pat in \
      vaultwarden/vaultwarden_*.sqlite3 \
      actual-budget/actual_account_*.sqlite3 \
      immich/immich_db_*.sql.gz \
      authentik/authentik_db_*.dump \
      forgejo/forgejo_dump_*.zip; do
      f="$(ls /mnt/tank/backups/$pat | head -n 1)"
      [ -s "$f" ] || { echo "backup $pat missing or empty"; exit 1; }
    done""",
    "systemctl is-active forgejo.service",
    "! zfs list -H -t snapshot -o name | grep -q '@backup-snap'",
)

# The dumps must be restorable material, not just non-empty files.
machine.succeed(
    """for f in /mnt/tank/backups/vaultwarden/vaultwarden_*.sqlite3 \
      /mnt/tank/backups/actual-budget/actual_account_*.sqlite3; do
      [ "$(sqlite3 "$f" 'PRAGMA integrity_check')" = ok ] || { echo "$f fails the integrity check"; exit 1; }
    done""",
    "gzip -t /mnt/tank/backups/immich/immich_db_*.sql.gz",
    "docker exec -i authentik_postgres pg_restore --list < /mnt/tank/backups/authentik/authentik_db_*.dump > /dev/null",
    "unzip -tq /mnt/tank/backups/forgejo/forgejo_dump_*.zip",
)

# Offsite backup and restore, end to end against a local Borg repository (the
# test profile points the production job at it). The job must succeed and
# produce an archive; then everything the Immich restore needs is deleted from
# the host, so it can only come back through `borg extract`.
BORG = (
    "BORG_REPO=/var/lib/borg-test-repo "
    "BORG_PASSCOMMAND='cat /run/secrets/borg_passphrase' "
)
# --wait: the job is still initialising the repository when plain `start` returns.
machine.succeed("systemctl start --wait borgbackup-job-storagebox.service")
archive = machine.succeed(BORG + "borg list --short --last 1").strip()
assert archive, "the Borg job produced no archive"
machine.succeed(
    BORG + f"borg list --short '::{archive}' | grep -q '^mnt/tank/backups/immich/immich_db_'",
)

# Immich round trip (the restore drill's runbook, sections 2 and 3): lose the
# server, the library file, the local dumps and the whole database; fetch files
# and dumps from Borg, restore the dump and find the seeded photo byte-identical.
machine.succeed(
    """db="$(docker exec immich_postgres printenv POSTGRES_DB)" && \
      docker stop immich_server && \
      docker exec immich_postgres psql -U postgres -d postgres \
        -c "DROP DATABASE \"$db\" WITH (FORCE)" && \
      find /mnt/tank/immich -type f -name '*.jpg' \
        ! -path '*/thumbs/*' ! -path '*/encoded-video/*' ! -path '*/backups/*' -delete && \
      rm -rf /mnt/tank/backups/*""",
)
machine.fail(
    "docker exec immich_postgres psql -U postgres -lqt | grep -qw \"$(docker exec immich_postgres printenv POSTGRES_DB)\""
)
machine.fail("ls /mnt/tank/backups/immich/immich_db_*.sql.gz")
machine.succeed(
    # Archive paths are absolute without the leading slash: extracting from /
    # puts files back where they were.
    "cd / && " + BORG + f"borg extract '::{archive}' mnt/tank/immich mnt/tank/backups",
    "gunzip -c /mnt/tank/backups/immich/immich_db_*.sql.gz "
    "| docker exec -i immich_postgres psql -U postgres > /dev/null",
    "docker start immich_server",
)
machine.wait_until_succeeds(
    "MANIFEST='" + manifest + "' " + DRILL + "MODE=verify bash /etc/drill-data-remote.sh"
)

print("vm-test: OK")
