{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab;
  app = cfg.apps.actual-budget;
in
{
  config = lib.mkMerge [
    {
      homelab.apps.actual-budget = {
        enable = lib.mkDefault true;
        ingress = {
          subdomain = "budget";
          port = 5006;
        };
        backup = {
          dumps = [
            {
              file = "actual_account_{date}.sqlite3";
              type = "sqlite";
              dataDir = "${cfg.storage.appdataPath}/actual-budget";
              db = "server-files/account.sqlite";
              restore.stopUnits = [ "actual.service" ];
            }
          ];
          # The budget files themselves; the dump only lists them.
          paths = [ "${cfg.storage.appdataPath}/actual-budget/user-files" ];
        };
      };
    }
    (lib.mkIf app.enable {
      # Static identity (not the upstream DynamicUser default) so the appdata
      # dataset directories can be created and chowned to it ahead of the first
      # start by appdata-dirs.service.
      services.actual = {
        enable = true;
        user = "actual";
        group = "actual";
        settings = {
          port = app.ingress.port;
          hostname = "127.0.0.1";
          serverFiles = "${cfg.storage.appdataPath}/actual-budget/server-files";
          userFiles = "${cfg.storage.appdataPath}/actual-budget/user-files";
        };
      };

      users.users.actual = {
        isSystemUser = true;
        group = "actual";
      };
      users.groups.actual = { };
    })
  ];
}
