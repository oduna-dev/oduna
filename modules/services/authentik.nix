# Central identity provider (Authentik), run as a Docker Compose stack on the
# host Docker daemon (see modules/immich.nix for the pattern): HTTP server
# (`ak server`) + background worker (`ak worker`, migrations included) on
# loopback behind Caddy, and the proxy outpost for the forward-auth app
# (Navidrome). Authentik's own compose file is the supported deployment
# target; the module only installs the stack file and wires the secrets.
# No Redis is needed: the cache, channel layer and background tasks are
# PostgreSQL-based.
#
# The stack ships its own PostgreSQL instance on the appdata/authentik
# dataset. The sops authentik.env file carries every stack secret: the secret
# key, the break-glass bootstrap credentials, the relay password for the email
# stage and the database password. The proxy outpost reads its token from the
# converge-owned outpost.env sibling file (written by homelab-converge after
# provisioning; the stack stubs an empty one ahead of its first container
# start).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  enabled = cfg.idp.issuer != "";
  authentikDir = "${cfg.storage.appdataPath}/authentik";
in
{
  config = lib.mkIf enabled {
    virtualisation.docker.enable = true;

    # Dataset directories are provisioned before the stack unit: systemd
    # evaluates a unit's namespace before any ExecStartPre runs and the
    # datasets mount later than activation scripts could chown (see
    # modules/appdata-dirs.nix). UID 1000 is the authentik container user,
    # 70 the alpine postgres one. The outpost env file is stubbed here too:
    # compose refuses missing env_file paths, and homelab-converge supplies
    # the token content thereafter.
    systemd.services.authentik-dirs = {
      description = "Create authentik data directories on the app dataset";
      after = [ "zfs-mount.service" ];
      before = [ "authentik-stack.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # PostgreSQL data directory, chowned before the cluster initdb.
        install -d -o 70 -g 70 -m 700 ${authentikDir}/postgres
        # Media/user uploads (flow backgrounds and similar) and the data
        # directory (geoip updates), shared between server and worker.
        install -d -o 1000 -g 1000 -m 750 ${authentikDir}/media
        install -d -o 1000 -g 1000 -m 750 ${authentikDir}/data
        # Outpost env file: empty stub ahead of compose, filled by
        # homelab-converge with the provisioned AUTHENTIK_TOKEN.
        [ -f ${authentikDir}/outpost.env ] || : > ${authentikDir}/outpost.env
        chmod 600 ${authentikDir}/outpost.env
      '';
    };

    # Installs the stack on every activation; the outpost starts crashing
    # until homelab-converge has provisioned the application, written the
    # token into outpost.env and re-upped the container.
    systemd.services.authentik-stack = {
      description = "Authentik docker compose stack";
      after = [
        "docker.service"
        "authentik-dirs.service"
      ];
      requires = [
        "docker.service"
        "authentik-dirs.service"
      ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = authentikDir;
      path = with pkgs; [
        docker
        docker-compose
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = authentikDir;
        TimeoutStartSec = "15min";
      };
      script = ''
        install -d -m 755 ${authentikDir}
        install -m 644 ${./authentik/compose.yml} ${authentikDir}/docker-compose.yml
        install -m 600 ${config.sops.secrets."authentik.env".path} ${authentikDir}/.env
        # Schema-resolved plaintext entries ride behind the sops block.
        {
          printf 'AUTHENTIK_HOST=%s\n' ${lib.escapeShellArg cfg.idp.issuer}
          printf 'AUTHENTIK_EMAIL__HOST=%s\n' ${lib.escapeShellArg cfg.smtp.host}
          printf 'AUTHENTIK_EMAIL__PORT=%s\n' ${lib.escapeShellArg (toString cfg.smtp.port)}
          printf 'AUTHENTIK_EMAIL__USERNAME=%s\n' ${lib.escapeShellArg cfg.smtp.user}
          printf 'AUTHENTIK_EMAIL__USE_TLS=true\n'
          printf 'AUTHENTIK_EMAIL__FROM=%s\n' ${lib.escapeShellArg cfg.smtp.alertSender}
          # The outpost container mounts this hosts' CA bundle as its trust
          # store for the IdP vhost TLS (default: the system bundle, which
          # covers the public-TLS deployment; see the compose outpost
          # service).
          printf 'AUTHENTIK_OUTPOST_CA_BUNDLE=%s\n' ${lib.escapeShellArg (toString cfg.idp.caBundle)}
        } >> ${authentikDir}/.env
        docker-compose up -d
      '';
    };
  };
}
