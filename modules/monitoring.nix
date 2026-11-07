# Alerting pipeline: transactional mail relay (msmtp), predictive disk
# monitoring (smartd) and the external dead-man's-switch heartbeat.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  heartbeat = pkgs.writeShellApplication {
    name = "healthchecks-heartbeat";
    runtimeInputs = [ pkgs.curl ];
    text = builtins.readFile ./monitoring/heartbeat.sh;
  };
in
{
  # Host-wide sendmail interface used by smartd and ZED. Credentials come from
  # sops; the envelope sender must match a mailbox.org-owned address.
  programs.msmtp = {
    enable = true;
    setSendmail = true;
    defaults = {
      port = cfg.smtp.port;
      tls = "on";
      tls_starttls = "on";
    };
    accounts.default = {
      host = cfg.smtp.host;
      from = cfg.smtp.alertSender;
      user = cfg.smtp.user;
      auth = "on";
      passwordeval = "${pkgs.coreutils}/bin/cat ${config.sops.secrets."smtp_password".path}";
    };
  };

  services.smartd = {
    enable = true;
    notifications.mail = {
      enable = true;
      recipient = cfg.smtp.alertSender;
      sender = cfg.smtp.alertSender;
    };
    defaults.monitored = "-a -o on -S on -s (S/../../7/02|L/../../1/03) -W 4,45,55";
  };

  # External liveness: if this ping stops arriving (power loss, kernel panic,
  # ISP failure), Healthchecks.io alerts the alert mailbox.
  systemd.services.healthchecks-heartbeat = lib.mkIf cfg.monitoring.healthchecks.enable {
    description = "Healthchecks.io host liveness heartbeat ping";
    environment.HC_URL_FILE = config.sops.secrets."healthchecks_heartbeat_uuid".path;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe heartbeat;
    };
  };

  systemd.timers.healthchecks-heartbeat = lib.mkIf cfg.monitoring.healthchecks.enable {
    description = "Trigger the Healthchecks.io heartbeat every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
}
