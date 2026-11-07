# Forgejo runs natively with server-side Git hooks disabled: push automation
# goes through Forgejo Actions, whose runner executes jobs inside ephemeral
# Docker containers instead of arbitrary shell on the host.
#
# forgejo-secrets.service generates the server-side secrets (custom/conf/*)
# on demand and is idempotent; if Forgejo fails setup with a missing
# credential file, restart that helper, then restart Forgejo.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  app = cfg.apps.forgejo;
in
{
  config = lib.mkMerge [
    {
      homelab.apps.forgejo = {
        enable = lib.mkDefault true;
        ingress = {
          subdomain = "git";
          port = 3000;
        };
      };
    }
    (lib.mkIf app.enable {
      services.forgejo = {
        enable = true;
        stateDir = "${cfg.storage.appdataPath}/forgejo";
        database.type = "sqlite3";
        settings = {
          server = {
            DOMAIN = "${app.ingress.subdomain}.${cfg.internalDomain}";
            ROOT_URL = "https://${app.ingress.subdomain}.${cfg.internalDomain}/";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = app.ingress.port;
            SSH_LISTEN_PORT = 2222;
            SSH_PORT = 2222;
            START_SSH_SERVER = true;
          };
          security = {
            # Block shell execution on the host OS from Git repositories.
            DISABLE_GIT_HOOKS = true;
          };
          actions = {
            ENABLED = true;
            DEFAULT_ACTIONS_URL = "github";
          };
          mailer = {
            ENABLED = true;
            SMTP_ADDR = cfg.smtp.host;
            SMTP_PORT = cfg.smtp.port;
            FROM = cfg.smtp.alertSender;
            USER = cfg.smtp.user;
          };
        };
        secrets.mailer.PASSWD = config.sops.secrets."smtp_password".path;
      };

      # The runner authenticates from `connections`: uuid from the host config
      # (`homelab.forgejo.runner.uuid`), token via LoadCredential. The instance
      # key is host-derived: unit = gitea-runner-<hostname>_runner.
      services.gitea-actions-runner = lib.mkIf cfg.forgejo.runner.enable {
        package = pkgs.forgejo-runner;
        instances."${config.networking.hostName}_runner" = {
          enable = true;
          # Satisfies the upstream module's token/tokenFile assertion only; the
          # token is consumed via LoadCredential below.
          tokenFile = config.sops.secrets."forgejo_runner_token".path;
          settings = {
            server.connections.forgejo = {
              url = "http://127.0.0.1:${toString app.ingress.port}";
              uuid = cfg.forgejo.runner.uuid;
              token_url = "file:$CREDENTIALS_DIRECTORY/forgejo-runner-token";
              labels = [
                "docker:docker://catthehacker/ubuntu:act-latest"
                "debian-latest:docker://debian:bullseye-slim"
              ];
            };
          };
        };
      };

      # The runner module names its service unit gitea-runner-*; the state
      # directory and working directory are named for Forgejo. The module's
      # register-side ExecStartPre is disabled: registration is config-driven.
      users.users.forgejo-runner = lib.mkIf cfg.forgejo.runner.enable {
        isSystemUser = true;
        group = "forgejo-runner";
      };
      users.groups.forgejo-runner = lib.mkIf cfg.forgejo.runner.enable { };
      systemd.services."gitea-runner-${config.networking.hostName}_runner" =
        lib.mkIf cfg.forgejo.runner.enable
          {
            serviceConfig = {
              ExecStartPre = lib.mkForce [ ];
              LoadCredential = "forgejo-runner-token:${config.sops.secrets."forgejo_runner_token".path}";
              DynamicUser = lib.mkForce false;
              User = lib.mkForce "forgejo-runner";
              Group = lib.mkForce "forgejo-runner";
              StateDirectory = lib.mkForce "forgejo-runner";
              WorkingDirectory = lib.mkForce "-/var/lib/forgejo-runner/${config.networking.hostName}_runner";
            };
            environment.HOME = lib.mkForce "/var/lib/forgejo-runner/${config.networking.hostName}_runner";
          };
    })
  ];
}
