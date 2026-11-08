# Oduna

**Your server, in Git.** Oduna is a NixOS flake for a self-hosted home and dev
server: ZFS storage, single sign-on and a curated set of apps, declared in one
repository and rebuildable on any hardware from Git plus a data backup.

> **Status:** early. The modules run a real family deployment, which is Oduna's
> first instance. The product is being refactored towards a reusable app
> contract; expect breaking changes. Direction and roadmap:
> [docs/vision.md](docs/vision.md).

## What it runs

| Area     | Components                                                               |
| -------- | ------------------------------------------------------------------------ |
| Platform | NixOS, ZFS (encrypted pools, Sanoid snapshots, scrubs), sops-nix secrets |
| Identity | Authentik (OIDC everywhere, forward-auth for apps without OIDC)          |
| Ingress  | Caddy with DNS-01 certificates, mesh-only private vhosts (NetBird)       |
| Backups  | Nightly database dumps, append-only offsite Borg                         |
| Apps     | Vaultwarden, Forgejo + Actions runner, Immich, Actual Budget, Navidrome  |
| Ops      | Beszel monitoring, Healthchecks.io dead-man's switch, ZED/smartd alerts  |

Every app keeps a break-glass local admin next to SSO. App-internal state the
Nix configuration cannot own (IdP providers, SSO credentials, admin accounts) is
converged idempotently on every activation by `homelab-converge`.

## Layout

- `flake.nix` — `nixosModules.default`, the provisioning apps, lint/format, and
  the VM boot test
- `modules/` — one module per concern; `modules/homelab.nix` is the typed
  `homelab.*` schema every instance fills in
- `scripts/` — provisioning pipeline run from an instance directory
- `secrets/secrets.example.yaml` — plaintext template of the secrets document
- `.bootstrap-secrets.env.example` — template of the workstation-local pre-seed
  (human-known credentials for provisioning)
- `examples/demo/` — a complete example instance host with placeholder values
- `tests/` — VM profile, fixture secrets and drive script of the boot test

## Instances

An instance is a separate (usually private) repository holding everything
specific to one deployment: host configuration, disk layout, sops-encrypted
secrets and `.sops.yaml`. Its flake consumes Oduna:

```nix
{
  inputs.oduna.url = "github:oduna-dev/oduna";

  outputs =
    { oduna, ... }:
    {
      nixosConfigurations.myhost = oduna.inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          oduna.nixosModules.default
          ./hosts/myhost # default.nix + disko.nix, see examples/demo/host
        ];
      };
      inherit (oduna) apps formatter;
    };
}
```

Each host sets at least the values the demo host shows, plus
`homelab.secrets.sopsFile` pointing at the instance's encrypted secrets and
`homelab.instance.hostDir` naming the host directory relative to the instance
root.

### Provisioning

Run from the instance directory (or set `ODUNA_INSTANCE`):

```bash
# fresh install onto a machine booted into the NixOS installer ISO
nix run .#bootstrap -- myhost root@<live-ip>
# post-install convergence (runs automatically at the end of bootstrap)
nix run .#postinstall -- myhost root@<host>
# acceptance checks over SSH
nix run .#checks -- myhost root@<host>
# dry-run evaluation of the full system
nix run .#validate -- myhost
```

The bootstrap generates the host identity, ZFS pool keys and the Borg key,
pauses for you to store them in an offline recovery vault, materializes the sops
secrets from the template plus the pre-seed, and installs via nixos-anywhere.
Day-2 deploys are a regular
`nixos-rebuild switch --flake .#myhost --target-host root@<host>`. Add
`CHECK_BACKUPS=1` to the checks to include the backup checks. Rebuilding on new
hardware and restoring the data is described in
[docs/restore-drill.md](docs/restore-drill.md).

## Development

```bash
nix run .#lint    # gitleaks, nixfmt, deadnix, Prettier, markdownlint, shellcheck
nix fmt           # format Nix files
nix build .#checks.x86_64-linux.vm-test       # boot test of the demo instance (needs KVM)
nix build .#checks.x86_64-linux.restore-test  # backup and restore round trip (needs KVM)
```

Work happens on one branch per task and goes into `main` through a pull request
that is rebased, not squashed; the rules are in [AGENTS.md](AGENTS.md).

To try unreleased changes against an instance, point its input at a local
checkout from the instance directory:

```bash
nix build .#nixosConfigurations.myhost.config.system.build.toplevel \
  --override-input oduna path:../oduna
```

## License

[MIT](LICENSE)
