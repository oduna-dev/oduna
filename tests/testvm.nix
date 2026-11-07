# VM profile for the boot test: boots a host configuration (the demo
# instance's in this repository) under QEMU with every external boundary
# neutralized, so the *runtime* of the built system becomes assertable
# (dataset mounts, service ordering, converge) without a provisioning run and
# without touching physical hardware.
#
# What this profile flips vs. production (each keyed on the homelab.* schema):
#  - secrets: a fixture sops document derived from the plaintext template,
#    machine-decrypted with a throwaway age key generated outside the repo.
#    The fixture values exercise the same smoke paths (non-empty secret keys).
#  - externals: Borg/StorageBox, Healthchecks.io, NetBird and the INWX DNS-01
#    ACME are disabled; Caddy serves its internal CA instead.
#  - storage: `disko`'s dataset declarations are reused verbatim for the guest
#    fileSystems (the physically backed root/ESP entries are dropped), while a
#    guest unit stages the loopback pools — same pool modes, root fs options,
#    keylocations and dataset properties — and then *lets the stock
#    zfs-import units* import, unlock them and the .mount units mount them;
#    no disko run, no production disk code path.
#  - images: the compose stacks' images are pulled by the Nix build (fixed-
#    output derivations, the only place network is allowed) into the store and
#    loaded into the guest docker ahead of each stack start — the guest needs
#    no registry access during the run, because Nix builds run without it.
#
# The IdP stays enabled: converge's bounded-wait + provisioning against the
# live stack is the core runtime assertion of the test.
{
  options,
  config,
  lib,
  pkgs,
  ...
}:
let
  fixture = import ./secrets-fixture.nix {
    inherit pkgs;
    secretsExample = ../secrets/secrets.example.yaml;
  };

  # Caddy's internal CA root (data dir lives under its service state); the
  # converge runs and the test smoke curls need it to accept the internal
  # TLS of the private vhosts.
  caddyPkiRoot = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt";
  caddyCaBundle = "/run/homelab-vm-test/caddy-ca-bundle.crt";

  # The compose stacks' images, pinned exactly like their compose files and
  # pulled into the Nix store as loadable OCI tarballs.
  pullImage =
    {
      repository,
      tag,
      imageDigest,
      sha256,
    }:
    pkgs.dockerTools.pullImage {
      inherit sha256 imageDigest;
      imageName = repository;
      finalImageName = repository;
      finalImageTag = tag;
    };

  composeNoDigest = pkgs.writeShellApplication {
    name = "docker-compose";
    runtimeInputs = [ pkgs.gnused ];
    runtimeEnv.REAL_DOCKER_COMPOSE = lib.getExe pkgs.docker-compose;
    text = builtins.readFile ./compose-no-digest.sh;
  };

  caddyCaTrust = pkgs.writeShellApplication {
    name = "caddy-ca-trust";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./caddy-ca-trust.sh;
  };

  loadImages = pkgs.writeShellApplication {
    name = "load-images";
    text = builtins.readFile ./load-images.sh;
  };

  imageTarballs = {
    authentik = [
      (pullImage {
        repository = "ghcr.io/goauthentik/server";
        tag = "2026.8.5";
        imageDigest = "sha256:602227a86455d6772e3d16b7d852713c4f864f40df5df894abd1285bb53979a5";
        sha256 = "sha256-GoBImCTaa8tmuKh6LPdxn1tSyVDH6ks0dosfEw3tURk=";
      })
      (pullImage {
        repository = "ghcr.io/goauthentik/proxy";
        tag = "2026.8.5";
        imageDigest = "sha256:34640cf41e009ab052d4b9119cea816713adcd1eaac95de6caefebfe86d3fcd9";
        sha256 = "sha256-AGcWiBvs3RHWWSs1sQtLnfJzffmB8TLTzav4+5DRfVM=";
      })
      (pullImage {
        repository = "docker.io/library/postgres";
        tag = "16-alpine";
        imageDigest = "sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab";
        sha256 = "sha256-y8cigyThllJT431NgSPnL/Wx97mB3ZEQCw+c2CSk4uY=";
      })
    ];
    immich = [
      (pullImage {
        repository = "ghcr.io/immich-app/immich-server";
        tag = "v3.3.3";
        imageDigest = "sha256:bae7664ff3aa4c2c1fcbdcdd86b40b105643c5f861f3e6a770fc760089f25862";
        sha256 = "sha256-tFFSRi5Z1lEtVBCJyd5zuRPLU4dFK2r7I0EpfD8aPgQ=";
      })
      (pullImage {
        repository = "ghcr.io/immich-app/immich-machine-learning";
        tag = "v3.3.3";
        imageDigest = "sha256:73915f07e1f4289ba45b174c58443db74cef47ddf502613f475fc5e52458ea42";
        sha256 = "sha256-oZnWGEZPVgDTeBIrKrdiBrYcW8jxbGyVjUKhL7LlLIc=";
      })
      (pullImage {
        repository = "docker.io/valkey/valkey";
        tag = "9";
        imageDigest = "sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d";
        sha256 = "sha256-DYeUdZ9B5heZ6qN3VwOp0NGc8rC4RubIiMb72nyW7oY=";
      })
      (pullImage {
        repository = "ghcr.io/immich-app/postgres";
        tag = "14-vectorchord0.4.3-pgvectors0.2.0";
        imageDigest = "sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23";
        sha256 = "sha256-YNxadMZRLd2Wky6UvZFTcJ+KXFxg51E4zPdEAG7HtPk=";
      })
    ];
  };

  diskoDevices = config.disko.devices;

  # Pool staging driver, generated from the evaluated disko config — the same
  # source the production create script is generated from — so the guest pool
  # layout cannot drift from the declared one.
  poolScript =
    name: poolCfg:
    let
      memberCount = lib.length (
        lib.filter (disk: (disk.content.type or "") == "zfs" && (disk.content.pool or "") == name) (
          lib.attrValues diskoDevices.disk
        )
      );
      # disko passes the mode keyword (`mirror`, `raidz2`, ...) ahead of the
      # members; the empty mode is a plain stripe.
      vdevArg = poolCfg.mode;
      # Pool properties (`-o`) and root filesystem properties (`-O`).
      poolFlags = lib.concatStringsSep " " (
        lib.mapAttrsToList (opt: val: "-o ${lib.escapeShellArg "${opt}=${val}"}") poolCfg.options
        ++ lib.mapAttrsToList (opt: val: "-O ${lib.escapeShellArg "${opt}=${val}"}") poolCfg.rootFsOptions
      );
      datasetLines = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          ds: dsCfg:
          lib.optionalString (dsCfg.type or "" == "zfs_fs" && dsCfg.mountpoint != null) ''
            zfs create -u -p ${
              lib.concatStringsSep " " (
                lib.mapAttrsToList (opt: val: "-o ${lib.escapeShellArg "${opt}=${val}"}") (
                  {
                    canmount = "noauto";
                    mountpoint = dsCfg.mountpoint;
                  }
                  // dsCfg.options
                )
              )
            } ${lib.escapeShellArg "${name}/${ds}"}
          ''
        ) poolCfg.datasets
      );
    in
    ''
      if zpool list "${name}" >/dev/null 2>&1; then
        echo "homelab-vm-test: pool ${name} already staged"
      else
        # One sparse loopback image per pool member; only ZFS metadata and
        # test traffic take real space on the guest root disk.
        truncate -s 2G ${
          lib.concatStringsSep " " (lib.genList (i: ''"$stageDir/${name}-${toString i}.img"'') memberCount)
        }

        declare -a loops=()
        i=0
        for img in "$stageDir"/${name}-*.img; do
          dev="$(losetup --find --show "$img")"
          loops+=("$dev")
          # The stock import units scan /dev/disk/by-id (the devNodes
          # default): the symlinks let it treat the loopback members like
          # physical disks.
          ln -sfT "$dev" "/dev/disk/by-id/homelab-vm-test-${name}-$i"
          i=$((i + 1))
        done

        zpool create ${poolFlags} \
          ${lib.escapeShellArg name} ${vdevArg} "''${loops[@]}"
        ${datasetLines}
        # Export here: the stock import unit then performs the actual import
        # and key load — the same code path a production boot exercises.
        zpool export "${name}"
        echo "homelab-vm-test: staged pool ${name} (${toString memberCount} members)"
      fi
    '';

  zfsSetupScript = ''
    set -euo pipefail

    # Loop device support; losetup below needs the device nodes.
    modprobe loop

    stageDir=/var/lib/homelab-vm-test-pools
    install -d -m 700 "$stageDir" /etc/zfs/keys

    for pool in ${lib.escapeShellArgs (lib.attrNames diskoDevices.zpool)}; do
      # Raw 32-byte keys at the file: keylocation the pools were declared
      # with (bootstrap generates the production keys the same way).
      key="/etc/zfs/keys/$pool.key"
      [ -f "$key" ] || dd if=/dev/urandom of="$key" bs=32 count=1
      chmod 400 "$key"
    done
  ''
  + lib.concatStringsSep "\n" (lib.mapAttrsToList poolScript diskoDevices.zpool);

  # Guest fileSystems mirror disko's declared datasets (the same entries
  # disko itself generates); the physically backed root/ESP entries of the
  # real host are dropped — the test framework provides its own root disk.
  vmFileSystems = lib.concatMapAttrs (
    pool: poolCfg:
    lib.concatMapAttrs (
      ds: dsCfg:
      lib.optionalAttrs (dsCfg.type or "" == "zfs_fs" && dsCfg.mountpoint != null) {
        ${dsCfg.mountpoint} = {
          device = "${pool}/${ds}";
          fsType = "zfs";
          options = dsCfg.mountOptions ++ lib.optional (dsCfg.options.mountpoint or "" != "legacy") "zfsutil";
        };
      }
    ) poolCfg.datasets
  ) diskoDevices.zpool;

  importUnits = lib.map (pool: "zfs-import-${pool}.service") (lib.attrNames diskoDevices.zpool);
in
{
  # The fixture is materialized at activation time — before any service runs
  # — because the sops module refuses store-path strings for both the
  # document and the decryption key.
  system.activationScripts.homelab-vm-test-secrets = lib.stringAfter [ "etc" "users" "groups" ] ''
    install -d -m 700 /etc/homelab-vm-test
    install -m 400 "${fixture}/age.key" /etc/homelab-vm-test/age.key
    install -m 400 "${fixture}/secrets.yaml" /etc/homelab-vm-test/secrets.yaml
  '';

  # Fixture secrets instead of the physical host's sops recipient set; the
  # evaluation-time store guard is off because the fixture lives in /etc.
  homelab.secrets.sopsFile = "/etc/homelab-vm-test/secrets.yaml";
  homelab.secrets.ageKeyFile = "/etc/homelab-vm-test/age.key";
  sops.validateSopsFiles = lib.mkDefault false;

  homelab = {
    # No registrar credentials and no reachable registrar in the guest.
    ingress.tls = "internal";
    # The issuer vhost certificate is Caddy's internal CA; the host-network
    # outpost trusts it via the bundle the caddy-ca-trust unit exports.
    idp.insecureTls = true;
    idp.caBundle = caddyCaBundle;
    # Externals the guest must not reach.
    # The production Borg job runs against a local repository instead of the
    # StorageBox; the job initialises it on first use.
    backup.storageBoxRepo = lib.mkOverride 90 "/var/lib/borg-test-repo";
    monitoring.healthchecks.enable = lib.mkOverride 90 false;
    # The Actions runner is not part of the asserted surface, and the fixture
    # runner token does not satisfy the runner's connection validation.
    forgejo.runner.enable = lib.mkOverride 90 false;
  };

  # No mesh in the guest: the netbird module reads the clients table for its
  # firewall wiring regardless of `enable`, so it is emptied with it.
  services.netbird.enable = lib.mkOverride 90 false;
  services.netbird.clients = lib.mkOverride 90 { };

  # Clamp the ZFS ARC for the guest: the production cap (modules/zfs.nix) is
  # 16 GiB, far more RAM than the guest has. The kernel keeps the last
  # occurrence of a duplicate kernel parameter, so our value must come after.
  boot.kernelParams = lib.mkAfter [ "zfs.zfs_arc_max=268435456" ];

  # DHCP from slirp configures the default (not statically declared) NIC and
  # hands out the guest DNS so host- and container-side lookups work; the
  # private vhost names resolve through /etc/hosts.
  networking.extraHosts = with config.homelab; ''
    127.0.0.1 ${internalDomain} auth.${internalDomain} budget.${internalDomain} git.${internalDomain} immich.${internalDomain} music.${internalDomain} beszel.${internalDomain} vault.${internalDomain}
  '';

  # Hosted runners offer 4 vCPU / 16 GiB beside the build; local runs benefit
  # from more cores directly. The dataset mounts ride virtualisation here,
  # because QEMU overrides the fileSystems option with the machine's
  # synthetic root/store entries (see below for the non-QEMU path).
  virtualisation = lib.optionalAttrs (options ? virtualisation.cores) {
    memorySize = 8192;
    # Room for the compose stacks' images and runtime state under /var.
    diskSize = 12288;
    cores = 4;
    fileSystems = vmFileSystems;
  };

  # The guest runs no disko-generated root/ESP mounts: the VM profile derives
  # its own fileSystems from the same dataset definitions instead (disko's
  # physical root entries would point at devices the guest lacks).
  disko.enableConfig = false;

  fileSystems = lib.optionalAttrs (!(options ? virtualisation.cores)) vmFileSystems;

  # The convergence-provisioned agent key arrives only after the IdP fleet
  # is up; with a failing (empty env) agent looping pre-converge, systemd
  # holds the multi-user transaction. Degrade to a single failure that
  # converge flips into a working unit on its first run (it restarts the
  # agent when it syncs the hub key).
  systemd.services.beszel-agent.serviceConfig.Restart = lib.mkOverride 90 "no";

  # Pools are staged before the stock zfs-import services run, so
  # import + key loading + fstab mounting follow the production code path.
  systemd.services.test-zfs-setup = {
    description = "Stage the loopback ZFS pools for the VM test";
    unitConfig.DefaultDependencies = false;
    requiredBy = importUnits;
    before = importUnits;
    after = [ "systemd-modules-load.service" ];
    path = with pkgs; [
      kmod
      util-linux
      zfs
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = zfsSetupScript;
  };

  # Tools the test script uses to check that the dumps are restorable and to
  # run the host half of the restore drill's seed script.
  environment.systemPackages = [
    pkgs.sqlite
    pkgs.unzip
    pkgs.jq
    pkgs.curl
    pkgs.borgbackup
  ];
  environment.etc."drill-data-remote.sh".source = ../scripts/lib/drill-data-remote.sh;

  # Make Caddy's private CA visible to the converge runs (merged with the
  # system bundle; curl reads CURL_CA_BUNDLE from its environment).
  systemd.services.caddy-ca-trust = {
    description = "Export Caddy's internal CA root for the test clients";
    after = [ "caddy.service" ];
    requires = [ "caddy.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      CADDY_PKI_ROOT = caddyPkiRoot;
      CADDY_CA_BUNDLE = caddyCaBundle;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe caddyCaTrust;
    };
  };

  systemd.services.homelab-converge = {
    after = [ "caddy-ca-trust.service" ];
    environment.CURL_CA_BUNDLE = caddyCaBundle;
  };

  # The compose stacks' images ship inside the closure: load them ahead of
  # each stack start (the tarballs already sit in the guest store, so
  # `docker compose up` finds every pinned image locally and pulls nothing).
  # The authentik stack also waits for the exported CA bundle: the outpost
  # container binds it as its trust store ahead of the first compose up.
  #
  # The compose files pin `tag@sha256:…`, but a docker-archive load carries no
  # registry digest, so the daemon cannot resolve that reference locally and
  # tries to pull. This wrapper (ahead of the real binary in the stack units'
  # PATH) drops the digest pins from the staged compose file; the loaded tags
  # then match.
  systemd.services.immich-stack = {
    path = lib.mkBefore [ composeNoDigest ];
    preStart = "${lib.getExe loadImages} ${lib.concatStringsSep " " (map toString imageTarballs.immich)}";
  };
  systemd.services.authentik-stack = {
    path = lib.mkBefore [ composeNoDigest ];
    preStart = "${lib.getExe loadImages} ${lib.concatStringsSep " " (map toString imageTarballs.authentik)}";
    after = [ "caddy-ca-trust.service" ];
    requires = [ "caddy-ca-trust.service" ];
  };
}
