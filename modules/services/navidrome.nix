{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab;
  app = cfg.apps.navidrome;
in
{
  config = lib.mkMerge [
    {
      homelab.apps.navidrome = {
        enable = lib.mkDefault true;
        ingress = {
          subdomain = "music";
          port = 4533;
          forwardAuth = true;
        };
        backup.paths = [ "${cfg.storage.bulkPath}/media/music" ];
      };
    }
    (lib.mkIf app.enable {
      services.navidrome = {
        enable = true;
        settings = {
          Address = "127.0.0.1";
          Port = app.ingress.port;
          MusicFolder = "${cfg.storage.bulkPath}/media/music";
          DataFolder = "${cfg.storage.appdataPath}/navidrome";
          ScanSchedule = "@every 1h";
        }
        // lib.optionalAttrs cfg.identity.enable {
          # Externalized authentication through the authentik proxy outpost:
          # the Caddy forward_auth gate copies the authentik identity headers
          # through, and Navidrome auto-provisions the login as a local user
          # keyed on the email claim (the IdP is authoritative for identities).
          ExtAuth = {
            UserHeader = "X-Authentik-Email";
            TrustedSources = "127.0.0.1";
          };
        };
      };
    })
  ];
}
