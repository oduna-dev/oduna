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
  borgPing = pkgs.writeShellApplication {
    name = "borg-ping";
    runtimeInputs = [ pkgs.curl ];
    text = builtins.readFile ./backups/borg-ping.sh;
  };

  apps = lib.filterAttrs (_: app: app.enable) cfg.apps;
  backupRoot = "${cfg.storage.bulkPath}/backups";

  # Apps whose dumps exec into their compose stack's database container need
  # that stack up: a missing one would abort the whole nightly job.
  stackUnits = lib.mapAttrsToList (name: _: "${name}-stack.service") (
    lib.filterAttrs (_: app: lib.any (dump: dump.type == "postgres-container") app.backup.dumps) apps
  );

  # The dump manifest the script iterates over: one entry per dump of every
  # enabled app.
  manifest = pkgs.writeText "backup-manifest.json" (
    builtins.toJSON {
      retentionDays = 14;
      inherit backupRoot;
      appPaths = lib.mapAttrs (_: app: app.backup.paths) apps;
      instancePaths = cfg.backup.paths;
      # stackUnit: the compose stack unit of the app; the restore starts it to
      # reach the database container.
      dumps = lib.concatLists (
        lib.mapAttrsToList (
          app: entry:
          map (
            dump:
            {
              inherit app;
              stackUnit = "${app}-stack.service";
            }
            // dump
          ) entry.backup.dumps
        ) apps
      );
    }
  );

  restoreScript = pkgs.writeShellApplication {
    name = "homelab-restore";
    runtimeInputs = with pkgs; [
      coreutils
      docker
      findutils
      gnugrep
      gzip
      jq
      systemd
      util-linux
    ];
    runtimeEnv.BACKUP_MANIFEST = "${manifest}";
    text = builtins.readFile ./backups/restore.sh;
  };

  backupScript = pkgs.writeShellApplication {
    name = "backup-databases";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      docker
      findutils
      gzip
      jq
      sqlite
      systemd
      util-linux
      zfs
    ];
    text = builtins.readFile ./backups/backup-databases.sh;
  };
in
{
  environment.systemPackages = [ restoreScript ];

  services.borgbackup.jobs.storagebox = lib.mkIf (cfg.backup.storageBoxRepo != "") {
    paths = [
      backupRoot
    ]
    ++ lib.concatMap (app: app.backup.paths) (lib.attrValues apps)
    ++ cfg.backup.paths;
    exclude = lib.concatMap (app: app.backup.exclude) (lib.attrValues apps);
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
    postHook = lib.optionalString cfg.monitoring.healthchecks.enable "${lib.getExe borgPing} ${hcBorg} \"$EXIT_STATUS\"";
  };

  systemd.services.backup-databases = {
    description = "Nightly atomic database dumps";
    # The PostgreSQL dumps exec into the compose stacks' own database
    # containers: hold the run until those stacks are up, or the dump of one
    # app aborts the whole nightly job.
    after = [
      "docker.service"
      "zfs-mount.service"
    ]
    ++ stackUnits;
    requires = stackUnits;
    environment = {
      BACKUP_MANIFEST = "${manifest}";
      BACKUP_ROOT = backupRoot;
    }
    // lib.optionalAttrs cfg.monitoring.healthchecks.enable { HC_URL_FILE = hcHotBackup; };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backupScript;
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
