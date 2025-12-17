# Flake Input Management

This document describes how flake inputs are managed, updated, and pinned in this repository.

## Input Overview

| Input | Branch/Version | Purpose | Follows nixpkgs? |
|-------|---------------|---------|------------------|
| `nixpkgs` | nixos-25.11 | Stable packages for hosts | - |
| `nixpkgs-unstable` | nixos-unstable | Bleeding-edge packages via overlay | No |
| `home-manager` | release-25.11 | User environment management | Yes |
| `nix-darwin` | nix-darwin-25.11 | macOS system configuration | Yes |
| `hardware` | latest | NixOS hardware profiles | No (pure module) |
| `flake-parts` | latest | Flake structure | Yes (nixpkgs-lib) |
| `disko` | latest | Declarative partitioning | Yes |
| `sops-nix` | latest | Secret management | Yes |
| `nixvim` | latest | Neovim configuration | Yes |
| `nix-vscode-extensions` | latest | VSCode extensions | Yes |
| `nixos-vscode-server` | latest | Remote SSH server | Yes |
| `rust-overlay` | latest | Rust toolchain | Yes |
| `catppuccin` | v1.0.2 | Theme (pinned) | No (pure module) |
| `impermanence` | latest | ZFS root rollback | No (pure module) |
| `nix-inspect` | latest | TUI inspector | Yes |
| `beads` | latest | AI issue tracker | Yes |

### Input Categories

**Stable Branch Inputs**: `nixpkgs`, `home-manager`, `nix-darwin`
- Pinned to NixOS release branches (currently 25.11)
- Provides stable, tested packages
- Updated when new NixOS release occurs

**Unstable Inputs**: `nixpkgs-unstable`
- Tracks nixos-unstable for bleeding-edge packages
- Accessed via `pkgs.unstable.*` overlay (see `overlays/default.nix`)
- Use sparingly for packages needing latest versions

**Pure Module Flakes**: `hardware`, `catppuccin`, `impermanence`
- Don't depend on nixpkgs (pure Nix modules)
- No `follows` needed

**Utility Flakes**: Everything else
- Follow `nixpkgs` to ensure consistent package versions
- Reduces closure size and evaluation time

## Update Workflow

### Automated Weekly Updates

A GitHub Actions workflow updates all inputs weekly:

- **Schedule**: Every Sunday at midnight UTC
- **Workflow**: `.github/workflows/update-flake-lock.yml`
- **Process**:
  1. Runs `nix flake lock --update-input` for all inputs
  2. Creates PR with title "chore(deps): Update flake.lock"
  3. Runs `nix flake check --no-build` to verify evaluation
  4. Auto-merges if checks pass

### Manual Updates

Use Taskfile commands for manual updates:

```bash
# Update all flake inputs
task nix:update

# Update specific input only
task nix:update input=nixpkgs
task nix:update input=home-manager

# Direct nix command (alternative)
nix flake lock --update-input nixpkgs
```

### Pre-deployment Validation

Before deploying updated inputs:

```bash
# Full validation suite
task nix:validate

# Build without deploying
task nix:build-nixos host=forge
task nix:build-darwin host=macbook
```

## Version Pinning Strategy

### Why Pin Versions?

1. **Reproducibility**: Same `flake.lock` = same system
2. **Stability**: Tested combinations of packages
3. **Rollback**: Git history enables instant rollback
4. **CI/CD**: Builds are deterministic

### Pinning Rules

| Category | Strategy | Example |
|----------|----------|---------|
| Core (nixpkgs, HM) | Release branch | `nixos-25.11` |
| Theme/style | Exact version | `catppuccin` at `v1.0.2` |
| Utilities | Latest + follows | `sops-nix` follows nixpkgs |
| Hardware | Latest | No nixpkgs dependency |

### When to Pin Exact Versions

Pin to exact version/commit when:
- Breaking changes are frequent
- Specific version has required fix
- Upstream is unstable

Example pinned input:
```nix
catppuccin = {
  url = "github:catppuccin/nix/v1.0.2";  # Pinned tag
};
```

## Rollback Procedure

### Quick Rollback (Last Known Good)

```bash
# Revert flake.lock to previous commit
git checkout HEAD~1 -- flake.lock

# Rebuild with reverted lock
task nix:apply-nixos host=forge
```

### Rollback to Specific Date

```bash
# Find commit from specific date
git log --oneline --until="2025-12-01" -- flake.lock | head -5

# Checkout that version
git checkout <commit-hash> -- flake.lock

# Rebuild
task nix:apply-nixos host=forge
```

### Emergency: Boot Previous Generation

If a bad update breaks the system:

1. Reboot and select previous generation from boot menu
2. Once booted, revert the flake.lock:
   ```bash
   cd /etc/nixos  # or wherever config lives
   git checkout HEAD~1 -- flake.lock
   sudo nixos-rebuild switch
   ```

## Unstable Packages Overlay

Access bleeding-edge packages without switching all of nixpkgs:

```nix
# In overlays/default.nix
unstable-packages = final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (prev) system;
    config.allowUnfree = true;
  };
};

# Usage in modules
{ pkgs, ... }: {
  environment.systemPackages = [
    pkgs.stable-package       # From nixpkgs (stable)
    pkgs.unstable.new-tool    # From nixpkgs-unstable
  ];
}
```

## NixOS Release Upgrades

When upgrading to a new NixOS release (e.g., 25.11 → 26.05):

1. **Update branch references** in `flake.nix`:
   ```nix
   nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
   home-manager.url = "github:nix-community/home-manager/release-26.05";
   nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-26.05";
   ```

2. **Update flake.lock**:
   ```bash
   task nix:update
   ```

3. **Test thoroughly**:
   ```bash
   task nix:validate
   task nix:build-nixos host=forge
   ```

4. **Deploy incrementally**:
   - Test host first
   - Production hosts after validation

## Troubleshooting

### "input X is not in flake.lock"

```bash
# Regenerate lock file
nix flake lock
```

### Evaluation errors after update

```bash
# Check what changed
git diff flake.lock

# Rollback problematic input
git checkout HEAD~1 -- flake.lock
nix flake lock --update-input <other-inputs-to-keep>
```

### Slow evaluation after update

Large nixpkgs updates can slow evaluation. Options:
1. Wait for Cachix to populate
2. Use `--no-eval-cache` to bypass stale cache
3. Run `nix flake check` to warm cache

## Related Documentation

- [Nix Garbage Collection](./nix-garbage-collection.md) - Managing store size
- [Bootstrap Quickstart](./bootstrap-quickstart.md) - New host setup
- [Repository Architecture](./repository-architecture.md) - Overall structure
