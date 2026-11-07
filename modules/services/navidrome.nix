{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab;
in
{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "127.0.0.1";
      Port = 4533;
      MusicFolder = "${cfg.storage.bulkPath}/media/music";
      DataFolder = "${cfg.storage.appdataPath}/navidrome";
      ScanSchedule = "@every 1h";
    }
    // lib.optionalAttrs (cfg.idp.issuer != "") {
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
}
