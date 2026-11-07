# Declarative Caddy ingress. The default (`dns-inwx`) compiles the INWX DNS-01
# plugin into the Caddy package so Let's Encrypt certificates for the private
# wildcard hostname and the public sharing hostname never expose service names
# in Certificate Transparency logs; the `internal` mode keeps Caddy stock and
# serves its own private CA certificates instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
  tlsBlock =
    if cfg.ingress.tls == "inwx-dns01" then
      ''
        tls {
          dns inwx {
            username {env.INWX_USERNAME}
            password {env.INWX_PASSWORD}
          }
        }
      ''
    else
      ''
        tls internal
      '';
in
{
  services.caddy = {
    enable = true;
    # The INWX plugin is only needed while the TLS mode issues public
    # certificates through it.
    package = lib.mkIf (cfg.ingress.tls == "inwx-dns01") (
      pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/inwx@v0.4.1" ];
        hash = "sha256-fPmaHMR9aN1mz4FKRMObLns7Ysg5Okd2ngs4s2iLyTM=";
      }
    );
    environmentFile = config.sops.secrets."caddy_inwx.env".path;

    globalConfig = ''
      email ${cfg.smtp.alertSender}
    '';

    extraConfig = ''
      # Private services: wildcard certificate over INWX DNS-01, resolved
      # exclusively inside the NetBird mesh.
      *.${cfg.internalDomain} {
        ${tlsBlock}

        @vault  host vault.${cfg.internalDomain}
        @immich host immich.${cfg.internalDomain}
        @budget host budget.${cfg.internalDomain}
        @git    host git.${cfg.internalDomain}
        @music  host music.${cfg.internalDomain}
        @beszel host beszel.${cfg.internalDomain}
        @auth   host auth.${cfg.internalDomain}

        handle @vault  { reverse_proxy 127.0.0.1:8080 }
        handle @immich { reverse_proxy 127.0.0.1:2283 }
        handle @budget { reverse_proxy 127.0.0.1:5006 }
        handle @git    { reverse_proxy 127.0.0.1:3000 }
        ${lib.optionalString (cfg.idp.issuer != "") ''
          handle @music {
            # Navidrome has no OIDC support: gate it behind the authentik
            # proxy outpost; the identity headers pass through unchanged and
            # Navidrome is configured to read the authentik header names.
            # The outpost-side flow paths (start/callback/ping) must reach the
            # outpost itself, hence the dedicated reverse_proxy inside the
            # ordered route (official authentik Caddy snippet).
            route {
              reverse_proxy /outpost.goauthentik.io/* 127.0.0.1:9001

              forward_auth 127.0.0.1:9001 {
                uri /outpost.goauthentik.io/auth/caddy
                copy_headers {
                  X-Authentik-Username
                  X-Authentik-Groups
                  X-Authentik-Email
                  X-Authentik-Name
                  X-Authentik-Uid
                }
              }

              reverse_proxy 127.0.0.1:4533
            }
          }
          handle @auth { reverse_proxy 127.0.0.1:9000 }
        ''}
        ${lib.optionalString (cfg.idp.issuer == "") ''
          handle @music { reverse_proxy 127.0.0.1:4533 }
        ''}
        handle @beszel { reverse_proxy 127.0.0.1:8090 }

        handle { respond "Not Found" 404 }
      }

      # Hardened public sharing: only the paths required for shared links are
      # reachable, everything else is denied before it touches Immich.
      ${cfg.sharingDomain}:2284 {
        ${tlsBlock}

        @allowed {
          path /_app/*
          path /api/server/version
          path /api/server/features
          path /api/server/config
          path /api/server/about
          path /api/shared-links/*
          path /api/assets/*
          path /api/download/*
          path /share/*
          path /favicon*
          path /manifest.json
        }

        handle @allowed {
          reverse_proxy 127.0.0.1:2283
        }

        handle {
          respond "Access Denied" 403
        }
      }
    '';
  };
}
