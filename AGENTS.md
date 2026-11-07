# Agent instructions (Oduna)

Oduna is a NixOS flake: modules, provisioning scripts and tests for a
Git-declared home and dev server. Instances live in their own repositories and
consume `nixosModules.default`; this repository never contains instance data.

- **Nix in non-interactive shells.** The agent shell may not source the user's
  profile; add `/nix/var/nix/profiles/default/bin` to `PATH` before invoking
  `nix`.
- **Lint after every change.** Run `nix run .#lint` (gitleaks, nixfmt check,
  deadnix, Prettier, markdownlint, shellcheck on every shell shebang file) and
  fix every finding; format Nix files with `nix fmt` (nixfmt RFC style).
- **No instance data.** Domains, host names, accounts, disk IDs, keys and e-mail
  addresses belong to instances. Examples use `example.org` and the demo
  instance under `examples/demo/`.
- **Schema.** Global parameters go through the typed `options.homelab` schema in
  `modules/homelab.nix`; service modules never hardcode them.
- **Secrets.** Only the plaintext template `secrets/secrets.example.yaml` lives
  here. New secrets are added to the template and to `modules/secrets.nix`.
- **No logic in Nix strings.** Host-side scripts are files with a shebang next
  to their module, packaged with `pkgs.writeShellApplication` or read with
  `builtins.readFile`; parameters reach them through the environment or
  arguments, never through Nix interpolation into script text.
- **English only.** Code comments, docs, commit and PR messages.
- **Comment and docs discipline.** State current facts, not history (no
  changelog in comments). Document the surprising, not the obvious. One
  canonical place per fact: code comments hold implementation details, the
  README holds the overview and manual steps.
- **Plan vs. implementation.** `docs/vision.md` is the strategic plan. When a
  planned item is implemented, replace its details there with a one-line pointer
  to the implementation; implementation files never cite the plan.
