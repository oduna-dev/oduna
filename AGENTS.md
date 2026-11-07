# Agent instructions (Oduna)

Oduna is a NixOS flake: modules, provisioning scripts and tests for a
Git-declared home and dev server. Instances live in their own repositories and
consume `nixosModules.default`; this repository never contains instance data.

- **Nix in non-interactive shells.** The agent shell may not source the user's
  profile; add `/nix/var/nix/profiles/default/bin` to `PATH` before invoking
  `nix`.
- **Lint after every change.** Run `nix run .#lint` (gitleaks, nixfmt check,
  deadnix, Prettier, markdownlint, shellcheck on every shell shebang file, and a
  check that fails on multi-line shell in Nix strings) and fix every finding;
  format Nix files with `nix fmt` (nixfmt RFC style).
- **No instance data.** Domains, host names, accounts, disk IDs, keys and e-mail
  addresses belong to instances. Examples use `example.org` and the demo
  instance under `examples/demo/`. Comments and docs do not name the first
  instance either.
- **Schema.** Global parameters go through the typed `options.homelab` schema in
  `modules/homelab.nix`; service modules never hardcode them.
- **Secrets.** Only the plaintext template `secrets/secrets.example.yaml` lives
  here. New secrets are added to the template and to `modules/secrets.nix`.
- **No logic in Nix strings.** Host-side scripts are files with a shebang next
  to their module, packaged with `pkgs.writeShellApplication` or read with
  `builtins.readFile`; parameters reach them through the environment or
  arguments, never through Nix interpolation into script text. The lint enforces
  this for shell bodies; the generated Caddyfile is the one multi-line string it
  leaves alone.
- **Git workflow.** One branch per task, one PR into `main`. Rebase instead of
  squashing: keep the branch rebased on its base (`main`, or the parent branch
  of a stacked PR) with `git rebase`, and merge with "Rebase and merge"; never
  squash and never create merge commits. Commits land in `main` one by one, so
  each one is a self-contained change that passes the lint with a message that
  says why; tidy a branch (amend, fixup, reorder) before it is merged. A stacked
  PR targets its parent's branch; after the parent has merged, rebase the child
  onto `main` and retarget the PR. A plain `git rebase main` skips the commits
  whose patch is already in `main`; `git rebase --onto main <parent-branch>`
  replays only the child's own commits, but only while the local parent branch
  still points at its pre-merge tip. After a rebase, push your own PR branch
  with `--force-with-lease`; never force-push `main` or a branch someone else
  works on. Rebase merging gives the commits new hashes, so instances pin the
  commit on `main` after the merge, not the PR head.
- **Store paths in units.** A unit environment variable that names a file of
  this repository is interpolated (`"${./compose.yml}"`), never passed through
  `toString`: that drops the Nix dependency, the file is missing from the system
  closure and the unit fails only at run time. Script variables must not share a
  name with variables the wrapped tool reads itself (`COMPOSE_*`, `BORG_*`).
- **Evaluation is not the runtime check.** Lint and evaluation cannot see
  closure or run-time problems; the VM test is the gate for changes to units and
  scripts, and it runs only on GitHub Actions (no KVM in the cloud container).
  Before naming the cause of a red check, read the failing log lines.
- **Merging.** Read the PR head from the API and pass it as `expectedHeadSha`,
  never a hash typed from memory. Merge only when CI is green on that head and
  the review has run; the review bot can push to a branch despite its prompt, so
  check the head again right before merging.
- **Pushing.** Run the lint before every push. A push to a PR cancels the
  running VM test and restarts it, so batch the fixes of a round into one push.
- **PR descriptions.** Sections What, Behavior, Verified and Not verified: say
  plainly what was checked and what was not.
- **English only.** Code comments, docs, commit and PR messages.
- **Comment and docs discipline.** State current facts, not history (no
  changelog in comments). Document the surprising, not the obvious. One
  canonical place per fact: code comments hold implementation details, the
  README holds the overview and manual steps.
- **Plan vs. implementation.** `docs/vision.md` is the strategic plan. When a
  planned item is implemented, replace its details there with a one-line pointer
  to the implementation; implementation files never cite the plan.
