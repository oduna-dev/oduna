# Oduna: Vision & Refactoring Plan

> **Status:** living plan. Decisions are recorded in §8; implemented items are
> replaced by pointers to the code. The modules currently run one real
> deployment (the maintainer's family instance, kept in a private repository).

## 1. Mission Statement

### Draft

> **Your server, in Git.** Rebuild your whole home or dev-shop server from one
> repository on any hardware, restore the data, and carry on — ZFS storage,
> single sign-on and a curated set of apps, from family photos to a Git forge
> with CI and AI agents, with no vendor in the loop.

Short form for positioning: **"the GitOps home & dev server"** — the
Umbrel/ZimaOS/Start9 experience, but declared in a repository you own, on
whatever hardware you have.

One platform, two packs, one continuum of users: the hobbyist running it for the
family, the semi-professional developer running it for side projects, and the
small software shop that is strong at engineering but weak at (Dev)Ops.

### Why this exists (origin story = product thesis)

The project started on TrueNAS: solid ZFS, but apps as containers on an
appliance whose direction is set by its vendor (app runtime switched from k3s to
Docker in one release, build system and sources becoming less open), and
configuration management with Ansible that is hard to keep idempotent across
TrueNAS versions. The thesis: **a NixOS-based storage server gives the TrueNAS
reliability story (ZFS, snapshots, scrubs, alerts) plus what an appliance cannot
— the entire box, OS to apps, as reviewable, rollback-able code.**

### Supporting principles (what the mission commits to)

1. **ZFS and owned hardware first.** The primary target is a physical box (home,
   office, small rack). Datasets, snapshots, scrubs, replication and disk-health
   alerts are first-class, not an add-on.
2. **Everything is code, nothing drifts.** One instance repository is the
   complete, idempotent description of a box; a version upgrade is a lock-file
   change with an automatic rollback path.
3. **Identity first.** Every app sits behind one account with MFA and
   self-registration by email (domain-restricted or invite-based); every app
   keeps a documented break-glass admin path.
4. **Data you can walk away with.** No app enters the catalog before it is part
   of backup and a tested restore.
5. **Curated over comprehensive.** A small catalog of deeply integrated dev and
   home apps beats an app store of shallow ones. Docker Compose stacks are
   first-class next to native NixOS services.
6. **Web and sync clients, not network shares.** Files are reached through a web
   UI, sync clients and WebDAV as the lowest common denominator that every OS
   and most mobile apps speak — all behind the same SSO identity (app passwords
   for clients that cannot do OIDC); SMB/NFS shares are not part of the product.
   Mail and full collaboration suites (Microsoft 365, Google Workspace,
   mailbox.org, a full Nextcloud) stay with the provider the user already has.
7. **VPS as a companion, not the core.** Rented servers serve as offsite
   replication targets, CI runners or small app-only instances — the same
   modules, a different profile.
8. **No rug pull possible.** Every layer must be forkable and keep working
   without its vendor: community-governed OS (NixOS), image digests pinned and
   mirrorable to the own forge, apps whose relied-on features live in the open
   source edition, and the product's own code under an open license.
9. **AI-ready, not AI-dependent.** The platform runs no LLM infrastructure of
   its own: model access stays external (the user's provider keys or an
   organization's own proxy). It offers places to run agents — CI workflows and,
   as an add-on, hosted agent workspaces — while code, secrets and history stay
   on the box.

### Naming

"Homelab" describes the first instance, not the product; "NAS" is back in scope
as the category word now that owned hardware and ZFS are the core. **The product
name is Oduna** (see Name candidates below for how it was chosen). The module
namespace, flake outputs and CLI follow it (`oduna.*`, §6.2).

### License

**MIT.** Everything in the stack is open source already and there is no
commercial story to protect, so the simplest, most reusable license wins:

- Modules can be upstreamed to nixpkgs (MIT) without relicensing.
- Running copyleft apps (e.g. SFTPGo, AGPL-3.0) as separate services next to the
  product is unaffected.
- The one constraint: AGPL-licensed _code_ (e.g. from Selfhostblocks) is not
  copied into the repository — compatibility with SHB stays on interfaces (§4).
- Contributions follow the inbound=outbound rule (DCO sign-off, no CLA).

### Name candidates

Theme: land you own outright, with no lord above it — the "no vendor, no rug
pull" promise. Avoid "Nix" and "Git" in the name (both are trademarks with usage
policies) and anything that implies an appliance vendor.

The allod idea stays the favorite. _Allod_ comes from Frankish _al-ōd_ — "all" +
"estate/wealth": property held whole, owing nothing to a lord. Close spellings
of the word itself (Allodium, Allodial, Alod) share the dominant element of the
pending US registration and would likely inherit the conflict in the same
classes, so the variants below keep the **meaning** while changing the word:

| Candidate                | Relation to the allod idea                                                   | Status of the quick check                                                            |
| ------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| ~~Allod~~                | The original                                                                 | ❌ Dropped: pending US brand registration for software products                      |
| Allodium, Allodial, Alod | Spelling variants                                                            | ❌ Too close to the pending registration                                             |
| Allhold                  | Literal English calque of _al-ōd_ ("all" + "holding")                        | ❌ Rejected: too plain                                                               |
| Alleu                    | The French word for allod (_franc-alleu_: free allod)                        | No software use found; pronunciation unclear to non-French speakers                  |
| Udal                     | Orkney/Shetland udal tenure: land held absolutely, without a feudal superior | ⚠️ Related to Norse _odal_, whose rune is misused by extremists — avoid              |
| Fiefless                 | "Without a fief" — the opposite of renting land from a lord                  | ⚠️ "Fief" is an existing authentication product — confusing next to SSO              |
| Homefold                 | Different metaphor: bringing everything home into one fold                   | No software use found; plain English compound                                        |
| **Freehold**             | Different metaphor: owning outright instead of renting                       | Likely crowded namespace                                                             |
| Stackyard                | Different metaphor: the yard where the stacks are kept                       | ❌ An MIT developer tool already uses it; "Stockyard" is a similar self-hosted suite |
| Steading, Cairn          | Different metaphors                                                          | ⚠️ Existing software uses both                                                       |

**Round, coined names built from the allod roots** (the plain English calques
read as too literal): the allod's own root _ōd_ ("owned estate, wealth")
combined with words for home, or constructed-language words for estate and home.

| Candidate  | Construction                                                                                                     | Quick check                                                                                                                                                                                            |
| ---------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Odoma**  | _ōd_ (the owned estate in _al-ōd_) + _domus_ (home): "the home you own outright"; o-do-ma                        | Strong contender. A Swiss AI and UX studio uses the name (services, not software products); the "Odo-" opening also sits near Odoo, the open source business suite — both to weigh in the brand search |
| **Oduna**  | _ōd_ (owned estate) + Old English _tūn_ (enclosed homestead, origin of "town"): "the homestead you own"; o-du-na | No software use found; shares the "Od-" opening with Odoo, but ends differently                                                                                                                        |
| **Penata** | From the _Penates_, the Roman guardians of the household storeroom (_penus_): storage and home in one figure     | No software use found                                                                                                                                                                                  |
| **Bieno**  | Esperanto for "estate, farm" — a constructed language nobody owns, like the project                              | No software use found in a web search                                                                                                                                                                  |
| Domova     | Slavic "home" (as in Czech _domov_)                                                                              | Nothing found, but a real word rather than a coinage                                                                                                                                                   |
| Domalo     | Blend of _domus_ + _allod_                                                                                       | ⚠️ Leans on "Domo" — a large BI vendor and a "home OS" household app use it                                                                                                                            |
| Hejmo      | Esperanto "home"                                                                                                 | ❌ Too close to "hjem", an existing Nix home-environment project in the same ecosystem                                                                                                                 |

Also checked and weaker: Larea (from the _Lares_, household guardian spirits —
crowded by many "Lara" projects), Domaro (Esperanto "group of houses" — close to
the Domo/Domodar home-automation names).

**Decision: Oduna.** Brand-register results for the shortlist:

- **Oduna:** a single, unrelated and expired registration; web search clean.
- **Odoma:** no registrations, but a Swiss AI and UX studio trades under the
  name — kept as the reserve.
- **Penata:** existing registrations — dropped.

The nixpkgs package and attribute namespace is free as well. Next steps to
secure it: GitHub organization and domains; the nixpkgs name once the product
flake is published. `oduna.org` belongs to an unrelated French non-profit
outside software and the GitHub handle `oduna` is a dormant personal account
without repositories — neither is a trademark conflict. The project uses a
consistent pair instead: the domain `oduna.dev` and the GitHub organization
`oduna-dev`, linked from the repository and docs.

## 2. Product-Market Fit Analysis

### 2.1. Who has the problem?

| Segment                                                                 | Pain                                                                                         | Fit                               |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------- |
| **Hobbyist families on scrap hardware** (the own family first)          | Want the Umbrel/ZimaOS experience without lock-in; appliance vendors relicense or paywall    | **Primary (dogfood, users)**      |
| **Semi-professional developers / freelancers**                          | Side projects need Git, CI, secrets, AI agents; SaaS per-seat pricing, data control          | **Primary (users, contributors)** |
| **Small software shops strong at engineering, weak at (Dev)Ops (2–25)** | Need forge, CI, password manager, AI agents; nobody owns ops; SaaS bills grow with headcount | **Primary (demanding users)**     |
| Engineers leaving TrueNAS, Unraid or Synology                           | Appliance direction outside their control, config not reproducible                           | Entry channel                     |
| Freelance admins / small MSPs                                           | Need a repeatable, low-touch stack per client                                                | Multiplier, later                 |
| Non-technical small businesses                                          | Same as dev shops, but nobody to own it                                                      | Only via a service                |

The segments form a continuum of the same person: whoever runs the box at home
is often the one asked to set up the tooling at work. Hobbyists bring users,
contributors and credibility; small software shops are the most demanding users
(§3) — and their gap (engineering yes, operations no) is exactly what a
Git-declared, self-updating platform closes.

### 2.2. The value equation

- **For TrueNAS-style users:** same ZFS safety, plus reproducibility, atomic
  upgrades with rollback, apps with SSO and backup already wired, and no vendor
  deciding the app runtime. The cost: less GUI, more Git.
- **For small teams:** per-seat SaaS (Git hosting + CI, password manager, wiki,
  project management) grows linearly with headcount; a box they own is a flat
  cost. _(Order-of-magnitude argument; verify list prices before using them
  externally.)_ The hidden cost is admin time — every design decision is
  measured in "minutes of human attention per month".
- **Ownership:** data on own hardware, export in native formats, no
  terms-of-service changes.

### 2.3. Competitive landscape

| Alternative                      | What it does well                                                   | Gap this product targets                                                                         |
| -------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| **TrueNAS Community Edition**    | Best-known ZFS appliance, free, strong GUI                          | Appliance model: vendor-chosen app runtime, config in a database not in Git, Ansible drift       |
| **HexOS** (paid UI on TrueNAS)   | Shows people pay for "TrueNAS, but easier" (lifetime license model) | Depends entirely on TrueNAS's direction; GUI-first, not code-first                               |
| **Unraid** (paid license)        | Proves prosumers pay for a NAS OS; big community app catalog        | Not ZFS-native by heritage, imperative, apps without SSO/backup integration                      |
| **Synology / QNAP**              | Turnkey hardware + software                                         | Closed, hardware lock-in, aging app ecosystems                                                   |
| **Cloudron**                     | App store with SSO, backups, auto-updates                           | Different slice: app hosting as a service on a rented server; no ZFS/NAS layer, not reproducible |
| **Selfhostblocks** (FOSS, NixOS) | Contracts for SSO/backup/proxy, ZFS datasets, VM tests              | Library for Nix users, native services only, LLDAP + Authelia, no installer (see §4)             |
| **Umbrel / ZimaOS / Start9**     | Polished home app stores, sold with own hardware                    | Config lives in the box; vendor-curated apps; see §2.6 for license moves                         |

**Defensible differentiators:** (1) the whole NAS, OS to apps, is reproducible
from one repository with atomic upgrade and rollback — no appliance offers that;
(2) SSO-and-backup-first curation; (3) Docker Compose stacks and native services
under one contract; (4) a dev-workflow catalog (Forgejo with runners, CI,
password manager) that the home-media platforms ignore.

**Honest weakness:** the primary user segment self-serves from open source and
rarely pays for software licenses; the GUI expectations set by TrueNAS are
expensive to meet. Both shape the project model below.

### 2.4. The "SSO tax" — the catalog's real constraint

Many business tools reserve SSO for paid tiers. Curation must check this per
app; forward-auth (Authentik proxy outpost, as Navidrome uses today) is the
fallback for apps without OIDC, at the cost of a second, app-local user model.

| Candidate                    | Category           | SSO in free/community edition (to verify per release) | Notes                                                                                  |
| ---------------------------- | ------------------ | ----------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Forgejo (+ external runners) | Git, CI, packages  | OIDC ✅                                               | Already integrated; runners become a separate host role                                |
| Vaultwarden                  | Password manager   | OIDC ✅                                               | Already integrated; master password stays the decryption key                           |
| Jenkins (controller only)    | CI                 | OIDC plugin ✅                                        | Agents external, like Forgejo runners                                                  |
| Woodpecker CI                | CI                 | Via Forgejo OAuth ✅                                  | Lighter alternative to Jenkins for Forgejo users                                       |
| Outline / BookStack          | Wiki / docs        | OIDC ✅                                               | Outline requires an external auth provider — a natural fit                             |
| Vikunja / Leantime           | Tasks / PM         | OIDC ✅                                               | Lightweight project management                                                         |
| Plane / OpenProject          | PM                 | ⚠️ verify — OIDC has been a paid feature              | Popular, but check the edition before committing                                       |
| n8n                          | Automation         | ⚠️ OIDC/SAML are enterprise features                  | Forward-auth gate + n8n's own owner account; consider Activepieces/Windmill limits too |
| Grafana / Uptime Kuma        | Observability      | Grafana OAuth ✅ / Kuma none (forward-auth)           | Status pages for the team                                                              |
| Paperless-ngx                | Document archive   | OIDC via allauth ✅                                   | Strong small-business appeal (invoices, contracts)                                     |
| GlitchTip                    | Error tracking     | OIDC via allauth ✅                                   | Sentry-compatible                                                                      |
| OpenChamber (OpenCode UI)    | AI coding agent UI | ❌ password protection only (MIT)                     | Forward-auth gate; one isolated OpenCode instance per user (see §2.5)                  |
| Immich / Navidrome / Actual  | Home pack          | OIDC ✅ / forward-auth / OIDC ✅                      | Today's family apps; stay as an optional "home" pack                                   |

### 2.5. The dev-shop pack (the professional niche)

A typical small-to-mid software team runs a mix of SaaS and self-hosted tooling
— a password manager, a hosted Git platform, a self-hosted CI server and,
increasingly, LLM agents that automate code review and task implementation. The
pack offers a drop-in equivalent that a team without dedicated ops people can
own:

| Need                         | Typical today               | Pack equivalent                                                                                                              |
| ---------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Password manager             | 1Password (SaaS)            | Vaultwarden (Bitwarden-compatible clients); official Bitwarden self-host where a vendor contract is required                 |
| Git hosting + PRs + packages | Bitbucket / GitHub          | Forgejo (PRs, package/container registry); as a pull mirror of external repos it is the fallback during outages or a cut-off |
| CI                           | Jenkins                     | Forgejo Actions on ephemeral container runners; Jenkins controller (OIDC) for existing pipelines                             |
| CI secrets                   | Jenkins credentials store   | Forgejo Actions secrets; a dedicated secrets manager (e.g. OpenBao) only if needed                                           |
| LLM access                   | Provider or own proxy       | Out of scope: external, bring your own provider keys or proxy (revisit if a clear open source gateway emerges)               |
| AI code review / task agents | Proxy-driven automation     | Agent workflows as Forgejo Actions (label or comment triggers) running agent CLIs in runners                                 |
| Interactive agents           | Local IDE / paid agent SaaS | Add-on: agent workbench (below)                                                                                              |

**Agent architecture principles:**

- Agents run only inside **ephemeral runner containers** on a dedicated runner
  host role, never on the storage box itself (the current hardware also lacks
  the CPU features and GPU for local models).
- Agent jobs get **scoped forge tokens** (one repository, PR-write only) and a
  model key from the forge's secrets — never deploy keys or production secrets.
- The model endpoint is configuration, not infrastructure: provider API, an
  organization's proxy or a later local model server are interchangeable.

**Add-on: agent workbench (OpenCode-first, agent-agnostic).** One workspace
image, built by the product flake and pinned like every other component, with
two entry points — so interactive work and background work share the same tools,
configuration and repository conventions (`AGENTS.md`):

| Entry point                           | What the user gets                                                                                                                 | How it runs                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **Interactive workspace**             | OpenChamber in the browser (chat + coding agent), a browser terminal, repositories cloned from the forge with the user's own token | One container per user with OpenCode server + OpenChamber and a persistent home volume, started on demand after SSO login    |
| **Background worker** ("cloud agent") | Comment `/agent …` or label an issue/PR; the agent works on a branch and answers with a comment or a PR                            | The same image as a Forgejo Actions job container: `opencode run` in a non-interactive job, results posted via the forge API |

Design rules:

- **OpenCode is the default, not the boundary.** The image also carries a
  browser terminal, so any CLI agent (Claude Code, Codex CLI, Aider, …) runs in
  the same workspace on its own subscription — no lock-in to one agent project,
  in line with principle 8.
- **Forge-native background worker:** the GitHub action this repository uses
  today depends on GitHub's API and OIDC tokens; the Forgejo variant is a plain
  workflow around `opencode run` plus the forge API, with a repository-scoped
  token.
- **Isolation per identity:** OpenChamber only knows a password, so the
  forward-auth gate sits in front and routes each SSO identity to its own
  container; no workspace can see another user's home or tokens.
- **Bring your own model key** per user (workspace) or per repository (forge
  secret for the worker), never stored by the platform.
- **Runs on the runner role**, never on the storage box; repositories live in
  the forge, so workspaces are disposable and only per-user configuration is
  backed up.
- **Spawner: start thin.** A small router behind forward-auth that starts a
  user's container on first request and stops it when idle; evaluate Coder only
  if workspace lifecycle needs outgrow that.

Alternatives considered: OpenHands (autonomous agent platform with its own
sandbox runtime — heavier, and largely single-user in its open source form),
Coder (strong workspace orchestration, but a whole product surface of its own),
plain code-server (an editor, not an agent UI).

### 2.6. Open-source landscape: build vs. reuse

**Appliance-style projects** deliver the family experience, but configuration
lives inside the box and the vendor curates apps — and several have shown the
lock-in risk this project exists to avoid:

| Project                               | State                                                                        | Verdict for this project's requirement                      |
| ------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------- |
| umbrelOS                              | Relicensed to PolyForm Noncommercial (source-available, not OSI open source) | ❌ Not Git-declared; commercial use restricted              |
| ZimaOS                                | Paid Plus edition since 1.5; free edition capped (apps, disks, users)        | ❌ Paywall moves are exactly the rug-pull risk              |
| CasaOS (Apache-2.0)                   | Core development largely stalled since the vendor's focus moved to ZimaOS    | ❌ Left behind by its own vendor                            |
| StartOS (Start9)                      | MIT per the current repository; DIY install; whole-server backup and restore | ⚠️ Closest in spirit, but vendor packaging and no Git state |
| YunoHost, FreedomBox, Runtipi, Cosmos | Open source, community-run                                                   | ⚠️ Open, but imperative — drift returns                     |

**Git-declarative projects** meet the rebuild requirement and are the reuse
candidates:

| Project                            | What to reuse                                                                  | Why not as the whole solution                                    |
| ---------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| Kubernetes home-ops (Talos + Flux) | GitOps patterns, Renovate-driven updates                                       | Heavy for one box; ZFS awkward; SSO/backup wiring per app manual |
| Clan (clan-core, NixOS)            | Machine install (nixos-anywhere), generated secrets, backup provider interface | Machine framework, not an app catalog with SSO                   |
| Selfhostblocks (NixOS)             | Contract shapes, app modules, Playwright login/SSO/backup tests (§4)           | Native services only; different IdP/proxy choices                |
| Ansible-based NAS playbooks        | —                                                                              | Same idempotency problems that motivated this project            |

**Conclusion:** no existing project combines NixOS + ZFS + Compose stacks +
Authentik SSO + per-app backup with a full rebuild from Git. Building the glue
is not wasted effort; rebuilding _plumbing_ that Clan (install, secrets, backup
interface) or Selfhostblocks (app modules) already maintain would be.

## 3. Project Model

**Decision: open source, no business plan.** The project must pay off as the own
family (and own dev) infrastructure first; anything beyond that is seen later.

Consequences for the design:

- **Scope is set by own use plus a few friendly instances,** not by a market.
  Features without a user in that circle wait.
- **Low maintenance beats feature count:** the measure stays "minutes of
  attention per month per instance", because the maintainer is also the main
  user.
- **The doors stay open cheaply:** uniform instance repos, release channels and
  health/backup reporting (§6) are what a later service or appliance offering
  would need — they are built because they serve the own instances anyway, not
  for a business case.
- **External validation without a work pilot:** one or two friendly instances
  outside the family (a fellow developer, a friend's household) once Phase 2 is
  done; their missing-feature list feeds the catalog.

Market observations for later reference: people pay for NAS operating systems
(Unraid, HexOS on TrueNAS); home-server vendors monetize hardware (Umbrel,
ZimaOS, Start9); small teams pay for "it works and someone is responsible" —
i.e. a service, not software licenses.

## 4. Foundation Decision: Selfhostblocks

Selfhostblocks (SHB) is the closest existing project: NixOS modules with
_contracts_ (swap reverse proxy, database, backup or SSO implementation without
changing the service module), automatic ZFS datasets per service, restic/Borg
backup with restore scripts, VM tests including Playwright login/SSO/backup
flows, an RFC to bring contracts into nixpkgs, and a sibling project (Skarabox)
for encrypted-ZFS installs. It is AGPL-3.0, NLnet-funded and maintained mainly
by one person.

### 4.1. Fit and gaps

| Topic             | SHB                                  | This project                                                                                                                |
| ----------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Service runtime   | Native NixOS services only           | Native **and** Docker Compose stacks (Immich, Authentik, …)                                                                 |
| Identity          | LLDAP + Authelia                     | Authentik — needed for email self-registration (enrollment flows), forward-auth outposts and an admin UI for non-Nix admins |
| Reverse proxy     | Nginx                                | Caddy                                                                                                                       |
| nixpkgs channel   | Tracks unstable                      | Stable release (NAS appliance expectations)                                                                                 |
| Install path      | Skarabox (nixos-anywhere based)      | Installer + recovery kit (§6.5) — Skarabox is a candidate to reuse                                                          |
| Audience          | Nix users composing their own server | Instance repo + data file; operators need no Nix                                                                            |
| Contracts concept | ✅ mature, upstreaming to nixpkgs    | Missing today (couplings C1–C4) — the main thing to adopt                                                                   |

### 4.2. Options

1. **Hard fork** — immediate head start, but every gap above means rewriting
   core blocks (IdP, proxy, runtime), and the fork then carries a permanent
   merge burden against a single-maintainer project heading elsewhere.
2. **Depend on SHB as a flake input** and add own blocks (compose runtime,
   Authentik, Caddy) through its contracts — works only if SHB accepts those
   providers upstream; otherwise it degrades into option 1.
3. **Own codebase, aligned with SHB's contract shapes** — implement the app
   contract (§6.4) with option names and semantics modeled on SHB contracts and
   the nixpkgs contracts RFC, reuse individual pieces where they fit (Skarabox
   for installation, backup/restore patterns, Playwright test approach),
   contribute generic parts (e.g. a compose-stack contract provider) upstream.

**Decision: option 3 — "API-compatible", not forked.** Cloning SHB and
upstreaming changes would add friction against a project with a different
direction; instead the app contract (§6.4) mirrors SHB's contract option names
and semantics (and the nixpkgs contracts RFC) wherever the concepts overlap, so
modules can move between the projects. Compatibility is on interface names and
semantics only: SHB is AGPL-3.0, so its code is not copied into this
MIT-licensed repository (§1, License). Generic pieces (e.g. a compose-stack
provider) are offered upstream opportunistically, starting with a conversation
with the maintainer. If contracts land in nixpkgs, both projects converge on the
same interfaces.

## 5. Review of the Current State

### 5.1. What is already sound (keep)

- **Typed `homelab.*` schema with env → host layering** (`modules/homelab.nix`,
  `envs/`): the right seed for a product configuration model.
- **sops-nix secrets with a single encrypted document** and a template that
  doubles as schema; machine decryption via the host key.
- **Idempotent host-side convergence** (`homelab-converge`): runtime state the
  Nix config cannot own is converged on every activation and on secret rotation.
  The _principle_ is product-grade.
- **Break-glass discipline:** no local login path is ever removed before SSO
  works; Vaultwarden keeps password login.
- **Native-vs-compose placement rule** with one database per stack — avoids
  cross-app version coupling.
- **VM boot test** (`tests/`) with neutralized externals and pre-pulled images:
  the foundation for per-app and upgrade tests.
- **Disaster-recovery thinking** (escrow, recovery walkthroughs, append-only
  offsite) is well beyond typical self-hosting setups.

### 5.2. Couplings that block reuse

| #   | Finding                                                                                                                                                                                                     | Where                                                                     | Impact on productization                                                                                                      |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| C5  | **Vendor lock-in at the edges:** INWX (custom Caddy plugin build), NetBird (setup-key enrollment, peer-anchored DNS by hand), Hetzner StorageBox (Borg over port 23), Healthchecks.io, mailbox.org wording. | `ingress.nix`, `networking.nix`, `backups.nix`, `monitoring.nix`, scripts | Every other user has a different DNS, VPN, backup and alerting provider                                                       |
| C6  | **ZFS and a specific disk topology assumed** (`zfs.nix` derives pools from disko; snapshot policies name datasets; ARC cap fixed at 16 GiB).                                                                | `modules/zfs.nix`, `the host disk layout`                                 | VPS profiles typically have one ext4/btrfs disk and 4–16 GiB RAM                                                              |
| C7  | **Instance data and product code live in one repo** (family domain, deploy key, StorageBox URL, runner UUID, encrypted secrets next to the modules).                                                        | `envs/`, `secrets/`, `flake.nix`                                          | No way to consume the modules as an upstream with releases                                                                    |
| C8  | **Workstation-push lifecycle:** deploys and updates are `nixos-rebuild --target-host` from a Nix workstation; image tags are bumped by hand.                                                                | README, compose files                                                     | Contradicts "easy automatic updates" and "no Nix knowledge needed"                                                            |
| C9  | **Bootstrap requires a Nix workstation, a filled pre-seed file and a KeePass escrow ritual**, with 9 required human-known values tied to specific providers.                                                | `scripts/bootstrap.sh`, `.bootstrap-secrets.env.example`                  | Not an install path for the target audience                                                                                   |
| C10 | **One shared break-glass password for all apps.**                                                                                                                                                           | `admin.env`, converge                                                     | Acceptable for a family; a business needs per-app credentials in a recovery kit                                               |
| C13 | **Single-host assumption:** runners run on the server; no host roles.                                                                                                                                       | `modules/services/forgejo.nix`                                            | "External runners for bigger setups" needs a runner role                                                                      |
| C14 | **File access and replication missing:** no web/WebDAV file app (only Immich for photos), no ZFS replication, the UPS is still planned.                                                                     | `modules/`                                                                | Family files and dev artifacts have no user-facing home                                                                       |
| C15 | **Shell and config logic inside Nix strings:** multi-line `script = ''…''` bodies and templated config with Nix interpolation (the generated Caddyfile).                                                    | `ingress.nix`                                                             | Not lintable or testable on its own; Nix interpolation into shell is a quoting and injection hazard; diffs are hard to review |

## 6. Target Architecture

### 6.1. The core idea: product vs. instance

Split the repository's two concerns into two artifacts:

```text
┌──────────────────────────── PRODUCT (upstream flake, versioned) ───────────────────────────┐
│  nixosModules.default      core platform + app catalog + provider adapters                 │
│  lib.mkInstance            turns an instance config file into nixosConfigurations          │
│  templates.instance        skeleton for a new instance repo                                │
│  packages.installer        TUI/web installer + recovery-kit generator                     │
│  checks.*                  per-app VM tests, profile tests, upgrade tests                  │
│  release channels          stable / edge (git branches or tags)                            │
└──────────────────────────────────────────────┬─────────────────────────────────────────────┘
                                               │ flake input (pinned by lock)
┌──────────────────────────── INSTANCE (one small repo per installation) ────────────────────┐
│  instance.toml        domain, profile, providers, enabled apps, sizing  ← GUI-editable     │
│  hardware/            generated disko + hardware config (physical profiles)                │
│  secrets.yaml         sops, encrypted to host key + recovery key (+ admin keys)            │
│  flake.nix / .lock    3-line wrapper: product.lib.mkInstance ./instance.toml              │
└──────────────────────────────────────────────┬─────────────────────────────────────────────┘
                                               │ pulled by the host
┌──────────────────────────── HOST RUNTIME ──────────────────────────────────────────────────┐
│  update agent   pull → build → switch → health gate → rollback/commit → report             │
│  platform core  ingress · identity · secrets · storage · backup · monitoring · admin UI    │
│  apps           enabled catalog entries, each fulfilling the app contract                  │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

The family setup becomes **instance #1** of the product — the dogfooding
installation — and stays the primary acceptance test.

### 6.2. Configuration model

- **One data file per instance** (`instance.toml`, or JSON) validated by the Nix
  option schema. Data instead of Nix code is what makes a GUI/TUI able to edit
  it safely; power users can still add a `custom.nix` escape hatch.
- **Deployment profiles** bundle defaults for storage, access, sizing:
  - `home-zfs` (**primary**) — owned hardware, ZFS pools (mirror/RAIDZ),
    mesh-first access (today's setup);
  - `companion-mesh` — VPS or second box reachable only via mesh VPN: offsite
    replication/backup target, CI runners, agent workspaces, small app-only
    instance.
- **App selection:** `apps.<name>.enable = true` plus a few per-app knobs
  (subdomain, exposure). Packs (`dev`, `office`, `home`) are presets.
- **Host roles:** `server` (default), `runner` (Forgejo/Jenkins agents on
  separate hardware, auto-registered against the server), later `backup-target`.

### 6.3. Platform core (always on)

| Capability      | Target design                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Disks & ZFS** | ZFS datasets per app and data class, snapshots, scrubs, replication (syncoid) to a second box or companion VPS, UPS (NUT), SMART history (e.g. Scrutiny), guided disk replacement. A `plain` adapter covers single-disk companions. Migrating from another NAS is copying datasets — no import tooling.                                                                                                                                                                                                                                                                                                                |
| **Ingress**     | Caddy, vhosts **generated from the app registry** (§6.4). TLS via NixOS `security.acme` DNS-01 (lego, ~100 DNS providers; mesh names are not publicly reachable for HTTP-01) — removes the custom Caddy plugin build.                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Access**      | **Mesh first:** every client, including those inside the LAN, reaches the apps through mesh DNS names, records automated through the provider API. **The mesh control plane is external:** NetBird Cloud by default, or any supported provider the user runs elsewhere (Headscale, a self-hosted NetBird, …); the box only runs the mesh client. Hosting the control plane on the box itself is a future topic, out of scope for now. Public exposure is opt-in per app through the mesh edge, never by default. LAN-only exposure is an explicit per-app exception for devices without a mesh client (TVs, printers). |
| **Identity**    | Authentik, provisioned **declaratively via blueprints** generated from the app registry (groups, OIDC providers, applications, enrollment flow). Self-registration with email verification, domain allowlist or invite-only. Roles: `admins`, `members`, per-app groups.                                                                                                                                                                                                                                                                                                                                               |
| **Secrets**     | sops-nix stays. Secrets are classified per app as _generated_ (installer/host creates them) or _provided_ (human/provider). Recipients: host key + offline recovery key.                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Storage**     | Adapter: `zfs` (datasets per app, snapshot policy by class) or `plain` (directories on one filesystem). Apps declare _data classes_ (database, state, bulk), not dataset names.                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Backup**      | Engine iterates the registry: per-app dump hooks (`sqlite`, `postgres-container`, `command`), quiesce hooks, paths. Targets via adapter: restic (S3-compatible, SFTP) or Borg (SSH, incl. StorageBox). Scheduled restore test into a scratch area.                                                                                                                                                                                                                                                                                                                                                                     |
| **Monitoring**  | Health endpoints from the registry; alerting via SMTP and any webhook (ntfy, healthchecks-compatible URLs); disk/ZFS/SMART on physical profiles.                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Updates**     | Pull-based agent (evaluate `comin` or a small own unit): maintenance window, health gate, automatic rollback, status report to the admin UI and by mail.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Admin UI**    | Status first: evaluate Cockpit in read-only use (its storage/ZFS/sharing plugins mutate the host imperatively and must stay disabled) before building an own Authentik-protected app. Config changes go through `instance.toml` commits, never by mutating the host directly.                                                                                                                                                                                                                                                                                                                                          |

### 6.4. The app contract (the extension point)

Adding an app should mean writing **one module** that fills a declared contract
— the platform does the rest:

```nix
oduna.apps.<name> = {
  enable      = mkEnableOption;
  ingress     = { subdomain; port; exposure = "mesh" | "lan" | "public"; };   # default: mesh
  identity    = { mode = "oidc" | "forward-auth" | "none";
                  redirectUris; scopes; accessGroups; adminGroup; };
  breakGlass  = { converge = <script>; };             # local admin from the recovery kit
  data        = { database = [ paths ]; state = [ paths ]; bulk = [ paths ]; };
  backup      = { dumps = [ { type = "sqlite" | "postgres-container" | "command"; … } ];
                  quiesce = { stop = [ units ]; }; exclude = [ paths ]; };
  secrets     = { generated = [ names ]; provided = [ names ]; };
  health      = { url; };
  resources   = { memoryMiB; };                       # installer sizing warnings
  runtime     = "native" | "compose";                 # compose → shared mkComposeStack
};
```

Consumers of the contract: ingress (vhosts), identity (blueprint generation),
converge (break-glass fragments, ordering), storage (dirs/datasets + snapshot
classes), backup (dumps/paths), monitoring (health), installer (secrets to ask
for, sizing), tests (a generic per-app VM test asserting login page, OIDC
discovery, backup dump and restore). Each app ships its own test on top.

Proposal for the converge split: Authentik blueprints own the IdP side
declaratively; per-app converge fragments own only what the app's own store
needs (client secret, break-glass account). The shared bash monolith dissolves
into small, individually testable units.

### 6.5. Lifecycle flows

**Install (target UX):**

1. Physical (primary): boot the product installer ISO → console shows a URL →
   web/TUI wizard on the LAN; the wizard runs burn-in checks (SMART long test,
   memory test) before touching disks. Companion VPS: run the installer CLI from
   any machine against the rescue system (nixos-anywhere kexecs into the
   installer from any Linux).
2. Wizard asks: domain, profile, disks (physical), access mode + provider, DNS
   provider + credentials, SMTP relay, backup target, apps, first admin email.
3. Wizard generates instance repo, secrets, disk layout; installs; prints a
   **recovery kit** (PDF/paper: recovery age key, pool keys, backup key,
   break-glass credentials, instance repo location).
4. First boot: platform converges, sends the first admin an enrollment link.

**Update:** release channel moves → host agent updates the product input,
builds, switches inside the maintenance window, runs health checks, rolls back
on failure, records the new lock in the instance repo. Compose image digests are
bumped in the _product_ repo (Renovate) and ship through the same channel —
instances never bump tags by hand.

**Change config:** edit `instance.toml` (by hand or via admin UI) → commit →
agent applies. Git history is the audit log.

**Where the instance repo lives:** the user's choice. The template defaults to
the box's own Forgejo as primary with a push mirror to an external host (e.g.
GitHub, private); users who prefer an external primary use Forgejo as a pull
mirror. Recovery never depends on the box's own Forgejo: the external copy (or
the recovery kit's pointer to it) is the source after a total loss. The repo
only carries sops-encrypted secrets, so an external private mirror is
acceptable.

**Recover:** new hardware/VPS → installer "restore" mode → recovery kit +
instance repo → reinstall → backup restore driven by the registry.

### 6.6. Version 1.0 catalog

Version 1.0 proves the platform, not breadth: the apps that run today move onto
the app contract, plus exactly one new app that exercises "add an app" end to
end. Together they cover every contract shape — native and compose runtimes,
OIDC and forward-auth, SQLite and PostgreSQL dumps, bulk and database data
classes.

| App                                       | Pack       | Runtime / identity           | Status            | Why in 1.0                                                                                      |
| ----------------------------------------- | ---------- | ---------------------------- | ----------------- | ----------------------------------------------------------------------------------------------- |
| Authentik, Caddy, backup, Beszel, updates | Platform   | compose / native             | exists            | The platform itself                                                                             |
| Vaultwarden                               | Home + Dev | native, OIDC                 | exists            | Passwords are the first thing both families and teams need                                      |
| Forgejo + Actions on the runner role      | Dev        | native, OIDC                 | exists (role new) | Git, CI, package registry, mirror fallback                                                      |
| Immich                                    | Home       | compose, OIDC                | exists            | Photos; the compose + PostgreSQL contract shape                                                 |
| Actual Budget                             | Home       | native, OIDC                 | exists            | Small native app with SQLite                                                                    |
| Navidrome                                 | Home       | native, forward-auth         | exists            | The forward-auth contract shape                                                                 |
| **SFTPGo** (web client, WebDAV, SFTP)     | Home + Dev | native, OIDC + app passwords | **new**           | Replaces shares (principle 6); the "add an app" proof; establishes the SSO app-password pattern |

**File access: SFTPGo with SSO end to end.** SFTPGo stores plain files on the
dataset (readable without the app), ships as a NixOS module, and serves a web
client, WebDAV and SFTP from one binary. Every path authenticates against the
same Authentik identity:

| Client                                    | Authentication                                                                                                                                                                                                                                                                            |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Web client                                | OIDC against Authentik; SFTPGo's pre-login hook creates or updates the matching SFTPGo user from the claims (home directory, quota and permissions from Authentik groups)                                                                                                                 |
| WebDAV (OS file managers, mobile, rclone) | **SSO-bound app passwords:** the user creates a per-device app password in the Authentik user settings (behind MFA); SFTPGo's external auth hook verifies username + app password against Authentik's token endpoint (`client_credentials` grant) and caches the result for a few minutes |
| SFTP                                      | Same app-password check; SSH keys optionally from the Authentik user profile                                                                                                                                                                                                              |

Consequences: one identity for every client; revoking a device is deleting its
app password; disabling a user in Authentik ends WebDAV access within the cache
window. The pattern is a **platform capability**, not an SFTPGo special case —
the app contract gains `identity.mode = "app-password"` for any non-OIDC
protocol client. To verify in the Phase 0 spike: Authentik accepts app passwords
of regular (non-service) users in the `client_credentials` grant, and SFTPGo's
external auth hook covers WebDAV logins (the check-password hook does; fallback:
Authentik's LDAP outpost with an SFTPGo LDAP auth plugin).

Considered and not chosen: OpenCloud (sync clients, but heavier and a non-plain
default storage layout), copyparty (unconventional configuration), Seafile
(chunked storage — data not readable without it).

**After 1.0** (in rough order): a wiki (Outline or BookStack), hosted agent
workspaces (§2.5), Paperless-ngx, a lightweight task/project tool (Vikunja), an
optional Jenkins controller for existing pipelines. Apps behind an SSO paywall
(n8n, Plane, OpenProject per §2.4) wait for a clear need.

### 6.7. Code hygiene: no logic in Nix strings

Nix modules declare _what_ runs; anything executed on the host is a real file in
the repository.

- **Scripts are files.** Every host-side script lives next to its module as
  `<name>.sh` with a shebang, is covered by the repo-wide shellcheck lint, and
  is packaged with `pkgs.writeShellApplication` (`runtimeInputs` for its tools;
  the builder adds strict mode and runs shellcheck again at build time). The
  module materializes it as a systemd oneshot, service or timer.
- **Parameters go in through the environment or arguments**, never through Nix
  interpolation into script text: unit `environment`, `EnvironmentFile`,
  `LoadCredential` or command-line arguments — the pattern `converge.nix`
  already uses.
- **Config is generated from data, not templated:** Caddy config from the app
  registry as structured Nix rendered to JSON (or one small Caddyfile renderer),
  compose files as repository files, env files assembled by a script from
  parameters.
- **One-liners stay inline** (a single `ExecStart`/`ExecStartPre` command);
  option descriptions are prose and unaffected.
- **Enforced by lint:** a check in `nix run .#lint` flags multi-line
  `script`/`preStart`/`postStart` strings and shell-heavy `''…''` blocks in the
  homelab modules beyond a small line threshold.
- **Testable in isolation:** scripts with real logic (backup dumps, converge
  fragments) get fixture-based tests next to the VM test.

### 6.8. Repository split

Implemented: this repository holds the product (`nixosModules.default`,
provisioning apps, the demo instance and VM test); instances are separate
repositories that consume it — see the README, "Instances".

## 7. Refactoring Roadmap

Each phase leaves the family host working; the VM test stays green throughout.

### Phase 0 — Decide (no code)

- Settle naming and license.
- Talk to the Selfhostblocks maintainer about contract compatibility and a
  compose provider upstream (§4).
- Spike Clan for an afternoon: can its install, secrets ("vars") and backup
  interface replace `bootstrap.sh`, `fetch-secrets.sh` and the escrow ritual?
- Spike the SFTPGo + Authentik app-password path on a test VM (§6.6).

### Phase 1a — Repository split

Done (§6.8). Open remainder: one deploy of the family host from the split
configuration, and a run of the VM boot test on KVM hardware.

### Phase 1 — Internal modularization (behavior-preserving, in `oduna`)

- Done: app registry with `identity.enable` (`modules/homelab.nix`, C1),
  generated Caddy vhosts and single-sourced ports (`modules/ingress.nix`, C2),
  registry-driven backups (`modules/backups.nix`,
  `modules/backups/backup-databases.sh`, C3) and `mkComposeStack`
  (`modules/compose-stack`, C12); shell in script files with a lint
  (`tools/lint.sh`, C15), `homelab-converge` split into per-app fragments
  (`modules/converge`, C4) and the family literals as instance settings
  (`homelab.instance`, `homelab.identity.userGroup`, C11).
- **Milestone — restore drill:** rebuild the family instance from Git on
  different hardware (spare box or VM), restore the backups, log in via SSO.
  This is the proof of the mission and gates everything after Phase 1. Prepared:
  the procedure and its open points are in `docs/restore-drill.md`; the drill
  itself is pending.

### Phase 2 — Instance model

- Product flake exports `nixosModules`, `lib.mkInstance`, instance template
  (C7).
- `instance.toml` data file validated by the schema; the family instance
  migrates to it.
- Rename to the `oduna` namespace (`oduna.*` options, flake outputs) and a
  neutral host attribute.

### Phase 3 — Storage and file access

- SFTPGo on the contract: OIDC web client, WebDAV/SFTP via SSO-bound app
  passwords, `identity.mode = "app-password"` as a reusable contract mode (C14).
- ZFS replication to a second box or companion VPS; UPS integration.
- Disk-replacement and pool-expansion runbooks driven from the instance config.

### Phase 4 — Providers and profiles

- TLS via `security.acme` DNS-01 with selectable DNS provider (C5).
- Access adapter: mesh first with NetBird Cloud as default, automated mesh DNS
  records, opt-in public exposure through the mesh edge, per-app LAN exception.
- Mesh provider adapters: NetBird (cloud or a control plane the user hosts
  elsewhere) and Tailscale/Headscale; the box only runs the client.
- Backup target adapter: restic (S3/SFTP) next to Borg; alerting via SMTP +
  generic webhooks.
- `companion-mesh` profile with storage adapter `plain`; VM test per profile
  (C6).

### Phase 5 — Identity productization

- Authentik blueprints generated from the registry; converge reduced to per-app
  fragments (C4).
- Enrollment flow: email verification, domain allowlist / invites, default
  groups, per-app access policies.
- Break-glass redesign: per-app generated credentials in the recovery kit (C10);
  keep the shared-password mode as an option for households.

### Phase 6 — Lifecycle automation

- Pull-based update agent with maintenance window, health gate, rollback, report
  (C8).
- Release channels and CI on the product repo: per-app tests, profile tests,
  upgrade test (previous release + data → new release).
- Renovate for compose image digests and flake inputs.

### Phase 7 — Install experience

- Installer CLI/TUI (wizard → instance repo → secrets → nixos-anywhere, evaluate
  Skarabox) with burn-in checks (C9).
- Recovery kit generation; restore mode.
- Installer ISO with LAN web wizard for physical hardware.

### Phase 8 — Catalog and roles

- `runner` host role (Forgejo runners, Jenkins agents) (C13).
- Dev pack: Jenkins controller or Woodpecker, wiki, PM tool, error tracking.
- Post-1.0 catalog per §6.6.
- Agent workbench: workspace image, thin per-user spawner, forge background
  worker workflows (review, issue-to-PR) on the runner role (§2.5).
- Office pack: Paperless-ngx, automation (n8n behind forward-auth or an
  SSO-capable alternative).
- "Add an app" guide + module template + generic contract test.

### Phase 9 — Community

- Public docs, instance template walkthrough, "add an app" guide.
- One or two friendly external instances; their feedback drives the catalog.
- Multi-instance view (update channel, health, backup and restore-drill status)
  for people running several instances, e.g. family plus friends.

## 8. Decisions and Open Questions

### 8.1. Decisions

| Topic               | Decision                                                                                                                                                 |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project model       | Open source, no business plan; own use first (§3)                                                                                                        |
| Name                | Oduna (_ōd_ "owned estate" + _tūn_ "homestead"); Odoma as reserve (§1)                                                                                   |
| License             | MIT; DCO sign-off, no CLA (§1)                                                                                                                           |
| Pilots              | No work pilot; one or two friendly external instances after Phase 2                                                                                      |
| Selfhostblocks      | Not forked; app contract stays API-compatible with SHB contracts and the nixpkgs RFC; no SHB (AGPL) code copied (§4)                                     |
| NAS import          | No import tooling; migration is copying datasets                                                                                                         |
| File access         | Web UI, sync clients and WebDAV, all behind SSO; no SMB/NFS shares (principle 6)                                                                         |
| File app            | SFTPGo: OIDC web client, WebDAV/SFTP via Authentik app passwords (§6.6)                                                                                  |
| Access model        | Mesh first, also inside the LAN; public exposure opt-in via the mesh edge; LAN-only as a per-app exception                                               |
| Mesh provider       | External control plane only: NetBird Cloud by default, or Headscale/self-hosted NetBird run elsewhere; control plane on the box is a future topic (§6.3) |
| Instance repo       | User's choice; template default: own Forgejo primary + external push mirror; recovery never depends on the box's own Forgejo                             |
| LLM infrastructure  | Not part of the platform; model access external (§2.5)                                                                                                   |
| Agent workbench     | OpenCode-first, agent-agnostic image; interactive workspace + forge background worker (§2.5)                                                             |
| Version 1.0 catalog | Today's apps on the contract plus SFTPGo (§6.6)                                                                                                          |
| Code hygiene        | No logic in Nix strings: scripts as lintable files packaged with `writeShellApplication`, config generated from data (§6.7)                              |

### 8.2. Open questions

None at the moment — next step is Phase 0 (§7).

### 8.3. Future topics (out of scope for now)

- **Mesh control plane on the box** (with a relay on a companion VPS): needs a
  break-glass path into a broken box from outside before it is viable.
