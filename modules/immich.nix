# Immich runs as a Docker Compose stack on the host Docker daemon: the coupled
# ML runtimes and database extensions move too fast for native NixOS modules.
# The compose file is owned by this repository and re-installed onto the app
# dataset on every activation (see modules/compose-stack).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  app = cfg.apps.immich;
  mkComposeStack = import ./compose-stack { inherit lib pkgs; };
in
{
  config = lib.mkMerge [
    {
      homelab.apps.immich = {
        enable = lib.mkDefault true;
        ingress = {
          subdomain = "immich";
          port = 2283;
        };
        backup = {
          dumps = [
            {
              file = "immich_db_{date}.sql.gz";
              type = "postgres-container";
              container = "immich_postgres";
              user = "postgres";
              restore.stopContainers = [ "immich_server" ];
            }
          ];
          paths = [ "${cfg.storage.bulkPath}/immich" ];
          exclude = map (dir: "${cfg.storage.bulkPath}/immich/${dir}") [
            "thumbs"
            "encoded-video"
            "backups"
          ];
        };
      };
    }
    (lib.mkIf app.enable {
      virtualisation.docker.enable = true;

      systemd.services = mkComposeStack {
        name = "immich";
        description = "Immich docker compose stack";
        dir = "${cfg.storage.appdataPath}/immich";
        composeFile = ./immich/compose.yml;
        secretsEnv = config.sops.secrets."immich.env".path;
        port = app.ingress.port;
      };
    })
  ];
}
