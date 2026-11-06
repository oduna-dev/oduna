# sops-nix wiring: secrets are encrypted with age keys (workstation + NAS host
# key) and decrypted at boot into /run/secrets. The encrypted document and the
# decryption key are parameters (`homelab.secrets.sopsFile`,
# `homelab.secrets.ageKeyFile`); the physical host derives its age key from
# the SSH host key, VM test environments point both at a fixture instead.
{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.secrets;
in
{
  sops = {
    defaultSopsFile = cfg.sopsFile;
    defaultSopsFormat = "yaml";
    age.sshKeyPaths = lib.optionals (cfg.ageKeyFile == null) [ "/etc/ssh/ssh_host_ed25519_key" ];
    age.keyFile = lib.mkIf (cfg.ageKeyFile != null) cfg.ageKeyFile;

    # Surface secrets through a sysinit-stage systemd unit: consumer restart
    # requests go through proper systemctl calls instead of activation-script
    # invocations.
    useSystemdActivation = true;

    secrets = {
      # restartUnits names the consumers of each secret: EnvironmentFile and
      # LoadCredential are read only at service start.
      # borg_passphrase is not listed: the backup job reads it per run and
      # msmtp's passwordeval reads smtp_password per send.
      "caddy_inwx.env" = {
        owner = "caddy";
        restartUnits = [ "caddy.service" ];
      };
      "smtp_password".restartUnits = [ "forgejo.service" ];
      "vaultwarden.env" = {
        owner = "vaultwarden";
        restartUnits = [ "vaultwarden.service" ];
      };
      # Shared break-glass admin identity: consumed directly by
      # homelab-converge (the script routes), so it re-runs on rotation.
      "admin.env".restartUnits = [ "homelab-converge.service" ];
      "forgejo_runner_token".restartUnits = [
        "gitea-runner-${config.networking.hostName}_runner.service"
      ];
      "netbird_setup_key".restartUnits = [
        "netbird.service"
        "netbird-login.service"
      ];
      "immich.env".restartUnits = [ "immich-stack.service" ];
      # Installed as the compose project's .env by the authentik-stack unit.
      "authentik.env".restartUnits = [ "authentik-stack.service" ];
      "borg_passphrase".owner = "root";
      # Healthchecks.io ping identifiers (spoofable URLs), kept as a tree in
      # secrets.yaml; the runtime files stay flat under /run/secrets. Consumers
      # cat the file at execution time, so no restartUnits: a changed URL is
      # picked up on the next timer fire or backup run.
      "healthchecks_heartbeat_uuid" = {
        key = "healthchecks/heartbeat";
        owner = "root";
      };
      "healthchecks_hotbackup_uuid" = {
        key = "healthchecks/hotbackup";
        owner = "root";
      };
      "healthchecks_borg_uuid" = {
        key = "healthchecks/borg";
        owner = "root";
      };
    };
  };
}
