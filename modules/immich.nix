# Immich runs as a Docker Compose stack on the host Docker daemon: the coupled
# ML runtimes and database extensions move too fast for native NixOS modules.
# The compose file is owned by this repository and re-installed onto the app
# dataset on every activation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  app = cfg.apps.immich;
  immichDir = "${cfg.storage.appdataPath}/immich";
in
{
  config = lib.mkMerge [
    {
      # The compose file publishes the port literally; keep both in sync.
      homelab.apps.immich = {
        enable = lib.mkDefault true;
        ingress = {
          subdomain = "immich";
          port = 2283;
        };
      };
    }
    (lib.mkIf app.enable {
      virtualisation.docker.enable = true;

      systemd.services.immich-stack = {
        description = "Immich docker compose stack";
        after = [
          "docker.service"
        ];
        requires = [
          "docker.service"
        ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = immichDir;
        path = with pkgs; [
          docker
          docker-compose
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = immichDir;
          TimeoutStartSec = "15min";
        };
        script = ''
          install -d -m 755 ${immichDir}
          install -m 644 ${./immich/compose.yml} ${immichDir}/docker-compose.yml
          install -m 600 ${config.sops.secrets."immich.env".path} ${immichDir}/.env
          docker-compose up -d
        '';
      };
    })
  ];
}
