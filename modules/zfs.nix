# ZFS plumbing: kernel-ZFS lock, ARC cap, encryption key loading, scrubs,
# snapshot policies (Sanoid) and ZFS Event Daemon alerting.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  pools = lib.attrNames config.disko.devices.zpool;
in
{
  # Explicit LTS kernel pin: ZFS support tracks specific mainline releases,
  # and pinning avoids surprises when nixpkgs moves its default kernel.
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.supportedFilesystems = [ "zfs" ];
  # Every pool the host's disko layout declares.
  boot.zfs.extraPools = pools;
  # Pools with encrypted datasets load their keys during import (stock
  # zfs module).
  # Force-importing pools containing mounted datasets risks data loss; imports
  # must be a deliberate action.
  boot.zfs.forceImportRoot = false;

  # Cap the ARC at 16 GiB so the cache cannot starve containers for memory.
  boot.kernelParams = [ "zfs.zfs_arc_max=17179869184" ];

  # Staggered to the 15th of the month to keep it away from backup windows.
  services.zfs.autoScrub = {
    enable = true;
    interval = "*-*-15 02:00:00";
    inherit pools;
  };

  services.zfs.zed.settings = {
    ZED_EMAIL_ADDR = [ cfg.smtp.alertSender ];
    ZED_NOTIFY_VERBOSE = false;
    ZED_EMAIL_PROG = "${pkgs.mailutils}/bin/mail";
  };

  services.sanoid = {
    enable = true;
    templates = {
      production = {
        hourly = 0;
        daily = 14;
        weekly = 8;
        monthly = 12;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
      critical_db = {
        hourly = 24;
        daily = 14;
        weekly = 4;
        monthly = 0;
        autosnap = true;
        autoprune = true;
      };
      standard_app = {
        hourly = 0;
        daily = 7;
        weekly = 4;
        monthly = 0;
        autosnap = true;
        autoprune = true;
      };
    };

    datasets = lib.mapAttrs (_: policy: { use_template = [ policy ]; }) cfg.storage.snapshots;
  };
}
