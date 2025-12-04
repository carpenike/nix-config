# Custom Package Patterns for NixOS

**Last Updated**: 2024-12-04

This document covers patterns for creating, maintaining, and automating custom packages in this NixOS configuration. For Darwin/macOS package management, see `package-management-strategy.md`.

## Table of Contents

- [Overview](#overview)
- [Package Architecture](#package-architecture)
- [nvfetcher: Automated Source Updates](#nvfetcher-automated-source-updates)
- [Custom Package Files](#custom-package-files)
- [Hash Update Strategies](#hash-update-strategies)
- [CI/CD Automation](#cicd-automation)
- [Decision Framework](#decision-framework)
- [Troubleshooting](#troubleshooting)

---

## Overview

This repository uses several patterns for custom packages:

| Pattern | Use Case | Examples |
|---------|----------|----------|
| **nvfetcher** | Rust/Go packages with frequent releases | cooklang-cli, talhelper, attic-client |
| **Standalone package file** | Complex builds, plugins, Go modules | caddy-custom.nix |
| **Inline overlay** | Simple version pins or patches | Rare, discouraged |
| **Flake inputs** | External flakes with packages | home-manager, nixvim |

---

## Package Architecture

```
pkgs/
├── _sources/           # nvfetcher generated (DO NOT EDIT)
│   └── generated.nix   # Auto-generated source definitions
├── nvfetcher.toml      # nvfetcher configuration
├── caddy-custom.nix    # Standalone package (Caddy with plugins)
├── cooklang-cli.nix    # Uses nvfetcher sourceData
├── cooklang-federation.nix
├── talhelper.nix
└── default.nix         # Package set aggregator

overlays/
└── default.nix         # Imports from pkgs/, applies to nixpkgs
```

---

## nvfetcher: Automated Source Updates

### What is nvfetcher?

[nvfetcher](https://github.com/berberman/nvfetcher) tracks upstream releases and generates Nix source definitions. It handles:
- GitHub releases and tags
- Version extraction
- Source hash calculation
- Automatic PR creation via GitHub Actions

### When to Use nvfetcher

✅ **Good candidates:**
- Rust packages (Cargo-based builds)
- Go packages with simple build
- Packages with frequent GitHub releases
- Packages where only the source version changes

❌ **Not suitable for:**
- Packages with Go module plugins (e.g., Caddy)
- Packages requiring complex build customization
- Packages where you need control over plugin versions

### Configuration

Add packages to `pkgs/nvfetcher.toml`:

```toml
# Rust package from GitHub releases
[cooklang-cli]
src.github = "cooklang/cooklang-rs"
src.github_tag = "v.*"       # Match tags like v0.10.0
fetch.github = "cooklang/cooklang-rs"

# Go package from GitHub releases
[talhelper]
src.github = "budimanjojo/talhelper"
fetch.github = "budimanjojo/talhelper"

# Package with specific tag pattern
[attic-client]
src.github = "zhaofengli/attic"
src.github_tag = "v.*"
fetch.github = "zhaofengli/attic"
```

### Using nvfetcher in Package Files

```nix
# pkgs/cooklang-cli.nix
{ lib, rustPlatform, darwin, stdenv }:

let
  # Import generated source data
  sourceData = (import ./_sources/generated.nix {
    inherit (import <nixpkgs> {}) fetchurl fetchgit fetchFromGitHub dockerTools;
  }).cooklang-cli;
in
rustPlatform.buildRustPackage {
  pname = "cooklang-cli";
  version = sourceData.version;
  src = sourceData.src;

  # IMPORTANT: cargoHash must be updated manually when source changes
  cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  meta = with lib; {
    description = "CLI for Cooklang recipe markup language";
    homepage = "https://github.com/cooklang/cooklang-rs";
    license = licenses.mit;
    maintainers = [ ];
  };
}
```

### Running nvfetcher Manually

```bash
# Update all sources
cd pkgs && nvfetcher

# Update specific package
cd pkgs && nvfetcher -f cooklang-cli

# Check what would change (dry-run)
cd pkgs && nvfetcher --dry-run
```

---

## Custom Package Files

### When to Use Standalone Package Files

Create a dedicated `pkgs/<name>.nix` when:
- Package has complex build requirements
- Package uses plugins or extensions (like Caddy)
- You need fine-grained control over dependencies
- Package doesn't fit nvfetcher pattern

### Caddy with Plugins Example

```nix
# pkgs/caddy-custom.nix
{ pkgs }:

# Caddy with custom plugins using NixOS 25.05+ withPlugins
# Plugin versions managed via Renovate comments
pkgs.caddy.withPlugins {
  plugins = [
    # renovate: datasource=go depName=github.com/caddy-dns/cloudflare
    "github.com/caddy-dns/cloudflare@v0.2.1"
    # renovate: datasource=go depName=github.com/greenpau/caddy-security
    "github.com/greenpau/caddy-security@v1.1.31"
  ];
  # This hash covers the Go module download
  hash = "sha256-O9jSQT3pPqfvuFbZry5/f/KiHIod5I/FOfLpyli8oa4=";
}
```

### Registering in Overlay

```nix
# overlays/default.nix
final: prev: {
  # Import standalone package
  caddy = import ../pkgs/caddy-custom.nix { pkgs = prev; };

  # Or define inline (discouraged for complex packages)
  simple-tool = prev.simple-tool.override { ... };
}
```

---

## Hash Update Strategies

### Understanding Nix Hashes

Nix packages use content-addressed hashes for reproducibility:

| Hash Type | Purpose | When It Changes |
|-----------|---------|-----------------|
| `hash` / `sha256` | Source archive hash | Source version changes |
| `cargoHash` | Rust Cargo.lock dependencies | Rust deps change |
| `vendorHash` | Go module dependencies | Go deps change |
| `npmDepsHash` | NPM dependencies | package-lock.json changes |

### Using nix-update

[nix-update](https://github.com/Mic92/nix-update) is the recommended tool for updating package hashes:

```bash
# Update a package (auto-detects hash types)
nix-update --flake cooklang-cli

# Update with specific version
nix-update --flake cooklang-cli --version 0.10.0

# Commit the changes automatically
nix-update --flake cooklang-cli --commit
```

**What nix-update handles:**
- Detects and updates `cargoHash`, `vendorHash`, `npmDepsHash`
- Calculates correct replacement hashes
- Works with packages in `pkgs/` directory

### Manual Hash Update (Fallback)

When nix-update doesn't work:

```bash
# 1. Set hash to empty string to trigger error
cargoHash = "";

# 2. Build to get correct hash
nix build .#cooklang-cli
# error: hash mismatch... got: sha256-ABC123...

# 3. Update with correct hash
cargoHash = "sha256-ABC123...";
```

---

## CI/CD Automation

### GitHub Actions Workflow

The `.github/workflows/update-nvfetcher.yml` workflow runs daily:

```yaml
name: Update nvfetcher sources

on:
  schedule:
    - cron: '0 5 * * *'  # Daily at 5 AM UTC
  workflow_dispatch:      # Manual trigger

jobs:
  update-sources:
    steps:
      # 1. Run nvfetcher to update sources
      - run: cd pkgs && nvfetcher

      # 2. Detect which packages changed
      - run: |
          # Parse nvfetcher.toml for package names
          # Check git diff for changes

      # 3. Fix hashes with nix-update
      - run: |
          for pkg in $CHANGED_PACKAGES; do
            nix run nixpkgs#nix-update -- --flake "$pkg" || true
          done

      # 4. Create PR with changes
      - uses: peter-evans/create-pull-request@v7
```

### Renovate Integration

For packages not using nvfetcher (like Caddy plugins), use Renovate comments:

```nix
plugins = [
  # renovate: datasource=go depName=github.com/caddy-dns/cloudflare
  "github.com/caddy-dns/cloudflare@v0.2.1"
];
```

Renovate will:
1. Detect the version from the comment
2. Check for new releases
3. Create PRs to update versions

**Note:** Renovate updates the version, but you must manually update the `hash`.

---

## Decision Framework

### New Package Flowchart

```
Need a custom package?
│
├─ Is it available in nixpkgs?
│   └─ YES → Use nixpkgs, maybe with overlay for patches
│
├─ Is it a Rust/Go package with simple build?
│   └─ YES → Use nvfetcher + package file
│
├─ Does it need plugins/extensions?
│   └─ YES → Standalone package file (like caddy-custom.nix)
│
├─ Is there a flake input available?
│   └─ YES → Add to flake.nix inputs
│
└─ None of the above?
    └─ Create standalone package in pkgs/
```

### Package Location Guidelines

| Scenario | Location | Reason |
|----------|----------|--------|
| Simple override | `overlays/default.nix` | Minimal, self-contained |
| New package | `pkgs/<name>.nix` | Separation of concerns |
| Package with plugins | `pkgs/<name>.nix` | Complex, needs dedicated file |
| nvfetcher-managed | `pkgs/<name>.nix` + `nvfetcher.toml` | Automated updates |

---

## Troubleshooting

### nvfetcher Issues

**"Package not found in generated.nix"**
```bash
# Regenerate sources
cd pkgs && nvfetcher

# Check for TOML syntax errors
cat pkgs/nvfetcher.toml | tomllint
```

**"Hash mismatch after nvfetcher update"**
```bash
# nvfetcher updates source, but cargoHash/vendorHash need manual update
nix run nixpkgs#nix-update -- --flake <package-name>
```

### Hash Calculation

**"Got sha256-... but expected sha256-..."**
```bash
# Copy the "got" hash from error message
# Update the hash in your package file
# Rebuild to verify
```

**"cargoHash changed unexpectedly"**
- Upstream Cargo.lock changed
- Rust toolchain version mismatch
- Check if nixpkgs Rust version matches upstream expectations

### Build Failures

**Go package: "missing go.sum entry"**
```bash
# Vendor hash is stale, update with:
nix run nixpkgs#nix-update -- --flake <package-name>
```

**Caddy plugins: "module not found"**
```bash
# Plugin version incompatible with Caddy version
# Check plugin compatibility matrix
# Update plugin version in caddy-custom.nix
```

---

## Related Documentation

- `package-management-strategy.md` - Darwin/macOS package management
- `container-image-management.md` - Container image versioning
- `.github/workflows/update-nvfetcher.yml` - CI automation source

---

## Revision History

- **2025-12-04**: Initial document created
  - Consolidated nvfetcher patterns from session work
  - Added caddy-custom.nix pattern documentation
  - Documented nix-update for hash management
  - Added CI/CD automation section
