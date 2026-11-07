{
  config,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  appdata = cfg.storage.appdataPath;
in
{
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
    before = [
      "vaultwarden.service"
      "actual.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = with pkgs; ''
      # Vaultwarden keeps its database and keys directly in the dataset root.
      ${coreutils}/bin/install -d -o vaultwarden -g vaultwarden -m 700 ${appdata}/vaultwarden
      # Actual Budget runs as the static system user "actual".
      ${coreutils}/bin/install -d -o actual -g actual -m 750 \
        ${appdata}/actual-budget/server-files
      ${coreutils}/bin/install -d -o actual -g actual -m 750 \
        ${appdata}/actual-budget/user-files
    '';
  };

  systemd.services.vaultwarden = {
    requires = [ "appdata-dirs.service" ];
    after = [ "appdata-dirs.service" ];
  };
  systemd.services.actual = {
    requires = [ "appdata-dirs.service" ];
    after = [ "appdata-dirs.service" ];
  };
}
