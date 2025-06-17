# Darwin Package Management Strategy

## Overview

This document outlines the recommended package management strategy for nix-darwin systems, balancing the benefits of Nix's declarative approach with the practical realities of macOS.

## Key Principle: Declarative Everything

The `homebrew.onActivation.cleanup = "zap"` setting enforces strict declarative management. This is a **feature**, not a bug - it ensures your system exactly matches your configuration.

## Package Management Rules

### Use Nix for:
- **All CLI tools and utilities** (ripgrep, sops, go-task, etc.)
- **Development languages and toolchains** (Python, Node.js, Go, Rust)
- **System utilities and infrastructure tools** (terraform, kubectl, helm)
- **Text editors and development environments** (vim, emacs, neovim)

### Use Homebrew (declared in Nix) for:
- **GUI applications** (Discord, Slack, Obsidian, etc.)
- **macOS-specific commercial software** (TablePlus, Transmit)
- **Tools that don't work well in Nix** (certain macOS-only utilities)

## Implementation

### 1. Daily Driver Tools

For tools you use regularly, add them to the appropriate home-manager module:

```nix
# home/_modules/shell/utilities/default.nix
home.packages = with pkgs; [
  ripgrep
  sops
  go-task
  # ... other daily tools
];
```

### 2. Development Languages

For language toolchains you use regularly:

```nix
# home/_modules/development/languages/default.nix
home.packages = with pkgs; [
  python311
  nodejs
  go
  rustup
  # ... other languages
];
```

### 3. GUI Applications

Declare all GUI apps in your homebrew configuration:

```nix
# hosts/_modules/darwin/homebrew.nix or hosts/rymac/default.nix
homebrew.casks = [
  "discord"
  "slack"
  "obsidian"
  # ... other GUI apps
];
```

## Migration Process

1. **Before making changes**, run: `brew list --formula > ~/current-brew-formulae.txt`
2. **Add desired packages** to your Nix configuration
3. **Validate** with: `nix flake check`
4. **Build** with: `darwin-rebuild build --flake .`
5. **Apply** with: `darwin-rebuild switch --flake .`

## Handling Edge Cases

### Packages not in nixpkgs

For tools like `talhelper` that aren't in nixpkgs:
1. Check if there's a flake input available
2. Create a custom package (see pkgs/ directory for examples)
3. As a last resort, add to homebrew.brews

### Darwin-only packages

Use conditional imports for Darwin-specific tools:

```nix
home.packages = with pkgs; [
  # Cross-platform tools
  ripgrep
  sops
] ++ lib.optionals pkgs.stdenv.isDarwin [
  mas  # Mac App Store CLI
];
```

## Benefits of This Approach

1. **Reproducibility**: Your entire system can be rebuilt from configuration
2. **Version Control**: All changes are tracked in git
3. **No Surprises**: System always matches configuration
4. **Easy Rollbacks**: Previous generations are preserved
5. **Team Sharing**: Colleagues can replicate your exact environment

## Common Commands

```bash
# Check what's currently installed via Homebrew
brew list --formula
brew list --cask

# Validate configuration
nix flake check

# Build without applying (safe preview)
darwin-rebuild build --flake .

# Apply configuration
darwin-rebuild switch --flake .

# Rollback to previous generation
darwin-rebuild rollback
```
