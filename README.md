# nix-config

[![NixOS](https://img.shields.io/badge/NixOS-25.05-blue?logo=nixos&logoColor=white)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/Nix-Flakes-informational?logo=nixos)](https://wiki.nixos.org/wiki/Flakes)
[![Darwin](https://img.shields.io/badge/nix--darwin-25.05-black?logo=apple)](https://github.com/LnL7/nix-darwin)
[![Home Manager](https://img.shields.io/badge/Home%20Manager-25.05-purple)](https://github.com/nix-community/home-manager)

A comprehensive **Infrastructure-as-Code** repository managing NixOS servers, macOS workstations, and user environments through Nix flakes. Features enterprise-grade patterns including declarative service management, encrypted secrets, ZFS storage with replication, comprehensive monitoring, and disaster recovery capabilities.

## ✨ Highlights

- **Multi-System Management**: NixOS servers (homelab, cloud), macOS workstations, and unified user environments
- **Three-Tier Architecture**: Clear separation between core OS, infrastructure, and application services
- **43+ Managed Services**: Media automation, home automation, AI/LLM, monitoring, and more on the `forge` host
- **Enterprise Patterns**: Declarative backups with Restic + pgBackRest, Prometheus/Grafana observability, Gatus status pages
- **Secure by Default**: SOPS-encrypted secrets, PocketID SSO, Caddy reverse proxy with automatic TLS
- **ZFS-First Storage**: Per-service datasets with optimized recordsizes, Sanoid snapshots, Syncoid replication
- **Disaster Recovery**: Preseed patterns for automatic service restoration from backups

## 📁 Repository Structure

```
.
├── flake.nix                 # Flake entrypoint - inputs and outputs
├── flake.lock                # Locked dependency versions for reproducibility
├── Taskfile.yaml             # Task runner commands for operations
│
├── hosts/                    # Host-specific configurations
│   ├── _modules/             # Reusable NixOS/Darwin modules
│   │   ├── common/           # Cross-platform modules
│   │   ├── darwin/           # macOS-specific modules
│   │   ├── nixos/            # NixOS-specific modules (70+ service modules)
│   │   └── lib/              # Shared type definitions and helpers
│   │
│   ├── forge/                # Primary homelab server (NixOS)
│   │   ├── core/             # OS-level: boot, networking, users
│   │   ├── infrastructure/   # Cross-cutting: storage, backup, observability
│   │   ├── services/         # 43+ application services
│   │   └── lib/              # Host-specific helpers (forgeDefaults)
│   │
│   ├── luna/                 # Secondary server (NixOS)
│   ├── nas-1/                # NAS configuration (NixOS)
│   ├── rymac/                # MacBook Pro (nix-darwin)
│   └── rydev/                # Development VM (NixOS)
│
├── home/                     # Home Manager configurations
│   ├── _modules/             # Reusable home modules
│   └── ryan/                 # User-specific config with per-host overrides
│
├── profiles/                 # Composable system profiles
│   ├── hardware/             # Hardware-specific (Intel GPU, Coral TPU)
│   └── user/                 # User environment profiles
│
├── pkgs/                     # Custom packages
│   ├── nvfetcher.toml        # Source definitions for auto-updates
│   └── _sources/             # Generated source metadata
│
├── overlays/                 # Package overlays and modifications
│
└── docs/                     # 50+ documentation files
    ├── modular-design-patterns.md
    ├── monitoring-strategy.md
    ├── backup-system-onboarding.md
    └── ...
```

## 🏗️ Architecture

### Three-Tier Organization (Forge Host)

The `forge` host demonstrates our architectural approach, separating concerns into three distinct layers:

```mermaid
flowchart TB
    subgraph Services["🔧 APPLICATION SERVICES"]
        direction LR
        Media["Media: Plex, Sonarr, Radarr, qBittorrent, Tdarr"]
        Home["Home: Home Assistant, Frigate, Zigbee2MQTT, ESPHome"]
        AI["AI/LLM: Open WebUI, LiteLLM"]
        Utils["Utils: Paperless, Mealie, Enclosed, Cooklang"]
    end

    subgraph Infra["⚙️ INFRASTRUCTURE"]
        direction LR
        Storage["Storage: ZFS datasets, Sanoid, Syncoid"]
        Backup["Backup: Restic, pgBackRest"]
        Obs["Observability: Prometheus, Grafana, Loki"]
        Net["Networking: Caddy, Cloudflare Tunnel"]
    end

    subgraph Core["🖥️ CORE OS"]
        direction LR
        CoreItems["Boot, Networking, Users, Impermanence, System Health"]
    end

    Services -->|consumes| Infra
    Infra -->|runs on| Core
```

### Key Design Patterns

#### Contribution Pattern

Services co-locate their own infrastructure needs. Each service file contains:

- Service configuration
- Storage dataset declaration (`modules.storage.datasets`)
- Backup policy (`modules.backup.sanoid.datasets`)
- Monitoring alerts (`modules.alerting.rules`)

```nix
# Example: hosts/forge/services/sonarr.nix
{
  modules.services.sonarr = {
    enable = true;
    backup = forgeDefaults.backup;
  };

  # Co-located storage
  modules.storage.datasets.services.sonarr = {
    mountpoint = "/var/lib/sonarr";
    recordsize = "16K";  # Optimized for SQLite
  };

  # Co-located backup policy
  modules.backup.sanoid.datasets."tank/services/sonarr" =
    forgeDefaults.mkSanoidDataset "sonarr";

  # Co-located monitoring
  modules.alerting.rules."sonarr-service-down" =
    forgeDefaults.mkServiceDownAlert "sonarr" "Sonarr" "TV series management";
}
```

#### Native > Container Philosophy

We prefer native NixOS services over containers when available:

- Better systemd integration
- Simplified updates via `nix flake update`
- No container user/permission mapping complexity
- Direct filesystem access without volume mounts

Containers are used when:

- No native NixOS module exists
- Application explicitly requires containerization
- Rapid prototyping before native implementation

#### Standardized Submodules

All services use consistent submodule patterns from `hosts/_modules/lib/types.nix`:

- `reverseProxy` - Caddy integration with TLS and auth
- `metrics` - Prometheus scrape configuration
- `logging` - Promtail/Loki log shipping
- `backup` - Restic backup integration
- `notifications` - Alert routing

## 🚀 Quick Start

### Prerequisites

- NixOS installed on target systems, or
- nix-darwin for macOS
- Flakes enabled (`nix.settings.experimental-features = [ "nix-command" "flakes" ]`)
- SOPS/age keys configured for secrets

### Deployment

```bash
# Clone repository
git clone https://github.com/carpenike/nix-config.git
cd nix-config

# List available tasks
task --list

# Validate configuration
task nix:validate

# Deploy to NixOS host
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net

# Deploy to Darwin host
task nix:apply-darwin host=rymac

# Build without applying (test)
task nix:build-nixos host=forge
```

### Common Operations

```bash
# Update all flake inputs
task nix:update

# Update specific input
task nix:update input=nixpkgs

# Compare system generations
task nix:diff host=forge

# Edit encrypted secrets
task sops:edit host=forge

# Re-encrypt all secrets (after key changes)
task sops:re-encrypt

# Check backup status
task backup:status

# Orchestrate backups before major changes
task backup:orchestrate
```

## 🖥️ Managed Systems

| Host | Platform | Architecture | Role |
|------|----------|--------------|------|
| `forge` | NixOS | x86_64-linux | Primary homelab server (43+ services) |
| `luna` | NixOS | x86_64-linux | Secondary server |
| `nas-1` | NixOS | x86_64-linux | ZFS NAS, backup target |
| `rymac` | nix-darwin | aarch64-darwin | MacBook Pro workstation |
| `rydev` | NixOS | aarch64-linux | Development VM |
| `nixpi` | NixOS | aarch64-linux | Raspberry Pi |

## 🔧 Services on Forge

### Media & Entertainment

| Service | Description | Monitoring |
|---------|-------------|------------|
| Plex | Media server | Gatus + Prometheus |
| Sonarr/Radarr/Bazarr | *arr stack for automation | Prometheus alerts |
| qBittorrent + cross-seed | Download clients | Service health |
| Tdarr | Transcoding automation | GPU metrics |
| Tautulli | Plex analytics | - |

### Home Automation

| Service | Description | Monitoring |
|---------|-------------|------------|
| Home Assistant | Automation platform | Gatus + alerts |
| Frigate | NVR with AI detection | Coral TPU metrics |
| Zigbee2MQTT | Zigbee coordinator | MQTT health |
| Z-Wave JS UI | Z-Wave coordinator | Service health |
| ESPHome | IoT firmware builder | - |

### AI & LLM

| Service | Description |
|---------|-------------|
| Open WebUI | Chat interface |
| LiteLLM | Unified AI gateway |

### Infrastructure

| Service | Description |
|---------|-------------|
| Caddy | Reverse proxy + TLS |
| PostgreSQL | Database + pgBackRest |
| Prometheus/Grafana/Loki | Observability stack |
| Gatus | Status page |
| PocketID | SSO/OIDC provider |

### Utilities

| Service | Description |
|---------|-------------|
| Paperless-ngx | Document management |
| Mealie | Recipe manager |
| Cooklang | Recipe markup |
| Enclosed | Encrypted notes |

## 📊 Observability Stack

### Black-Box Monitoring (Gatus)

User-facing availability checks displayed on public status page:

- HTTP/HTTPS endpoint health
- DNS resolution verification
- Certificate expiry warnings

### White-Box Monitoring (Prometheus)

Internal metrics and predictive alerting:

- System resources (node_exporter)
- Container health
- ZFS pool/dataset metrics
- Application-specific exporters

### Alerting Flow

```mermaid
flowchart LR
    P[Prometheus] --> A[Alertmanager]
    A --> Push[Pushover]
    A --> Discord[Discord]

    subgraph Rules["Alert Rules"]
        R1["Defined per-service"]
        R2["Co-located in service files"]
    end

    P -.->|evaluates| Rules
```

See [docs/monitoring-strategy.md](docs/monitoring-strategy.md) for detailed guidance.

## 💾 Backup Architecture

### Multi-Layer Strategy

1. **ZFS Snapshots** (Sanoid) - Hourly/daily/weekly/monthly local snapshots
2. **ZFS Replication** (Syncoid) - Local replication to nas-1
3. **Restic** - Encrypted backups to NAS (local) + Cloudflare R2 (offsite)
4. **pgBackRest** - PostgreSQL PITR to Cloudflare R2 (offsite)

### Disaster Recovery

Services support automatic restoration via preseed pattern:

```nix
preseed = forgeDefaults.mkPreseed [ "syncoid" "local" "restic" ];
```

See [docs/backup-system-onboarding.md](docs/backup-system-onboarding.md) for complete documentation.

## 🔐 Security

### Secrets Management

All secrets encrypted with SOPS using age keys:

```bash
task sops:edit host=forge
```

### Authentication

- **PocketID**: Passkey-first OIDC provider
- **Caddy**: Forward auth integration for all services
- **Access Groups**: admin, home, media with different access levels

### Network Security

- Services bind to localhost only
- Caddy handles TLS termination
- Cloudflare Tunnel for external access (no port forwarding)

## 📚 Documentation

Key documentation files in `docs/`:

| Document | Description |
|----------|-------------|
| [modular-design-patterns.md](docs/modular-design-patterns.md) | Service module architecture |
| [monitoring-strategy.md](docs/monitoring-strategy.md) | Black-box vs white-box monitoring |
| [backup-system-onboarding.md](docs/backup-system-onboarding.md) | Backup configuration guide |
| [persistence-quick-reference.md](docs/persistence-quick-reference.md) | ZFS dataset patterns |
| [custom-package-patterns.md](docs/custom-package-patterns.md) | nvfetcher and package updates |

## 🛠️ Development

### Validation

```bash
# Full flake check
task nix:validate

# Host-specific validation (faster)
task nix:validate host=forge

# Test in VM (Linux only)
task nix:test-vm host=rydev
```

### Adding a New Service

1. Check for native NixOS module first ([search.nixos.org](https://search.nixos.org))
2. Create service file: `hosts/forge/services/myservice.nix`
3. Import in `hosts/forge/default.nix`
4. Follow contribution pattern (service + storage + backup + alerts)
5. Use `forgeDefaults` helpers for consistency

See [docs/modular-design-patterns.md](docs/modular-design-patterns.md) for detailed patterns.

### Package Updates

```bash
# Update nvfetcher sources
nix run .#nvfetcher

# Update package hashes with nix-update
task nix:update-package package=cooklang-cli
```

## 🙏 Acknowledgments

This configuration draws inspiration from:

- [EmergentMind/nix-config](https://github.com/EmergentMind/nix-config)
- [hlissner/dotfiles](https://github.com/hlissner/dotfiles)
- [bjw-s/nix-config](https://github.com/bjw-s/nix-config)
- [ryan4yin/nix-config](https://github.com/ryan4yin/nix-config)

## 📝 License

This repository is shared for educational purposes. Feel free to use patterns and ideas, but this is a personal configuration - not a framework or distribution.

---

*This is an actively maintained personal infrastructure. Patterns evolve as better approaches are discovered.*
