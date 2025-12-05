<h1 align="center">🏠 Home Manager Configuration</h1>

<p align="center">
  <em>User environment and dotfiles management</em>
</p>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Directory Structure](#-directory-structure)
- [Module Categories](#-module-categories)
- [Per-Host Overrides](#-per-host-overrides)
- [Adding New Modules](#-adding-new-modules)

---

## 🔍 Overview

This directory contains [Home Manager](https://github.com/nix-community/home-manager) configurations for user environments. The structure separates reusable modules (`_modules/`) from user-specific configurations (`ryan/`).

---

## 📁 Directory Structure

```
home/
├── _modules/           # Reusable Home Manager modules
│   ├── default.nix     # Module aggregator
│   ├── deployment/     # Deployment tooling (kubectl, terraform, etc.)
│   ├── development/    # Dev tools and languages
│   ├── editor/         # Neovim, VS Code configuration
│   ├── infrastructure/ # Infrastructure management tools
│   ├── kubernetes/     # K8s tooling and configs
│   ├── mutability.nix  # Mutable file management
│   ├── security/       # SSH, GPG, secrets
│   ├── shell/          # Fish, Git, terminal utilities
│   ├── themes/         # Catppuccin and other themes
│   └── utilities/      # General utilities
│
└── ryan/               # User-specific configuration
    ├── default.nix     # Base user config
    ├── config/         # User config files (dotfiles)
    └── hosts/          # Per-host overrides
        ├── forge.nix
        ├── luna.nix
        ├── rymac.nix
        └── ...
```

---

## 🧩 Module Categories

### `deployment/`
CI/CD and deployment tooling configurations.

### `development/`
Programming languages, LSPs, and development environments.

### `editor/`
Text editor configurations (Neovim, VS Code, etc.).

### `infrastructure/`
Tools for infrastructure management (Ansible, Packer, etc.).

### `kubernetes/`
Kubernetes CLI tools, kubeconfig management, and cluster utilities.

### `security/`
SSH key management, GPG configuration, and secrets handling.

### `shell/`
Shell configuration including:
- **Fish** — Primary shell with custom functions
- **Git** — Version control with signing
- **Terminal utilities** — tmux, starship, etc.

### `themes/`
Theming across applications:
- **Catppuccin** — Unified color scheme (macchiato flavor)

### `utilities/`
General-purpose utilities and helper applications.

---

## 🖥️ Per-Host Overrides

Each host can have specific configurations in `ryan/hosts/<hostname>.nix`:

```nix
# ryan/hosts/rymac.nix
{ ... }:
{
  modules = {
    development.enable = true;     # Enable dev tools on workstation
    kubernetes.enable = true;      # K8s tooling for cluster management
  };
}
```

### Host Files

| File | Host Type | Notes |
|------|-----------|-------|
| `forge.nix` | NixOS server | Primary homelab server |
| `luna.nix` | NixOS server | Minimal server config |
| `rymac.nix` | macOS (nix-darwin) | Full development workstation |
| `rydev.nix` | Development VM | Dev environment |
| `nixos-bootstrap.nix` | Installer | Bootstrap configuration |

---

## ➕ Adding New Modules

### 1. Create Module File

```nix
# _modules/mymodule/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.mymodule;
in
{
  options.modules.mymodule = {
    enable = lib.mkEnableOption "my module";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.mytool ];
  };
}
```

### 2. Import in Module Aggregator

```nix
# _modules/default.nix
{
  imports = [
    ./mymodule
    # ... other modules
  ];
}
```

### 3. Enable in User Config

```nix
# ryan/hosts/rymac.nix
{
  modules.mymodule.enable = true;
}
```

---

## 🎨 Theming

The Catppuccin theme is applied consistently across:
- Terminal emulators
- Neovim
- Fish shell
- Git delta
- bat
- And more...

Configuration in base user config:

```nix
# ryan/default.nix
modules.themes.catppuccin = {
  enable = true;
  flavor = "macchiato";
};
```

---

## 🔗 Integration with NixOS

Home Manager is integrated via the NixOS module system. User configurations are applied during system activation:

```nix
# In host configuration
home-manager.users.ryan = import ../../home/ryan {
  hostname = "forge";
};
```
