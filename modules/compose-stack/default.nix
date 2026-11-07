# Systemd unit for a Docker Compose stack on the host Docker daemon. The
# module owning the stack supplies its compose file and env files; the unit
# installs them into the stack's state directory and runs `docker-compose up`
# on every activation (see ./stack-up.sh).
#
# `extraEnv` carries the schema-resolved plaintext entries the stack needs on
# top of its sops-managed secrets. They land in a world-readable store file,
# so they must not hold secrets. Compose files read the published HTTP port
# from the ODUNA_HTTP_PORT entry this helper always adds.
{ lib, pkgs }:
{
  name,
  description,
  dir,
  composeFile,
  secretsEnv,
  port,
  extraEnv ? { },
  after ? [ ],
  requires ? [ ],
}:
let
  envFile = pkgs.writeText "${name}-extra.env" (
    lib.concatStrings (
      lib.mapAttrsToList (key: value: "${key}=${value}\n") (
        extraEnv // { ODUNA_HTTP_PORT = toString port; }
      )
    )
  );
  up = pkgs.writeShellApplication {
    name = "${name}-stack-up";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./stack-up.sh;
  };
in
{
  "${name}-stack" = {
    inherit description;
    after = [ "docker.service" ] ++ after;
    requires = [ "docker.service" ] ++ requires;
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = dir;
    # docker-compose stays on the unit PATH, not in the script's inputs, so
    # a wrapper placed ahead of it in `path` takes effect.
    path = with pkgs; [
      docker
      docker-compose
    ];
    environment = {
      STACK_DIR = dir;
      COMPOSE_FILE = toString composeFile;
      SECRETS_ENV = toString secretsEnv;
      EXTRA_ENV = toString envFile;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = dir;
      TimeoutStartSec = "15min";
      ExecStart = lib.getExe up;
    };
  };
}
