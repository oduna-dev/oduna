{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  appdata = cfg.storage.appdataPath;
  vaultwarden = cfg.apps.vaultwarden.enable;
  actual = cfg.apps.actual-budget.enable;
  enabledApps = lib.optional vaultwarden "vaultwarden" ++ lib.optional actual "actual-budget";
  script = pkgs.writeShellApplication {
    name = "appdata-dirs";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./appdata-dirs/appdata-dirs.sh;
  };
in
{
  config = lib.mkIf (vaultwarden || actual) {
    # Per-service data directories on the shared datasets: systemd evaluates a
    # unit's namespace (BindPaths, LoadCredential, ReadWritePaths) before any
    # ExecStartPre can run, and the datasets mount later than packaged tmpfiles
    # rules could write to them — so the directories must be created between the
    # ZFS mount and the first service start.
    # Started only through the consumers below (requires/after
    # appdata-dirs.service); no wantedBy on zfs-mount.service.
    systemd.services.appdata-dirs = {
      description = "Create per-service data directories on the app datasets";
      after = [ "zfs-mount.service" ];
      before = lib.optional vaultwarden "vaultwarden.service" ++ lib.optional actual "actual.service";
      environment.APPDATA = appdata;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe script} ${lib.concatStringsSep " " enabledApps}";
      };
    };

    systemd.services.vaultwarden = lib.mkIf vaultwarden {
      requires = [ "appdata-dirs.service" ];
      after = [ "appdata-dirs.service" ];
    };
    systemd.services.actual = lib.mkIf actual {
      requires = [ "appdata-dirs.service" ];
      after = [ "appdata-dirs.service" ];
    };
  };
}
