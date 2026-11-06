# Mesh networking: SSH for remote deployments, NetBird client enrollment via
# setup key, and firewall rules for the ingress paths.
{
  config,
  ...
}:
{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  services.netbird = {
    enable = true;
    # Enroll the host into the mesh non-interactively using a setup key
    # decrypted from sops at boot; secrets are in place before any unit starts
    # (systemd activation), so no extra ordering dependency is needed.
    clients.default.login = {
      enable = true;
      setupKeyFile = config.sops.secrets."netbird_setup_key".path;
    };
  };

  networking.firewall = {
    trustedInterfaces = [ "wt0" ];
    allowedTCPPorts = [
      443 # Caddy: private services and edge-proxied TLS
      2284 # Caddy: public media sharing (L4 passthrough from the edge proxy)
      2222 # Forgejo built-in SSH server
    ];
  };
}
