# NixOS Homelab Documentation

Welcome to the documentation for a declarative NixOS homelab configuration. This repository manages multiple NixOS hosts, macOS systems via nix-darwin, and user environments with Home Manager—all using Nix flakes.

## Quick Links

<div class="grid cards" markdown>

- :material-rocket-launch: **[Getting Started](bootstrap-quickstart.md)**

    Bootstrap a new host or get up and running quickly

- :material-sitemap: **[Architecture](repository-architecture.md)**

    Understand the repository structure and design decisions

- :material-puzzle: **[Patterns](modular-design-patterns.md)**

    Learn the standardized patterns for service modules

- :material-backup-restore: **[Operations](backup-system-onboarding.md)**

    Backup, disaster recovery, and operational procedures

</div>

## Repository Overview

```text
nix-config/
├── flake.nix              # Flake entry point
├── lib/                   # Shared library functions (mylib)
├── modules/               # Reusable NixOS/Darwin modules
│   ├── nixos/services/    # Service modules
│   └── nixos/storage/     # ZFS dataset management
├── hosts/                 # Host-specific configurations
│   ├── forge/             # Primary homelab server
│   └── luna/              # Secondary server
├── home/                  # Home Manager configurations
└── docs/                  # This documentation
```

## Core Principles

### 1. Declarative Configuration

Everything is defined in Nix. No manual steps, no imperative configuration. The entire system state is reproducible from the flake.

### 2. Contribution Pattern

Services declare their infrastructure needs (storage, backup, monitoring). Infrastructure modules aggregate these contributions. See [ADR-001](adr/001-contributory-infrastructure-pattern.md).

### 3. Native Over Containers

Prefer NixOS service modules over containerized implementations when available. Containers are a last resort. See [ADR-005](adr/005-native-services-over-containers.md).

### 4. Co-located Configuration

Service configuration, storage datasets, backup policies, and alerts are co-located in the same file. Related concerns stay together.

## Key Hosts

| Host | Role | Architecture |
|------|------|--------------|
| **forge** | Primary homelab server | Two-disk ZFS, tank pool for services |
| **luna** | Secondary server | Single-disk, impermanent root |

## Architecture Decision Records

This repository maintains [ADRs](adr/README.md) documenting significant design choices:

| ADR | Decision |
|-----|----------|
| [001](adr/001-contributory-infrastructure-pattern.md) | Services declare needs; infrastructure aggregates |
| [002](adr/002-host-level-defaults-library.md) | Parameterized factory for host-specific helpers |
| [003](adr/003-shared-types-for-service-modules.md) | Centralized type definitions via `mylib.types` |
| [004](adr/004-impermanence-host-level-control.md) | Hosts control persistence, not modules |
| [005](adr/005-native-services-over-containers.md) | Prefer native NixOS modules over containers |
| [006](adr/006-black-box-white-box-monitoring.md) | Gatus for availability, Prometheus for internals |
| [007](adr/007-multi-tier-disaster-recovery.md) | Preseed with Syncoid → Local priority |
| [008](adr/008-authentication-priority-framework.md) | OIDC → Headers → Disable+Caddy priority |
| [009](adr/009-thin-orchestrator-pattern.md) | Lightweight stack modules without re-exposure |

## Common Tasks

### Build a Host

```bash
task nix:build-forge
```

### Apply Configuration

```bash
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

### Check Flake

```bash
nix flake check
```

### Available Tasks

```bash
task --list
```

## Contributing

Before making changes:

1. Read the [Modular Design Patterns](modular-design-patterns.md)
2. Review relevant [ADRs](adr/README.md)
3. Study existing service modules (`sonarr`, `radarr`, `dispatcharr`)
4. Follow the [Monitoring Strategy](monitoring-strategy.md) for observability

## License

This configuration is open source. See the repository for license details.
