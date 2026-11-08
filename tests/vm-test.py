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

import atexit
import time

# Phase timing: the report at exit shows where the minutes of a run go, also
# when an assertion aborts the script.
_t0 = time.monotonic()
_marks = []
_notes = []


def phase(name):
    _marks.append((name, time.monotonic() - _t0))


def measure(title, command):
    _notes.append(title)
    _notes.append(machine.succeed("( " + command + " ) 2>&1 || true"))


def _report():
    for note in _notes:
        print(note)
    print("vm-test timing (seconds since the script started, +seconds per phase):")
    prev = 0.0
    for name, at in _marks:
        print(f"  {at:6.0f}  +{at - prev:5.0f}  {name}")
        prev = at


atexit.register(_report)

start_all()

machine.wait_for_unit("multi-user.target")
phase("multi-user.target")
machine.wait_for_unit("docker.service")
phase("docker.service")
machine.wait_for_unit("immich-stack.service")
phase("immich-stack.service")
machine.wait_for_unit("authentik-stack.service")
phase("authentik-stack.service")
machine.wait_for_unit("caddy.service")
machine.wait_for_unit("forgejo.service")
machine.wait_for_unit("vaultwarden.service")
machine.wait_for_unit("navidrome.service")
machine.wait_for_unit("actual.service")
machine.wait_for_unit("beszel-hub.service")
machine.wait_for_unit("beszel-agent.service")
phase("all units active")
# Where the boot minutes go: the slowest units and the chain to multi-user.
measure(
    "slowest units of the boot (systemd-analyze blame):",
    "systemd-analyze blame --no-pager | head -n 15",
)
measure(
    "critical chain to multi-user.target:",
    "systemd-analyze critical-chain multi-user.target --no-pager",
)
# What the two stack units spent their minutes on: the image loads, how big the
# images are once loaded, what the guest's disk, CPU and 9p store mount can do,
# and what the boot-time converge run waited for. A measurement never fails the
# test.
measure(
    "image loads and stack starts (journal of the stack units):",
    "journalctl -u immich-stack.service -u authentik-stack.service "
    "-o short-monotonic --no-pager | grep -E 'load-images|Starting|Started|Finished'",
)
measure(
    "the boot-time converge run (journal):",
    "journalctl -u homelab-converge.service -o short-monotonic --no-pager "
    "| grep -E 'Starting|Started|Finished|Deactivated|warning|waiting|healthy' | head -n 25",
)
measure(
    "images in the daemon (size once loaded):",
    "docker images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}'",
)
measure(
    "read speed of the largest image tarball over the 9p store mount:",
    "grep -E ' /nix/(.ro-)?store ' /proc/mounts | grep -o 'msize=[0-9]*' | sort -u; "
    "sync; echo 3 > /proc/sys/vm/drop_caches; "
    "f=$(ls -S /nix/store/*-docker-image-*.tar | head -n 1); ls -l \"$f\"; "
    "dd if=\"$f\" of=/dev/null bs=4M 2>&1 | tail -n 1",
)
measure(
    "docker storage and guest resources:",
    "docker info --format 'driver={{.Driver}} root={{.DockerRootDir}}'; "
    "df -h / /var/lib/docker | cat; nproc; free -m | head -n 2; "
    "dd if=/dev/zero of=/var/tmp/ddtest bs=1M count=1024 conv=fdatasync 2>&1 | tail -n 1; "
    "rm -f /var/tmp/ddtest",
)

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
phase("IdP answers")
machine.succeed("systemctl restart homelab-converge.service")
machine.succeed("systemctl is-active --quiet homelab-converge.service")
phase("converge run 1")
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

phase("converge run 2 and idempotency checks")
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

phase("service tree and containers checked")
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

phase("pools and datasets checked")
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

phase("smoke HTTP: IdP, vault, git, immich, music, beszel")
# Actual Budget and Navidrome local surfaces (converge seeded the owner
# identities against the live services).
machine.succeed("curl -fsS http://127.0.0.1:5006/account/needs-bootstrap > /dev/null")
machine.succeed("curl -fsS http://127.0.0.1:4533/ > /dev/null")

phase("local surfaces")
print("vm-test: OK")
