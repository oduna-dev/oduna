# Backup pipeline: nightly atomic database dumps into tank/backups and the
# append-only Borg job to the Hetzner StorageBox, both verified through
# Healthchecks.io dead-man's-switch pings.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;

  # Dumps and Borg report to Healthchecks.io with ping URLs read from sops at
  # run time; the host gates them via homelab.monitoring.healthchecks.enable.
  hcHotBackup = config.sops.secrets."healthchecks_hotbackup_uuid".path;
  hcBorg = config.sops.secrets."healthchecks_borg_uuid".path;
  curlPing = "${pkgs.curl}/bin/curl -fsS -m 10 --retry 3";

  backupScript = pkgs.writeShellScript "backup-databases" ''
    set -euo pipefail

    backup_root="${cfg.storage.bulkPath}/backups"
    date="$(date +%F)"
    ${lib.optionalString cfg.monitoring.healthchecks.enable ''
      ${curlPing} "$(cat ${hcHotBackup})/start" || true
      trap '${curlPing} "$(cat ${hcHotBackup})/fail" || true' ERR
    ''}

    mkdir -p "$backup_root/vaultwarden" "$backup_root/actual-budget" "$backup_root/immich" "$backup_root/forgejo" "$backup_root/authentik"

    # Vaultwarden: consistent SQLite copy read from a dedicated ZFS snapshot.
    # A previous run that failed between snapshot and destroy leaves the
    # snapshot behind, so drop it before creating a fresh one.
    ${pkgs.zfs}/bin/zfs destroy fast-pool/appdata/vaultwarden@backup-snap 2>/dev/null || true
    ${pkgs.zfs}/bin/zfs snapshot fast-pool/appdata/vaultwarden@backup-snap
    ${pkgs.sqlite}/bin/sqlite3 \
      "file:${cfg.storage.appdataPath}/vaultwarden/.zfs/snapshot/backup-snap/db.sqlite3?mode=ro" \
      ".backup '$backup_root/vaultwarden/vaultwarden_$date.sqlite3'"
    ${pkgs.zfs}/bin/zfs destroy fast-pool/appdata/vaultwarden@backup-snap

    # Actual Budget: same snapshot-read pattern.
    ${pkgs.zfs}/bin/zfs destroy fast-pool/appdata/actual-budget@backup-snap 2>/dev/null || true
    ${pkgs.zfs}/bin/zfs snapshot fast-pool/appdata/actual-budget@backup-snap
    ${pkgs.sqlite}/bin/sqlite3 \
      "file:${cfg.storage.appdataPath}/actual-budget/.zfs/snapshot/backup-snap/server-files/account.sqlite?mode=ro" \
      ".backup '$backup_root/actual-budget/actual_account_$date.sqlite3'"
    ${pkgs.zfs}/bin/zfs destroy fast-pool/appdata/actual-budget@backup-snap

    # Immich PostgreSQL: logical dump from the running container.
    pg_container="$(${pkgs.docker}/bin/docker ps --filter name=postgres --format '{{.Names}}' | grep immich | head -n 1)"
    ${pkgs.docker}/bin/docker exec -i "$pg_container" pg_dumpall -c --if-exists -U postgres \
      | ${pkgs.gzip}/bin/gzip > "$backup_root/immich/immich_db_$date.sql.gz"

    # authentik PostgreSQL: logical dump of the dedicated role's database
    # from the stack's own PostgreSQL container.
    ${lib.optionalString (cfg.idp.issuer != "") ''
      ${pkgs.docker}/bin/docker exec authentik_postgres \
        pg_dump --format=custom -U authentik authentik \
        > "$backup_root/authentik/authentik_db_$date.dump"
    ''}

    # Forgejo: stop the service for a consistent repository dump. The EXIT
    # trap brings it back up even when the dump fails; the success path clears
    # it after the restart.
    ${pkgs.systemd}/bin/systemctl stop forgejo
    trap '${pkgs.systemd}/bin/systemctl start forgejo' EXIT
    ${pkgs.util-linux}/bin/runuser -u forgejo -- \
      env FORGEJO_WORK_DIR="${cfg.storage.appdataPath}/forgejo" \
      ${pkgs.forgejo}/bin/forgejo dump \
        -c "${cfg.storage.appdataPath}/forgejo/custom/conf/app.ini" \
        -f /tmp/forgejo-dump.zip
    ${pkgs.systemd}/bin/systemctl start forgejo
    trap - EXIT
    mv /tmp/forgejo-dump.zip "$backup_root/forgejo/forgejo_dump_$date.zip"

    # Retain 14 days locally; offsite retention is governed by Borg.
    find "$backup_root" -type f -mtime +14 -delete

    ${lib.optionalString cfg.monitoring.healthchecks.enable ''
      ${curlPing} "$(cat ${hcHotBackup})" || true
    ''}
  '';
in
{
  services.borgbackup.jobs.storagebox = lib.mkIf (cfg.backup.storageBoxRepo != "") {
    paths = [
      "${cfg.storage.bulkPath}/backups"
      "${cfg.storage.bulkPath}/storage/users"
      "${cfg.storage.bulkPath}/immich"
      "${cfg.storage.bulkPath}/media/music"
      "${cfg.storage.bulkPath}/media/home-videos"
    ];
    exclude = [
      "${cfg.storage.bulkPath}/immich/thumbs"
      "${cfg.storage.bulkPath}/immich/encoded-video"
      "${cfg.storage.bulkPath}/immich/backups"
    ];
    repo = cfg.backup.storageBoxRepo;
    encryption = {
      mode = "repokey-blake2";
      passCommand = "cat ${config.sops.secrets."borg_passphrase".path}";
    };
    environment = {
      BORG_RSH = "ssh -i /etc/ssh/borg_append_only_key -p 23";
    };
    compression = "zstd";
    startAt = "*-*-* 03:30:00";
    postHook = lib.optionalString cfg.monitoring.healthchecks.enable ''
      ${curlPing} "$(cat ${hcBorg})$([ "$EXIT_STATUS" -eq 0 ] || printf /fail)" \
        || true
    '';
  };

  systemd.services.backup-databases = {
    description = "Nightly atomic database dumps";
    # The PostgreSQL dumps exec into the compose stacks' own database
    # containers: hold the run until those stacks are up, or the dump of one
    # app aborts the whole nightly job.
    after = [
      "docker.service"
      "zfs-mount.service"
      "immich-stack.service"
    ]
    ++ lib.optionals (cfg.idp.issuer != "") [ "authentik-stack.service" ];
    requires = [
      "immich-stack.service"
    ]
    ++ lib.optionals (cfg.idp.issuer != "") [ "authentik-stack.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = backupScript;
    };
  };

  systemd.timers.backup-databases = {
    description = "Run the nightly database dumps at 02:30";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
    };
  };
}
