# Drive script of the backup and restore test: boots the demo instance like
# ./vm-test.py, seeds known data through the apps' APIs, runs the nightly dump
# job and the Borg job against a local repository, wipes the data and brings it
# back with `homelab-restore --yes`. Split from the boot test because it takes
# its own minutes and only the backup and restore code can break it. The flake
# substitutes the @internalDomain@ placeholder from the evaluated host.

import atexit
import time

_t0 = time.monotonic()
_marks = []


def phase(name):
    _marks.append((name, time.monotonic() - _t0))


def _report():
    print("restore-test timing (seconds since the script started, +seconds per phase):")
    prev = 0.0
    for name, at in _marks:
        print(f"  {at:6.0f}  +{at - prev:5.0f}  {name}")
        prev = at


atexit.register(_report)

CA = "/run/homelab-vm-test/caddy-ca-bundle.crt"

start_all()
machine.wait_for_unit("multi-user.target")
phase("multi-user.target")
for unit in [
    "docker",
    "immich-stack",
    "authentik-stack",
    "caddy",
    "forgejo",
    "vaultwarden",
    "actual",
    "caddy-ca-trust",
]:
    machine.wait_for_unit(f"{unit}.service")
phase("units active")

# The drill seed logs in as the Immich admin that converge provisions. The
# boot-time converge run may lose the IdP's readiness race on a fresh IdP
# database; the unit is re-runnable, so the run this test relies on is a
# restart once the IdP answers.
machine.wait_until_succeeds(
    f"curl --cacert {CA} -fsS https://auth.@internalDomain@/-/health/live/ > /dev/null",
    timeout=900,
)
machine.succeed("systemctl restart homelab-converge.service")
machine.succeed("systemctl is-active --quiet homelab-converge.service")
phase("converge")

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

phase("seed data written")
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

phase("nightly dump job")
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

phase("dumps verified")
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

phase("borg job and archive check")
# Restore round trip through homelab-restore: lose the Immich database and
# library file, the local dumps, a Forgejo repository and the Vaultwarden and
# Actual databases. The tool fetches files and dumps from Borg and puts every
# dump back by its type.
machine.succeed(
    """db="$(docker exec immich_postgres printenv POSTGRES_DB)" && \
      docker stop immich_server && \
      docker exec immich_postgres psql -U postgres -d postgres \
        -c "DROP DATABASE \"$db\" WITH (FORCE)" && \
      find /mnt/tank/immich -type f -name '*.jpg' \
        ! -path '*/thumbs/*' ! -path '*/encoded-video/*' ! -path '*/backups/*' -delete && \
      rm -rf /mnt/tank/backups/*""",
    """e="$(sed -n 's/^ADMIN_EMAIL=//p' /run/secrets/admin.env)" && \
      pw="$(sed -n 's/^ADMIN_PASSWORD=//p' /run/secrets/admin.env)" && u="${e%%@*}" && \
      curl -fsS -X DELETE -u "$u:$pw" "http://127.0.0.1:3000/api/v1/repos/$u/drill-seed" """,
    "systemctl stop vaultwarden.service actual.service",
    "rm -f /mnt/fast-pool/appdata/vaultwarden/db.sqlite3* /mnt/fast-pool/appdata/actual-budget/server-files/account.sqlite*",
)
machine.fail("ls /mnt/tank/backups/immich/immich_db_*.sql.gz")
machine.fail(
    "MANIFEST='" + manifest + "' " + DRILL + "MODE=verify bash /etc/drill-data-remote.sh"
)

phase("data lost (wipe)")
# Without --yes the tool only prints its plan.
machine.succeed(
    "homelab-restore | grep -q 'plan only'",
    "! ls /mnt/tank/backups/immich/immich_db_*.sql.gz",
)
print(machine.succeed("homelab-restore --yes"))
phase("homelab-restore --yes")

machine.wait_until_succeeds(
    "MANIFEST='" + manifest + "' " + DRILL + "MODE=verify bash /etc/drill-data-remote.sh"
)
machine.succeed(
    "systemctl is-active forgejo.service vaultwarden.service actual.service",
    """for f in /mnt/fast-pool/appdata/vaultwarden/db.sqlite3 \
      /mnt/fast-pool/appdata/actual-budget/server-files/account.sqlite; do
      [ "$(sqlite3 "$f" 'PRAGMA integrity_check')" = ok ] || { echo "$f fails the integrity check"; exit 1; }
    done""",
    "[ \"$(stat -c %U /mnt/fast-pool/appdata/vaultwarden/db.sqlite3)\" = vaultwarden ]",
    "[ \"$(stat -c %U /mnt/fast-pool/appdata/actual-budget/server-files/account.sqlite)\" = actual ]",
)
phase("restored data verified")
# Authentik was restored in place: the server and worker are back and answer.
machine.wait_until_succeeds(
    f"curl --cacert {CA} -fsS https://auth.@internalDomain@/-/health/live/ > /dev/null"
)
machine.succeed(
    """for n in authentik_server authentik_worker; do
      docker ps --filter "name=$n" --filter status=running --format '{{.Names}}' | grep -qx "$n" || exit 1
    done"""
)

phase("authentik back")
print("restore-test: OK")
