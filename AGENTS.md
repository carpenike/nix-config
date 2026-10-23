# AGENTS.md — nix-config

## How changes are made here (Research → Plan → Implement → Review)

**Size the work first.**
- *Small:* a typo, a known one-line fix, a routine bump, or an additive DNS record / DHCP reservation. Implement it and list the checks you ran.
- *Standard:* a bug with an unclear cause, a new feature, or a multi-file change. Confirm the cause first, then write a short plan.
- *High-risk:* firewall, VPN/WireGuard, routing, NAT, interfaces, host config, auth, scopes, data deletion, or anything that could cut off access or is hard to roll back. Write the plan and a self-critique, then stop for approval before you implement.

**Research before you code** whenever the cause isn't proven. Separate evidence (file:line, log or command output) from assumptions. Don't fix the symptom you guessed at.

**Plan notes go in the PR description**, not in files in this repo. Every PR body has these sections:
- **Goal / non-goals**
- **Root cause / evidence** (if it's a fix)
- **Acceptance criteria:** observable, checkable statements
- **Checks run:** each command, where it ran (CI, a local machine, your VM) and its result. A check you couldn't run is listed as `not verified: <reason>`. Never imply it passed.
- **Accepted?** Each acceptance criterion as met or not met, with its evidence. This is separate from "checks run".
- **Rollout / rollback:** deploy steps, ordering with other repos or pins, manual steps, how to undo
- **Decisions:** one line per non-obvious choice, with why and what you rejected
- **Follow-ups:** anything left over

**Rules**
- Open draft PRs and never merge them. Don't push to the default branch.
- Change only what the plan covers. If scope or risk grows, stop and say so in the PR.
- Never commit secrets, tokens, keys, home IPs or private network details. This repo may be public.
- Don't weaken auth, scopes, validation or tests to make something pass, and don't skip hooks or checks.
- Don't hand-edit generated files unless you can rerun the generator. If you can't, say so.
- If CI can't run (for example, it's billing-blocked), run the same checks locally and record them under "Checks run".
- If a check fails on the base branch too, name it as pre-existing.

### This repo
- **Checks** (what `.github/workflows/` runs):
  - `lint.yml`: `nix fmt -- --check .`; `nix build --no-link .#checks.x86_64-linux.{statix,deadnix,renovate-extraction}`; `nix develop --command pre-commit run --all-files` (git-hooks.nix in `flake.nix`: nixpkgs-fmt, statix, deadnix, shellcheck, ruff, ruff-format, yamllint, check-json, check-toml, trailing-whitespace, end-of-file-fixer, gitleaks)
  - `nix-build.yml`: `nix flake check --no-build` plus the per-host `nix build` matrix, gated by path filters
  - Atrium/MCP lanes (`atrium-n04-controller.yml`, `atrium-n06-fixtures.yml`, `homelab-mcp-deployment.yml`): `nix build --builders '' --no-link --no-write-lock-file .#checks.x86_64-linux.<check>`
  - Local: `task nix:validate` (`nix flake check`, or one host with `host=forge`); `task nix:build-nixos host=forge` builds without switching
- **Generated files and how to regenerate them:**
  - `flake.lock`: `task nix:update input=<name>` (`nix flake update <name>`)
  - `pkgs/_sources/generated.{json,nix}`: `cd pkgs && nvfetcher` (see `update-nvfetcher.yml`)
  - `tests/atrium_n03/pins.json` and `tests/atrium_n03/native-vendor-compatibility.json` are edited by hand when pins move and are checked by `tests/atrium_n03/forge-evaluate.nix`. <!-- TODO: confirm there is no generator -->
- **Deploy:** hosts with `modules.autoUpgrade` (Forge included, `hosts/forge/default.nix`) pull `github:carpenike/nix-config` `main` on the default 04:00 schedule (host time; Forge's reboot window is 04:00–05:00). You can apply on demand with `task nix:apply-nixos host=<host>` (runs `scripts/nix-apply-guarded.sh`) or through the on-demand upgrade unit (`modules/nixos/on-demand-upgrade.nix`, triggered by homelab-mcp's `nixos_apply_config`). Applying needs Ryan's approval. App repos dispatch `flake-input-updated`, and `update-flake-input.yml` (allowlist: whiskey-whiskey-whiskey, replog, marginalia, homelab-mcp, coachiq, ambit, lading) opens a gated, auto-merged bump. `update-flake-lock.yml` bumps all inputs weekly (Sunday 00:00 UTC). Those automation PRs auto-merge; agent PRs stay draft.
- **Cross-repo pins this repo affects or depends on:**
  - `homelab-mcp` (carpenike/mcp) and `atrium` are pinned by commit SHA in `flake.nix`. `whiskey-whiskey-whiskey` and `schoolhouse` track their default branch through `flake.lock`.
  - `tests/atrium_n03/pins.json` must match: `atrium` = `inputs.atrium.rev`, `native` = `inputs.homelab-mcp.rev`, `consumer` = `inputs.whiskey-whiskey-whiskey.rev`, and `atrium_native_vendor_source` = homelab-mcp's `vendor/atrium-artifacts.lock.json` revision.
  - `tests/atrium_n03/native-vendor-compatibility.json` `application_revision` / `native_revision` must match the atrium / homelab-mcp revs. Bump them in the same PR as the pin.
- **High-risk paths here:** `hosts/forge/atrium/` (registry, identity, bootstrap/authority JSON), `hosts/forge/services/atrium*.nix`, `hosts/forge/services/homelab-mcp.nix` (restricted scopes), `hosts/forge/services/pocketid.nix`; `.sops.yaml` and every `secrets.sops.yaml`; `modules/nixos/storage/`, `modules/nixos/filesystems/` (ZFS, NFS), `modules/nixos/impermanence.nix`; firewall and networking settings in `hosts/*/`; `modules/nixos/auto-upgrade.nix`, `on-demand-upgrade.nix`, `deployment-guard.nix`, `scripts/nix-apply-guarded.sh`; `flake.nix` / `flake.lock` input pins and `tests/atrium_n03/pins.json`.
- **Other agent instructions:** `.github/copilot-instructions.md` and `.github/instructions/*.md` still apply.
