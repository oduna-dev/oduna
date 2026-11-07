# Central identity provider (Authentik), run as a Docker Compose stack on the
# host Docker daemon (see modules/compose-stack): HTTP server
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
  authentikDir = "${cfg.storage.appdataPath}/authentik";
  mkComposeStack = import ../compose-stack { inherit lib pkgs; };
  dirs = pkgs.writeShellApplication {
    name = "authentik-dirs";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./authentik/dirs.sh;
  };
in
{
  config = lib.mkMerge [
    {
      homelab.apps.authentik = {
        enable = cfg.identity.enable;
        ingress = {
          subdomain = "auth";
          port = 9000;
        };
      };
    }
    (lib.mkIf cfg.identity.enable {
      virtualisation.docker.enable = true;

      # Dataset directories are provisioned before the stack unit: systemd
      # evaluates a unit's namespace before any ExecStartPre runs and the
      # datasets mount later than activation scripts could chown (see
      # modules/appdata-dirs.nix). UID 1000 is the authentik container user,
      # 70 the alpine postgres one. The outpost env file is stubbed here too:
      # compose refuses missing env_file paths, and homelab-converge supplies
      # the token content thereafter.
      # Dataset directories are provisioned before the stack unit: systemd
      # evaluates a unit's namespace before any ExecStartPre runs and the
      # datasets mount later than activation scripts could chown (see
      # modules/appdata-dirs.nix). The outpost env file is stubbed there too:
      # compose refuses missing env_file paths, and homelab-converge supplies
      # the token content thereafter.
      systemd.services = {
        authentik-dirs = {
          description = "Create authentik data directories on the app dataset";
          after = [ "zfs-mount.service" ];
          before = [ "authentik-stack.service" ];
          environment.AUTHENTIK_DIR = authentikDir;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe dirs;
          };
        };
      }
      // mkComposeStack {
        name = "authentik";
        description = "Authentik docker compose stack";
        dir = authentikDir;
        composeFile = ./authentik/compose.yml;
        secretsEnv = config.sops.secrets."authentik.env".path;
        port = cfg.apps.authentik.ingress.port;
        after = [ "authentik-dirs.service" ];
        requires = [ "authentik-dirs.service" ];
        extraEnv = {
          AUTHENTIK_HOST = cfg.idp.issuer;
          AUTHENTIK_EMAIL__HOST = cfg.smtp.host;
          AUTHENTIK_EMAIL__PORT = toString cfg.smtp.port;
          AUTHENTIK_EMAIL__USERNAME = cfg.smtp.user;
          AUTHENTIK_EMAIL__USE_TLS = "true";
          AUTHENTIK_EMAIL__FROM = cfg.smtp.alertSender;
          # The outpost container mounts this host's CA bundle as its trust
          # store for the IdP vhost TLS (default: the system bundle, which
          # covers the public-TLS deployment; see the compose outpost
          # service).
          AUTHENTIK_OUTPOST_CA_BUNDLE = toString cfg.idp.caBundle;
        };
      };
    })
  ];
}
