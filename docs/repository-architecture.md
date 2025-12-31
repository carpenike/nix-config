# Repository Architecture

**Last Updated**: 2025-12-31

This document describes the high-level architecture of the NixOS configuration repository, including directory structure, module patterns, and key design decisions.

---

## Directory Structure

```
nix-config/
├── flake.nix              # Flake entry point
├── flake.lock             # Locked dependencies
│
├── lib/                   # Shared library functions
│   ├── default.nix        # Exports mylib (types, helpers, etc.)
│   ├── types.nix          # Compatibility wrapper → types/default.nix
│   ├── types/             # Shared type definitions (split by concern)
│   │   ├── default.nix    # Re-exports all types
│   │   ├── reverse-proxy.nix
│   │   ├── metrics.nix
│   │   ├── backup.nix
│   │   └── ...            # logging, storage, container, etc.
│   ├── host-defaults.nix  # Parameterized factory for host-specific defaults
│   ├── monitoring-helpers.nix  # Prometheus alert helpers
│   ├── backup-helpers.nix      # Backup configuration helpers
│   ├── caddy-helpers.nix       # Reverse proxy helpers
│   ├── mkSystem.nix       # NixOS/Darwin system builders
│   └── ...
│
├── modules/               # Reusable NixOS/Darwin modules
│   ├── common/            # Shared between NixOS and Darwin
│   ├── darwin/            # macOS-specific modules
│   └── nixos/             # NixOS-specific modules
│       ├── services/      # Service modules (caddy, sonarr, etc.)
│       ├── storage/       # ZFS, NFS, dataset management
│       ├── backup.nix     # Backup system
│       ├── alerting.nix   # Prometheus alerting rules
│       └── impermanence.nix  # ZFS root rollback
│
├── hosts/                 # Host-specific configurations
│   ├── forge/             # Primary homelab server (two-disk)
│   │   ├── core/          # OS-level concerns (boot, network, users)
│   │   ├── infrastructure/# Cross-cutting (storage, backup, observability)
│   │   ├── services/      # Application configs
│   │   └── lib/defaults.nix  # Host-specific defaults wrapper
│   ├── luna/              # Secondary server (single-disk, impermanent)
│   └── ...
│
├── home/                  # Home Manager configurations
├── profiles/              # Reusable configuration profiles
├── pkgs/                  # Custom packages
├── overlays/              # Nixpkgs overlays
└── docs/                  # Documentation
    └── adr/               # Architecture Decision Records
```

---

## Core Concepts

### 1. The `mylib` Pattern

All shared library functions are exposed via `mylib`, injected into every module via `_module.args`:

```nix
# In lib/default.nix
{
  types = import ./types.nix { inherit lib; };
  storageHelpers = pkgs: import ../modules/nixos/storage/helpers-lib.nix { inherit pkgs lib; };
  # ...
}

# In any module
{ lib, mylib, pkgs, ... }:
let
  sharedTypes = mylib.types;
  storageHelpers = mylib.storageHelpers pkgs;  # Note: requires pkgs argument
in
{ ... }
```

**Benefits**:
- No relative path calculations
- Single import point
- Available everywhere automatically

### 2. Three-Tier Host Architecture

Hosts like `forge` use a layered organization:

| Layer | Directory | Purpose | Examples |
|-------|-----------|---------|----------|
| **Core** | `core/` | OS fundamentals | boot, networking, users, packages |
| **Infrastructure** | `infrastructure/` | Cross-cutting platforms | storage, backup, observability, reverse-proxy |
| **Services** | `services/` | Application configs | sonarr.nix, plex.nix, postgresql.nix |

**Key Principle**: Configuration and monitoring are co-located. A service file contains its config, storage datasets, backup policies, and alerts.

### 3. Contributory Pattern

Services declare their infrastructure needs; infrastructure modules aggregate contributions:

```nix
# Service module declares what it needs
modules.services.caddy.virtualHosts.sonarr = { ... };
modules.alerting.rules."sonarr-down" = { ... };
modules.backup.sanoid.datasets."tank/services/sonarr" = { ... };

# Infrastructure modules aggregate all contributions
# (Caddy module collects all virtualHosts, alerting module collects all rules)
```

**Used by**: Caddy, backup/Sanoid, alerting, Gatus, Grafana datasources, impermanence

### 4. Host-Level Defaults

Each host has a defaults library that provides host-specific values:

```nix
# hosts/forge/lib/defaults.nix
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
in
{
  # Standard backup config
  backup = forgeDefaults.backup;

  # Alert helpers
  mkServiceDownAlert = forgeDefaults.mkServiceDownAlert;

  # ZFS replication
  mkSanoidDataset = forgeDefaults.mkSanoidDataset;
}
```

The actual logic lives in `lib/host-defaults.nix` - hosts just provide their specific parameters (pool names, replication targets, etc.).

---

## Module Patterns

### Service Module Structure

Every service module follows this pattern:

```nix
{ lib, mylib, config, pkgs, ... }:
let
  cfg = config.modules.services.myservice;
  sharedTypes = mylib.types;
in
{
  options.modules.services.myservice = {
    enable = lib.mkEnableOption "myservice";

    # Service-specific options
    dataDir = lib.mkOption { ... };
    port = lib.mkOption { ... };

    # Standardized submodules (from shared types)
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
    };
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
    };
  };

  config = lib.mkIf cfg.enable {
    # Service implementation
    # Contributions to infrastructure (Caddy, backup, alerts)
  };
}
```

### Shared Types

Common submodule types are defined in `lib/types.nix`:

- `reverseProxySubmodule` - Caddy reverse proxy configuration
- `backupSubmodule` - Restic backup configuration
- `metricsSubmodule` - Prometheus metrics collection
- `loggingSubmodule` - Log shipping configuration
- `notificationSubmodule` - Alert notification channels

### Storage Helpers

Complex storage logic is centralized in `modules/nixos/storage/helpers-lib.nix`:

- `mkReplicationConfig` - Walks ZFS dataset tree to find inherited replication config
- `mkNfsMountConfig` - Resolves NFS mount dependencies
- `mkPreseedService` - Creates disaster recovery preseed services

---

## Host Architecture Differences

| Aspect | Forge (two-disk) | Luna (single-disk) |
|--------|------------------|-------------------|
| **Root pool** | `rpool` (impermanent) | `rpool` (impermanent) |
| **Service data** | `tank/services/*` (persistent) | `/persist/var/lib/*` (bind-mount) |
| **Storage method** | ZFS datasets | Impermanence module |
| **Persistence config** | `modules.storage.datasets` | `modules.system.impermanence.directories` |

**Key insight**: Service modules are agnostic to storage architecture. Hosts decide how persistence is implemented.

---

## Import Flow

```
flake.nix
    │
    ├── lib/mkSystem.nix
    │       │
    │       ├── modules/nixos/default.nix  (all NixOS modules)
    │       │       ├── services/*.nix
    │       │       ├── storage/*.nix
    │       │       └── ...
    │       │
    │       └── hosts/<hostname>/default.nix
    │               ├── core/*.nix
    │               ├── infrastructure/*.nix
    │               └── services/*.nix
    │
    └── lib/default.nix → mylib (injected via _module.args)
```

---

## Design Decisions

Key architectural decisions are documented in `docs/adr/`:

- [ADR-001: Contributory Infrastructure Pattern](./adr/001-contributory-infrastructure-pattern.md)
- [ADR-002: Host-Level Defaults Library](./adr/002-host-level-defaults-library.md)
- [ADR-003: Shared Types for Service Modules](./adr/003-shared-types-for-service-modules.md)
- [ADR-004: Impermanence Host-Level Control](./adr/004-impermanence-host-level-control.md)

---

## Quick Reference

### Adding a New Service

1. Create module in `modules/nixos/services/<name>/default.nix`
2. Use `mylib.types` for standardized options
3. Contribute to infrastructure (Caddy, backup, alerts)
4. Add host config in `hosts/<host>/services/<name>.nix`

### Adding Persistence (Luna)

```nix
# In hosts/luna/default.nix
modules.system.impermanence.directories = [
  "/var/lib/myservice"
];
```

### Adding ZFS Dataset (Forge)

```nix
# In hosts/forge/services/myservice.nix
modules.storage.datasets.services.myservice = {
  mountpoint = "/var/lib/myservice";
  recordsize = "16K";
};
```

### Using Host Defaults

```nix
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
in
{
  modules.backup.sanoid.datasets."tank/services/myservice" =
    forgeDefaults.mkSanoidDataset "myservice";
}
```

---

## Related Documentation

- [Modular Design Patterns](./modular-design-patterns.md) - Detailed module patterns
- [Monitoring Strategy](./monitoring-strategy.md) - Black-box vs white-box monitoring
- [Backup System Onboarding](./backup-system-onboarding.md) - Backup configuration
