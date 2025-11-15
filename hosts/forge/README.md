# Forge Host Configuration

This directory contains the NixOS configuration for the `forge` host, organized following a three-tier architectural pattern with strict separation of concerns.

## Architecture

### Three-Tier Organization

```
hosts/forge/
├── core/              # OS-level concerns (boot, networking, users, monitoring)
├── infrastructure/    # Cross-cutting operational concerns (storage, backup, observability)
└── services/          # Application-specific configurations
```

### Core Layer (`core/`)

**Purpose**: Fundamental operating system configuration

**Contents**:
- `boot.nix` - Boot loader and kernel configuration
- `networking.nix` - Network configuration, firewall rules
- `users.nix` - User accounts and SSH keys
- `packages.nix` - System-wide packages
- `hardware.nix` - Hardware-specific settings
- `monitoring.nix` - **Core system health alerts** (CPU, memory, disk, systemd units)
- `system-services.nix` - OS-level services (rsyslogd, journald)

**Key Principle**: Core files are OS concerns that would exist on any server, regardless of what applications it runs.

### Infrastructure Layer (`infrastructure/`)

**Purpose**: Cross-cutting operational concerns that span multiple services

**Contents**:
- `alerts.nix` - Backup/snapshot age monitoring (cross-cutting alerts)
- `backup.nix` - Backup orchestration and scheduling
- `storage.nix` - **ZFS datasets, Sanoid templates, NFS mounts, ZFS monitoring alerts**
- `containerization.nix` - Podman networking, generic container health alerts
- `notifications.nix` - Notification system (Pushover, system events)
- `reverse-proxy.nix` - Caddy reverse proxy configuration
- `monitoring-ui.nix` - Monitoring dashboards and UI
- `observability/` - Observability stack (Prometheus, Alertmanager, Grafana, Loki, Promtail)

**Key Principle**: Infrastructure provides services and platforms that applications consume.

### Services Layer (`services/`)

**Purpose**: Application-specific configurations

**Contents**: Individual service files (`sonarr.nix`, `plex.nix`, `postgresql.nix`, etc.)

**Key Principle**: Services are self-contained and contribute their own:
- Service configuration
- Storage datasets (via `modules.storage.datasets`)
- Monitoring alerts (via `modules.alerting.rules`)
- Backup policies (via `modules.backup.sanoid.datasets`)

## Contribution Pattern

This configuration follows a **contribution pattern** where concerns are co-located with the features that require them.

### Example: Adding a New Service

When adding a new service (e.g., `myapp`), create `services/myapp.nix` containing:

```nix
{ ... }:

{
  # Service configuration
  modules.services.myapp = {
    enable = true;
    # ... service config
  };

  # Co-located storage dataset
  modules.storage.datasets."myapp" = {
    dataset = "tank/services/myapp";
    recordsize = "128K";
    compression = "lz4";
  };

  # Co-located Sanoid backup policy
  modules.backup.sanoid.datasets."tank/services/myapp" = {
    useTemplate = [ "services" ];
    recursive = true;
  };

  # Co-located monitoring alerts
  modules.alerting.rules."myapp-service-down" = {
    type = "promql";
    alertname = "MyAppServiceDown";
    expr = "container_service_active{service=\"myapp\"} == 0";
    for = "2m";
    severity = "high";
    # ... alert config
  };
}
```

### Alert Organization

Alerts are distributed according to their scope:

| Alert Type | Location | Example |
|------------|----------|---------|
| Core OS health | `core/monitoring.nix` | CPU, memory, disk, systemd units, watchdog |
| ZFS storage | `infrastructure/storage.nix` | Pool degraded, snapshot stale, pool space |
| Container health | `infrastructure/containerization.nix` | Health check failed, high memory |
| Backup/snapshot age | `infrastructure/alerts.nix` | Snapshot too old, stale holds |
| Infrastructure services | With service | `observability/prometheus.nix` → prometheus-down alert |
| Application services | With service | `services/sonarr.nix` → sonarr-service-down alert |

## Finding Configuration

### "Where is X configured?"

- **System health monitoring?** → `core/monitoring.nix`
- **ZFS datasets and alerts?** → `infrastructure/storage.nix`
- **Container networking?** → `infrastructure/containerization.nix`
- **Notifications (Pushover)?** → `infrastructure/notifications.nix`
- **Service X's config?** → `services/X.nix`
- **Service X's alerts?** → `services/X.nix` (co-located with service)
- **Service X's storage?** → `services/X.nix` (contributes to `modules.storage.datasets`)

### Discovery Tools

```bash
# Find all alert definitions
rg "alertname =" hosts/forge/

# Find where a service is configured
rg "modules\.services\.sonarr" hosts/forge/

# Find all storage dataset definitions
rg "modules\.storage\.datasets" hosts/forge/

# Find all Sanoid backup policies
rg "modules\.backup\.sanoid\.datasets" hosts/forge/
```

## Design Decisions

### Why co-locate alerts with services?

**Benefits**:
- Reduces merge conflicts (services don't share files)
- Improves cohesion (related concerns are together)
- Makes service ownership clear
- Easier to add/remove services

**Trade-offs**:
- Requires tools (`grep`/`rg`) for cross-service discovery
- Cross-cutting changes may need multiple file edits
- Pattern must be documented and enforced

### Why separate core vs infrastructure?

**Core** = "Would exist on a bare server"
- Boot, networking, users are OS fundamentals
- System monitoring (CPU, memory, disk) is always needed

**Infrastructure** = "Provides services to applications"
- Storage (ZFS, NFS) is a platform for applications
- Observability is consumed by services
- Reverse proxy routes to applications

This distinction makes it clear which concerns are mandatory vs optional.

### Why keep default.nix minimal?

`default.nix` serves as the **import orchestrator and host manifest**. It answers "What does this host do?" without implementation details. The ~140 lines remaining are:
- Import statements (the "table of contents")
- Host-specific parameters (IP address, enabled features)
- Top-level enables (impermanence, openssh, caddy)

This makes the host's capabilities immediately visible without scrolling through hundreds of lines of implementation.

## Metrics

- **Original**: 3,168 lines in `default.nix`
- **Current**: 140 lines in `default.nix` (95.6% reduction)
- **Extracted**:
  - `core/monitoring.nix`: 117 lines
  - `infrastructure/storage.nix`: 337 lines (includes ZFS alerts)
  - `infrastructure/alerts.nix`: 74 lines (backup/snapshot age)
  - `infrastructure/containerization.nix`: 55 lines (includes container alerts)
  - `infrastructure/notifications.nix`: 30 lines
  - `infrastructure/reverse-proxy.nix`: 80 lines
  - `core/system-services.nix`: 74 lines

## Maintenance

### When to create a new file

Create a new file when you have a **cohesive set of related configuration** that:
1. Has a clear single purpose
2. Could grow independently
3. Might be reused across hosts

Don't create files just to reduce line count.

### When to consolidate files

Consolidate files if they are **always modified together** in the same commit. If every change to file A also requires a change to file B, they probably belong together.

### Enforcing the pattern

In code reviews, verify:
- Services contribute their own alerts (not in central files)
- ZFS-related config stays in `storage.nix`
- Core OS concerns stay in `core/`
- Infrastructure provides platforms, not applications

## Questions?

If you're unsure where something belongs:
1. Is it OS-level? → `core/`
2. Is it a platform/service provider? → `infrastructure/`
3. Is it an application? → `services/`
4. Is it service-specific (alert, dataset, backup)? → Co-locate with service

When in doubt, use `rg` to find similar examples in the codebase.
