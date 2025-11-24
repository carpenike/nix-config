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
- `backup.nix` - Restic backup configuration and monitoring (including zfs-holds-stale)
- `storage.nix` - **Complete ZFS lifecycle: datasets, Sanoid/Syncoid config, replication, all ZFS/snapshot/replication alerts**
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
    expr = "container_service_active{name=\"myapp\"} == 0";
    for = "2m";
    severity = "high";
    # ... alert config
  };
}
```

> **Guard requirement**: wrap every downstream contribution (datasets, backup jobs, alert rules, Cloudflare tunnels, etc.) in `lib.mkIf serviceEnabled` where `serviceEnabled = config.modules.services.myapp.enable or false`. Disabling the service must automatically remove all co-located infrastructure.

### Alert Organization

Alerts are distributed according to their scope following the **co-location principle**:

| Alert Type | Location | Example |
|------------|----------|---------|
| Core OS health | `core/monitoring.nix` | CPU, memory, disk, systemd units, watchdog |
| GPU hardware | `infrastructure/monitoring.nix` | GPU exporter, utilization, engine stalls |
| ZFS storage & snapshots | `infrastructure/storage.nix` | Pool health, capacity, fragmentation, snapshot age (24hr/48hr) |
| ZFS replication | `infrastructure/storage.nix` | Replication lag, stale, never-run, syncoid failures |
| Restic backups | `infrastructure/backup.nix` | Backup errors, zfs-holds-stale (Restic cleanup) |
| Container health | `infrastructure/containerization.nix` | Health check failed, high memory, service down |
| TLS/Caddy | `infrastructure/reverse-proxy.nix` | Certificate expiry, ACME failures, Caddy service down |
| Prometheus/metrics | `infrastructure/observability/prometheus.nix` | prometheus-down, scrape failures |
| PostgreSQL | `services/postgresql.nix` | Database down, connection exhaustion |
| pgBackRest | `services/pgbackrest.nix` | Backup failures, spool usage, config generator |
| Application services | With service | `services/sonarr.nix` → sonarr-service-down alert |

**Key Principle**: Configuration and monitoring are co-located. For example, `storage.nix` defines both the Sanoid/Syncoid configuration AND all the alerts that monitor ZFS health, snapshots, and replication.

### Monitoring Coverage

**Active Services**: 23 out of 25 services have comprehensive monitoring alerts (92% coverage)

**Services Without Monitoring** (intentional):
- `pgweb` - Auxiliary PostgreSQL web UI tool, not critical infrastructure. If down, admins will notice when accessing it. The underlying PostgreSQL database has comprehensive monitoring.
- `qbit-manage` - **DISABLED** service (migrated to `tqm`), no monitoring needed for inactive services.

**Monitoring Strategy by Service Type**:
- **Container Services**: Service-down alerts using `container_service_active` metric
- **Databases**: Connection pool, query performance, deadlocks, WAL archiving
- **Backup Tools**: Job status, staleness, repository health, spool usage
- **Hardware**: Device-specific metrics (UPS battery, temperature, load)

## Finding Configuration

### "Where is X configured?"

- **System health monitoring?** → `core/monitoring.nix`
- **ZFS datasets, snapshots, replication + alerts?** → `infrastructure/storage.nix` (complete ZFS lifecycle)
- **Restic backups + alerts?** → `infrastructure/backup.nix`
- **Container networking?** → `infrastructure/containerization.nix`
- **Notifications (Pushover)?** → `infrastructure/notifications.nix`
- **Alertmanager routing/receivers?** → `infrastructure/observability/alertmanager.nix`
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
- **Current**: 139 lines in `default.nix` (95.6% reduction)
- **Extracted**:
  - `core/monitoring.nix`: 117 lines (system health alerts)
  - `core/system-services.nix`: 74 lines (rsyslogd, journald)
  - `infrastructure/storage.nix`: 538 lines (complete ZFS lifecycle: datasets, Sanoid, Syncoid, 18 alerts)
  - `infrastructure/backup.nix`: 207 lines (Restic backups, zfs-holds-stale alert)
  - `infrastructure/containerization.nix`: 55 lines (Podman + container alerts)
  - `infrastructure/notifications.nix`: 30 lines (Pushover, system notifications)
  - `infrastructure/reverse-proxy.nix`: 80 lines (Caddy)
  - `infrastructure/observability/alertmanager.nix`: 49 lines (alert routing + receivers)

**Key Achievement**: Perfect co-location of configuration and monitoring throughout the architecture.

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
- Services contribute their own alerts (not in central alert files)
- ZFS lifecycle (datasets, snapshots, replication, monitoring) stays in `storage.nix`
- Backup tool monitoring (Restic) stays in `backup.nix`
- Configuration and monitoring are co-located
- Core OS concerns stay in `core/`
- Infrastructure provides platforms, not applications

## Questions?

If you're unsure where something belongs:
1. Is it OS-level? → `core/`
2. Is it a platform/service provider? → `infrastructure/`
3. Is it an application? → `services/`
4. Is it service-specific (alert, dataset, backup)? → Co-locate with service

When in doubt, use `rg` to find similar examples in the codebase.
