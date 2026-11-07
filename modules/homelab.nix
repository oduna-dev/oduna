# Typed schema for global parameters. This file defines the *shape* only.
# Family environment values live in `envs/<env>/default.nix`; host configs
# (`envs/<env>/<host>/default.nix`) set host-specific values and override
# anything env-level through the same option paths. Services consume the
# values via `config.homelab`; nothing hardcodes domains, SMTP relay
# settings, or storage mount points.
{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab;

  # Fields each dump type needs.
  dumpFields = {
    sqlite = [
      "dataDir"
      "db"
    ];
    postgres-container = [
      "container"
      "user"
    ];
    command = [ "exec" ];
  };
  missingFields = dump: lib.filter (field: dump.${field} == null) dumpFields.${dump.type};
in
{
  options.homelab = {
    instance = {
      name = lib.mkOption {
        type = lib.types.str;
        description = ''
          Display name of the instance, used where services present
          themselves by name (e.g. mail sender names).
        '';
      };
      hostDir = lib.mkOption {
        type = lib.types.str;
        description = ''
          Directory of this host relative to the instance root. The
          provisioning scripts check its disko.nix and write host-specific
          values (Forgejo runner UUID, backup repository) into its
          default.nix.
        '';
      };
    };
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Authoritative apex domain";
    };
    internalDomain = lib.mkOption {
      type = lib.types.str;
      description = "Private mesh namespace resolved via NetBird custom DNS";
    };
    sharingDomain = lib.mkOption {
      type = lib.types.str;
      description = "Public link-sharing ingress hostname";
    };
    identity = {
      enable = lib.mkEnableOption ''
        The central identity provider (Authentik on this host): its stack, its
        Caddy vhost and forward-auth gate, and the SSO wiring of the consuming
        services. Requires `idp.issuer`
      '';
    };
    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "the ${name} app";
              ingress = {
                subdomain = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Host label under `internalDomain` the app is served on.
                  '';
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  description = ''
                    Loopback port the app listens on. The app module feeds
                    the same value to the service and to the generated vhost.
                  '';
                };
                forwardAuth = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Gate the vhost behind the identity provider's forward-auth
                    outpost when `identity.enable` is set; the identity
                    headers pass through to the app.
                  '';
                };
              };
              backup = {
                dumps = lib.mkOption {
                  type = lib.types.listOf (
                    lib.types.submodule {
                      options = {
                        file = lib.mkOption {
                          type = lib.types.str;
                          example = "app_{date}.sqlite3";
                          description = ''
                            Name of the dump file below the app's directory in
                            the local backup root; `{date}` is replaced by the
                            run date.
                          '';
                        };
                        type = lib.mkOption {
                          type = lib.types.enum [
                            "sqlite"
                            "postgres-container"
                            "command"
                          ];
                          description = ''
                            `sqlite`: consistent copy of a database read from
                            a ZFS snapshot of the dataset mounted at
                            `dataDir`. `postgres-container`: logical dump
                            through `docker exec` into `container`. `command`:
                            run the executable `exec`, which writes the dump
                            to the path in `$BACKUP_OUT`.
                          '';
                        };
                        dataDir = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "sqlite: mountpoint of the dataset holding the database.";
                        };
                        db = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "sqlite: database path relative to `dataDir`.";
                        };
                        container = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "postgres-container: name of the running container.";
                        };
                        user = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = ''
                            postgres-container: database role to connect as.
                            command: system user to run `exec` as (default
                            root).
                          '';
                        };
                        database = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = ''
                            postgres-container: database for a custom-format
                            `pg_dump`; null dumps the whole cluster with
                            `pg_dumpall`, gzip-compressed.
                          '';
                        };
                        exec = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "command: absolute path of the executable.";
                        };
                        stopUnits = lib.mkOption {
                          type = lib.types.listOf lib.types.str;
                          default = [ ];
                          description = ''
                            Systemd units stopped for the duration of this dump
                            and started again afterwards, also on failure.
                          '';
                        };
                      };
                    }
                  );
                  default = [ ];
                  description = "Nightly dumps of the app's databases into the local backup root.";
                };
                paths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Bulk data paths of the app that go into the offsite backup.";
                };
                exclude = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Paths below `paths` the offsite backup skips.";
                };
              };
            };
          }
        )
      );
      default = { };
      description = ''
        App registry. Every app module declares its entry here; the ingress
        and the other registry consumers are generated from the enabled
        entries. The shipped apps default to enabled.
      '';
    };
    idp = {
      issuer = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Issuer URL of the central identity provider (Authentik on this host),
          e.g. https://auth.<internal-domain>. Required when
          `identity.enable` is set.
        '';
      };
      insecureTls = lib.mkEnableOption ''
        Treat the IdP issuer vhost's TLS as not publicly trusted. The authentik
        outpost (and any other in-container consumer of the issuer URL) then
        verifies against the host CA bundle from `outpostCaBundle` instead of
        the distribution roots. Set in environments where the issuer vhost
        carries an internal, self-signed or private-CA certificate instead of
        a public one.
      '';
      caBundle = lib.mkOption {
        type = lib.types.path;
        default = "/etc/ssl/certs/ca-bundle.crt";
        description = ''
          Host CA bundle trusted by the consumers of the IdP issuer vhost TLS
          that do not share the system trust store: the authentik outpost
          container (its compose mount) and the Go CLI invocations of
          homelab-converge. The public-TLS deployment needs no override; a
          private-CA or test issuer sets `insecureTls` and points this at the
          bundle that contains the issuer CA.
        '';
      };
    };
    ingress = {
      tls = lib.mkOption {
        type = lib.types.enum [
          "inwx-dns01"
          "internal"
        ];
        default = "inwx-dns01";
        description = ''
          TLS issuance mode for Caddy's vhosts. `inwx-dns01` issues public
          certificates via the compiled-in INWX DNS-01 plugin; `internal` uses
          Caddy's built-in private CA and never contacts a registrar (VM test
          environments, staging machines without registrar credentials).
        '';
      };
    };
    secrets = {
      sopsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          sops-encrypted secrets document of the instance, decrypted at boot
          (single file with the per-key dotenv blocks; see the plaintext
          template secrets/secrets.example.yaml for the schema).
        '';
      };
      ageKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Age key file the sops file is machine-decrypted with. When null
          (physical hosts), the decryption key derives from the SSH host key
          (sops-nix age.sshKeyPaths). Set in environments where no host SSH
          key participates in the recipient list (VM test environments: a
          fixture age key generated outside the repository).
        '';
      };
    };
    converge = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run the host-side homelab-converge service (IdP provisioning, runtime
          SSO credentials, break-glass admin accounts) on every activation and
          whenever a consumed sops secret changes.
        '';
      };
    };
    forgejo = {
      runner = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the host runs a Forgejo Actions runner";
        };
        uuid = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Runner UUID printed once by `forgejo forgejo-cli actions register
            --secret <token>` on the Forgejo host; paired with the sops
            forgejo_runner_token credential.
          '';
        };
      };
    };
    smtp = {
      host = lib.mkOption {
        type = lib.types.str;
        description = "Outbound transactional SMTP relay host";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "SMTP STARTTLS submission port";
      };
      alertSender = lib.mkOption {
        type = lib.types.str;
        description = "From-address for all automated alerts";
      };
      user = lib.mkOption {
        type = lib.types.str;
        description = "Authenticated mailbox account for the outbound relay";
      };
    };
    storage = {
      appdataPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Base directory for service state (databases, app configs). Backed by
          fast storage on the host; must match the host's filesystem or disko
          mountpoints.
        '';
      };
      bulkPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Base directory for bulk data (media, documents, local backups). May
          share a pool with `appdataPath`; must match the host's filesystem or
          disko mountpoints.
        '';
      };
      snapshots = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.enum [
            "production"
            "critical_db"
            "standard_app"
          ]
        );
        default = { };
        example = {
          "tank/media" = "production";
        };
        description = ''
          Sanoid snapshot policy per ZFS dataset (full dataset name). The
          datasets and pools themselves are a property of the host's disk
          layout, so the host names them here.
        '';
      };
    };
    backup = {
      paths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/mnt/tank/storage/users" ];
        description = ''
          Instance data outside the apps (personal files, media collections)
          that goes into the offsite backup next to the apps' own paths.
        '';
      };
      storageBoxRepo = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          SSH URL of the append-only Borg repository on the Hetzner StorageBox.
          The Borg job is disabled until this is set.
        '';
      };
    };
    monitoring = {
      healthchecks = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Host reports to Healthchecks.io dead-man's switches. The check UUIDs
            (spoofable ping URLs) are sops secrets under the `healthchecks:`
            tree.
          '';
        };
      };
    };
  };

  config.assertions = [
    {
      assertion = !cfg.identity.enable || cfg.idp.issuer != "";
      message = "homelab.identity.enable requires homelab.idp.issuer.";
    }
    {
      assertion =
        !cfg.converge.enable
        || lib.all (app: cfg.apps.${app}.enable) [
          "vaultwarden"
          "forgejo"
          "navidrome"
          "actual-budget"
          "beszel"
          "immich"
        ];
      message = ''
        homelab.converge provisions every shipped app: disable it, or keep
        all of them enabled.
      '';
    }
  ]
  ++ lib.concatLists (
    lib.mapAttrsToList (
      name: app:
      lib.optionals app.enable (
        map (dump: {
          assertion = missingFields dump == [ ];
          message = "homelab.apps.${name}.backup.dumps: the ${dump.type} dump ${dump.file} needs ${lib.concatStringsSep ", " (missingFields dump)}.";
        }) app.backup.dumps
      )
    ) cfg.apps
  );
}
