# Demo instance host: a complete example configuration with placeholder
# values. The VM boot test boots it with fixture secrets; a real instance
# copies this directory, fills in its own values and adds its sops file.
{
  imports = [ ./disko.nix ];

  config = {
    homelab = {
      instance = {
        name = "Demo";
        hostDir = "host";
      };

      domain = "example.org";
      internalDomain = "hub.example.org";
      sharingDomain = "share.example.org";
      smtp = {
        host = "smtp.example.org";
        port = 587;
        alertSender = "notifications@example.org";
        user = "relay@example.org";
      };
      identity.enable = true;
      idp.issuer = "https://auth.hub.example.org";

      converge.enable = true;

      forgejo.runner = {
        enable = true;
        # Printed by `forgejo forgejo-cli actions register` on the host;
        # postinstall writes the real value.
        uuid = "00000000-0000-0000-0000-000000000000";
      };

      # Mount points must match ./disko.nix.
      storage = {
        appdataPath = "/mnt/fast-pool/appdata";
        bulkPath = "/mnt/tank";

        snapshots = {
          "tank/immich" = "production";
          "tank/media/home-videos" = "production";
          "tank/storage/users" = "production";

          "fast-pool/appdata/vaultwarden" = "critical_db";
          "fast-pool/appdata/actual-budget" = "critical_db";
          "fast-pool/appdata/forgejo" = "critical_db";
          "fast-pool/appdata/immich/postgres" = "critical_db";
          "fast-pool/appdata/authentik" = "critical_db";

          "fast-pool/appdata/navidrome" = "standard_app";
        };
      };
    };

    networking.hostName = "demo";
    # Stable per-host ZFS id; generate one per real host
    # (`head -c4 /dev/urandom | od -A none -t x4`).
    networking.hostId = "0d0d0d0d";

    time.timeZone = "UTC";

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    system.stateVersion = "26.05";
  };
}
