# Example disk layout of the demo instance, provisioned by nixos-anywhere via
# disko:
# - boot SSD: 1 GiB FAT32 ESP + ext4 root (keeps OS recovery simple and the
#   Nix store isolated from bulk storage)
# - fast-pool: mirrored SSDs for application state
# - tank: RAIDZ2 on four bulk HDDs
#
# Dataset recordsize choices match the workload: 16k for SQLite/PostgreSQL
# page sizes, 64k for Forgejo, 1M for large media files.
let
  # Whole-disk ZFS pool member; the pool collects every disk that names it.
  zfsMember = device: pool: {
    type = "disk";
    inherit device;
    content = {
      type = "zfs";
      inherit pool;
    };
  };

  zfsFs = mountpoint: options: {
    type = "zfs_fs";
    inherit mountpoint;
    # Mount the fstab-generated .mount units only: zfs mount -a from
    # zfs-mount.service must skip these datasets (canmount=noauto still
    # allows explicit mounts), otherwise both mechanisms race over the
    # same datasets at boot and each loses with EBUSY.
    options = {
      canmount = "noauto";
    }
    // options;
  };

  # Physical `by-id` identities of the drives; replace every placeholder with
  # the target's `ls -l /dev/disk/by-id/` entries before provisioning (the
  # bootstrap refuses to run while a SERIAL placeholder is left).
  disks = {
    boot = "/dev/disk/by-id/ata-BOOT_SSD_SERIAL";
    "ssd-1" = "/dev/disk/by-id/ata-APP_SSD_1_SERIAL";
    "ssd-2" = "/dev/disk/by-id/ata-APP_SSD_2_SERIAL";
    "hdd-1" = "/dev/disk/by-id/ata-BULK_HDD_1_SERIAL";
    "hdd-2" = "/dev/disk/by-id/ata-BULK_HDD_2_SERIAL";
    "hdd-3" = "/dev/disk/by-id/ata-BULK_HDD_3_SERIAL";
    "hdd-4" = "/dev/disk/by-id/ata-BULK_HDD_4_SERIAL";
  };
in
{
  disko.devices = {
    disk = {
      boot-ssd = {
        type = "disk";
        device = disks.boot;
        content = {
          type = "gpt";
          partitions = {
            esp = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      ssd-1 = zfsMember disks."ssd-1" "fast-pool";
      ssd-2 = zfsMember disks."ssd-2" "fast-pool";

      hdd-1 = zfsMember disks."hdd-1" "tank";
      hdd-2 = zfsMember disks."hdd-2" "tank";
      hdd-3 = zfsMember disks."hdd-3" "tank";
      hdd-4 = zfsMember disks."hdd-4" "tank";
    };

    zpool = {
      "fast-pool" = {
        type = "zpool";
        mode = "mirror";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          acltype = "posix";
          xattr = "sa";
          dnodesize = "auto";
          normalization = "formD";
          compression = "zstd";
          encryption = "aes-256-gcm";
          keyformat = "raw";
          keylocation = "file:///etc/zfs/keys/fast-pool.key";
          mountpoint = "none";
        };
        datasets = {
          "appdata" = zfsFs "/mnt/fast-pool/appdata" { };
          "appdata/vaultwarden" = zfsFs "/mnt/fast-pool/appdata/vaultwarden" { recordsize = "16k"; };
          "appdata/actual-budget" = zfsFs "/mnt/fast-pool/appdata/actual-budget" { recordsize = "16k"; };
          "appdata/authentik" = zfsFs "/mnt/fast-pool/appdata/authentik" { recordsize = "16k"; };
          # Every parent of a nested dataset must be declared: ZFS creates an
          # undeclared parent with canmount=on, and zfs-mount.service then
          # mounts it over the child's mountpoint directory while systemd
          # mounts the child, which fails the boot into emergency mode.
          "appdata/immich" = zfsFs "/mnt/fast-pool/appdata/immich" { };
          "appdata/immich/postgres" = zfsFs "/mnt/fast-pool/appdata/immich/postgres" { recordsize = "16k"; };
          "appdata/forgejo" = zfsFs "/mnt/fast-pool/appdata/forgejo" { recordsize = "64k"; };
          "appdata/navidrome" = zfsFs "/mnt/fast-pool/appdata/navidrome" { recordsize = "128k"; };
        };
      };

      "tank" = {
        type = "zpool";
        mode = "raidz2";
        options = {
          ashift = "12";
          failmode = "wait";
          autotrim = "off";
        };
        rootFsOptions = {
          acltype = "posix";
          xattr = "sa";
          dnodesize = "auto";
          normalization = "formD";
          compression = "zstd";
          encryption = "aes-256-gcm";
          keyformat = "raw";
          keylocation = "file:///etc/zfs/keys/tank.key";
          mountpoint = "none";
        };
        datasets = {
          "immich" = zfsFs "/mnt/tank/immich" { recordsize = "512k"; };
          "media/home-videos" = zfsFs "/mnt/tank/media/home-videos" { recordsize = "1M"; };
          "media/movies" = zfsFs "/mnt/tank/media/movies" { recordsize = "1M"; };
          "media/music" = zfsFs "/mnt/tank/media/music" { recordsize = "256k"; };
          "storage/users" = zfsFs "/mnt/tank/storage/users" { recordsize = "128k"; };
          "backups" = zfsFs "/mnt/tank/backups" { recordsize = "128k"; };
          "staging" = zfsFs "/mnt/tank/staging" {
            recordsize = "128k";
            quota = "2T";
          };
        };
      };
    };
  };
}
