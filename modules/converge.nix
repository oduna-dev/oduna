# Host-side convergence for runtime state the system config cannot own: the
# IdP-side provisioning, runtime SSO credentials and the break-glass admin
# accounts (see ./converge/converge.sh for the step set). This replaces the
# bootstrap pipeline's post-install IdP work: every step is idempotent against
# live services, so the unit converges from any previous state — fresh
# install, wiped app database, changed shared password — on every activation.
#
# Two units, because the consuming services are running before converge can
# probe them:
#   - homelab-converge-files: creates the stub env files (empty) that the
#     consuming units reference; there is no dash-prefixed
#     EnvironmentFile tolerance needed, the files always exist ahead of the
#     first start.
#   - homelab-converge: the actual convergence; after every consuming unit —
#     and re-runnable any time via systemctl.
#
# Re-runs are triggered by
#   - activation (multi-user.target), and
#   - sops restartUnits on the consumed secrets (e.g. a rotated shared admin
#     password in admin.env).
#
# Failure semantics: every step degrades to "that service keeps its own
# login path" (journal warning); the one unit-fatal case is an unhealthy IdP
# after a bounded wait, because the whole IdP-dependent block cannot run — a
# later unit start converges the rest.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;

  appdata = cfg.storage.appdataPath;
  forgejoStateDir = config.services.forgejo.stateDir;
  hubDataDir = config.services.beszel.hub.dataDir;
  actualServerFiles = "${appdata}/actual-budget/server-files";
  authentikDir = "${appdata}/authentik";
  vaultwardenData = "${appdata}/vaultwarden";

  vaultwardenConvergeEnv = "${vaultwardenData}/converge.env";
  outpostEnv = "${authentikDir}/outpost.env";

  navidromeConf =
    (pkgs.formats.json { }).generate "navidrome-converge.json"
      config.services.navidrome.settings;

  # `runuser` and `script` ship in util-linux's "bin" output; in the unit
  # path these must stay plain packages (a prebuilt makeBinPath string would
  # have an extra /bin appended by the unit renderer).
  path = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.diffutils
    pkgs.findutils
    pkgs.jq
    pkgs.sqlite
    pkgs.docker
    pkgs.docker-compose
    pkgs.curl
    pkgs.openssh
    pkgs.util-linux
  ];

  script = pkgs.writeShellScript "homelab-converge" (builtins.readFile ./converge/converge.sh);
in
{
  config = lib.mkIf cfg.converge.enable {
    # Stub creation ahead of the first consuming start: the consume modules
    # list these files as plain EnvironmentFile entries (systemd fails a
    # unit on a missing file), so the stubs must exist ahead of them.
    systemd.services.homelab-converge-files = {
      description = "Stub creation of the converge-managed env files";
      after = [
        "local-fs.target"
        "appdata-dirs.service"
      ];
      before = [
        "beszel-agent.service"
        "vaultwarden.service"
        "authentik-stack.service"
      ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ appdata ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Beszel agent env: root-owned stub (DynamicUser parses via pid1);
        # homelab-converge supplies KEY here.
        install -d -m 700 ${appdata}/beszel-agent
        [ -f ${appdata}/beszel-agent/agent.env ] || \
          : > ${appdata}/beszel-agent/agent.env
        # Vaultwarden converge env: staged admin hash + SSO_* entries.
        install -d -o vaultwarden -g vaultwarden -m 700 ${vaultwardenData}
        [ -f ${vaultwardenConvergeEnv} ] || : > ${vaultwardenConvergeEnv}
      '';
    };

    systemd.services.homelab-converge = {
      description = "Homelab convergence: IdP provisioning, runtime SSO credentials, break-glass admins";
      after = [
        "network-online.target"
        "homelab-converge-files.service"
        "beszel-hub.service"
        "beszel-agent.service"
        "forgejo.service"
        "navidrome.service"
        "actual.service"
        "vaultwarden.service"
        "immich-stack.service"
        "docker.service"
      ]
      ++ lib.optionals (cfg.idp.issuer != "") [
        "authentik-stack.service"
      ];
      requires = [ "homelab-converge-files.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ appdata ];
      inherit path;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = script;
        TimeoutStartSec = "10min";
      };
      environment = {
        # Shared break-glass identity and its file location.
        ADMIN_ENV_FILE = config.sops.secrets."admin.env".path;
        AUTHENTIK_ENV_FILE = config.sops.secrets."authentik.env".path;
        IDP_ISSUER = cfg.idp.issuer;
        INTERNAL_DOMAIN = cfg.internalDomain;

        VAULTWARDEN_DATA_DIR = vaultwardenData;
        VAULTWARDEN_CONVERGE_ENV = vaultwardenConvergeEnv;
        VAULTWARDEN_EXEC = lib.getExe config.services.vaultwarden.package;

        BESZEL_HUB_DATA_DIR = hubDataDir;
        # The beszel 0.18 hub binary is beszel-hub (the package has no
        # meta.mainProgram); getExe would resolve to a missing "beszel".
        BESZEL_HUB_EXEC = lib.getExe' config.services.beszel.hub.package "beszel-hub";
        BESZEL_AGENT_ENV_FILE = "${appdata}/beszel-agent/agent.env";

        FORGEJO_STATE_DIR = forgejoStateDir;
        FORGEJO_EXEC = lib.getExe config.services.forgejo.package;
        FORGEJO_PORT = toString config.services.forgejo.settings.server.HTTP_PORT;

        ACTUAL_PORT = toString config.services.actual.settings.port;
        ACTUAL_SERVER_FILES = actualServerFiles;
        ACTUAL_PACKAGE = "${config.services.actual.package}";
        NODE_BIN = "${pkgs.nodejs_24}/bin/node";
        SQLITE = "${pkgs.sqlite}/bin/sqlite3";

        NAVIDROME_PORT = toString config.services.navidrome.settings.Port;
        NAVIDROME_EXEC = lib.getExe config.services.navidrome.package;
        NAVIDROME_CONF = navidromeConf;

        AUTHENTIK_DIR = authentikDir;
        AUTHENTIK_OUTPOST_ENV = outpostEnv;
        # The forward-auth outpost (Navidrome) is named after the host.
        OUTPOST_NAME = "${config.networking.hostName}-navidrome";
        # The IdP vhost TLS is not part of the system store in the private-CA
        # deployments; the Go CLI consumers (forgejo admin subcommands verify
        # the auto-discovery document) read SSL_CERT_FILE.
        IDP_CA_BUNDLE = toString cfg.idp.caBundle;
      };
    };
  };
}
