{
  config,
  lib,
  ...
}:
let
  app = config.homelab.apps.beszel;
in
{
  config = lib.mkMerge [
    {
      homelab.apps.beszel = {
        enable = lib.mkDefault true;
        ingress = {
          subdomain = "beszel";
          port = 8090;
        };
      };
    }
    (lib.mkIf app.enable {
      services.beszel.hub = {
        enable = true;
        host = "127.0.0.1";
        port = app.ingress.port;
      }
      // lib.optionalAttrs config.homelab.identity.enable {
        # Family members sign in through the IdP; the pre-seeded break-glass
        # admin keeps its local login.
        environment = {
          USER_CREATION = "true";
        };
      };

      services.beszel.agent = {
        enable = true;
        environment = {
          PORT = "45876";
        };
        # The hub's public key (KEY) is runtime system state derived from the
        # hub's own identity database (not a repo secret), so the converge
        # service owns the agent env file and keeps it in sync (root-owned:
        # systemd parses the EnvironmentFile, not the transient-user agent).
        environmentFile = lib.mkIf config.homelab.converge.enable "${config.homelab.storage.appdataPath}/beszel-agent/agent.env";
      };

      # Keep the converge-managed env file stubbed off state before the first agent start.
      systemd.services.beszel-agent = lib.mkIf config.homelab.converge.enable {
        after = [ "homelab-converge-files.service" ];
      };

      # Container metrics for the Immich stack require read access to the Docker
      # socket.
      users.users.beszel-agent = lib.mkIf config.services.beszel.agent.enable {
        extraGroups = [ "docker" ];
      };
    })
  ];
}
