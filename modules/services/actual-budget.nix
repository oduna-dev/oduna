{
  config,
  ...
}:
let
  cfg = config.homelab;
in
{
  # Static identity (not the upstream DynamicUser default) so the appdata
  # dataset directories can be created and chowned to it ahead of the first
  # start by appdata-dirs.service.
  services.actual = {
    enable = true;
    user = "actual";
    group = "actual";
    settings = {
      port = 5006;
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
}
