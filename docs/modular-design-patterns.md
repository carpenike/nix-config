# Modular Design Patterns

This document establishes standardized design patterns for NixOS service modules based on the refined Caddy and PostgreSQL reference implementations. Following these patterns ensures consistency, maintainability, and type safety across the entire infrastructure configuration.

## Design Philosophy

### Core Principles

1. **Declarative Configuration**: Services declare what they need, not how to achieve it
2. **Type Safety**: Use `types.submodule` for complex configuration structures
3. **Separation of Concerns**: Abstract implementation details from service declarations
4. **Automatic Integration**: Services automatically register with infrastructure systems
5. **Graceful Migration**: Support legacy patterns during transitions

### Reference Implementations

- **Web Services**: `hosts/_modules/nixos/services/caddy/default.nix` - Structured backend configuration, security options, automatic DNS record generation
- **Storage Services**: `hosts/_modules/nixos/services/postgresql/` - Database provisioning, secure credential handling, systemd integration
- **Observability Services**: `hosts/_modules/nixos/services/loki/default.nix`, `hosts/_modules/nixos/services/promtail/default.nix` - Complete observability stack with standardized patterns
- **Monitoring Services**: `hosts/_modules/nixos/services/uptime-kuma/default.nix` - Black-box monitoring with pragmatic Prometheus integration
- **Shared Types**: `hosts/_modules/lib/types.nix` - Centralized type definitions for all standardized submodules

### Related Documentation

- **Monitoring Strategy**: `docs/monitoring-strategy.md` - Black-box vs white-box monitoring principles, service-specific guidance

### Cross-Service Contribution Interfaces

Shared services expose dedicated integration points so downstream modules can declaratively contribute resources without patching implementation details:

- **Grafana** (`hosts/_modules/nixos/services/grafana/default.nix`)
  - Use `modules.services.grafana.integrations.<name>` to bundle datasources, dashboards, and `LoadCredential` entries.
  - Each integration can provide a map of datasources plus dashboard providers, and the module handles YAML provisioning + credential wiring automatically.
  - Example: `modules.services.grafana.integrations.teslamate.datasources.teslamate = { ... };` (see TeslaMate module for a real reference).
- **PostgreSQL → Grafana bridge**
  - Any database may declare `grafanaDatasources = [ { ... } ]` under `modules.services.postgresql.databases.<dbName>`.
  - Entries capture datasource metadata (host, user, UID, Timescale toggles) and optional dashboard directories; the module emits the correct Grafana integration and attaches password files safely via systemd credentials.
- **EMQX MQTT broker**
  - Global ACLs live in `modules.services.emqx.aclRules`, and downstream services can append via `modules.services.emqx.integrations.<service>.acls`.
  - MQTT users can also be added through the same integration attribute, keeping per-service credentials close to their owners.
  - The module now materializes `authz.conf` and sets `EMQX_AUTHORIZATION__*` automatically whenever rules are declared.

---

## Creating New Service Modules

### Native vs Container Decision

**CRITICAL PRINCIPLE**: Always prefer native NixOS services over containerized implementations when available.

#### Decision Framework

When adding a new service, follow this priority order:

1. **Check for native NixOS module** (`search.nixos.org/options`)
   - ✅ **PREFERRED**: Wrap native module with homelab patterns
   - Example: Uptime Kuma has `services.uptime-kuma` - use this instead of container
   - Benefits: Better NixOS integration, easier updates, no container overhead

2. **If native module doesn't exist**, check if upstream provides one
   - Sometimes services have NixOS modules in their own repos
   - Consider contributing the module to nixpkgs

3. **Only use containers when**:
   - No native NixOS module exists or is practical
   - Service explicitly requires containerization (security isolation)
   - Rapid prototyping before creating native module

#### Architecture Pivot Example: Uptime Kuma

The Uptime Kuma module demonstrates the preferred approach:

**Initial Implementation** (Nov 5, 2025):
- Podman container with full homelab patterns (369 lines)
- Custom image management, systemd integration, volume mounts

**Discovery & Pivot**:
- Found native `services.uptime-kuma` module in NixOS
- Pivoted to wrapper approach (~200 lines, 46% reduction)

**Final Architecture**:
```nix
# Wrapper around native module adds homelab patterns
config = mkIf cfg.enable {
  # Enable native NixOS service
  services.uptime-kuma = {
    enable = true;
    settings.HOST = "0.0.0.0";
    settings.PORT = "3001";
  };

  # Add homelab integrations
  # - ZFS storage management
  # - Backup integration
  # - Reverse proxy registration
  # - Monitoring/alerting
  # - Preseed/DR capability
};
```

**Benefits of Native Approach**:
- ✅ Simpler implementation (46% less code)
- ✅ No Podman dependency
- ✅ Better systemd integration
- ✅ Automatic NixOS updates (`nix flake update`)
- ✅ Native privilege management (no container user mapping)
- ✅ Direct filesystem access (no volume mounts)

### Service Module Creation Workflow

#### Step 1: Research & Discovery

1. **Search for native NixOS module**:
   ```bash
   # Search nixpkgs options
   nix search nixpkgs#<service-name>

   # Check NixOS options
   # https://search.nixos.org/options?query=services.<service>
   ```

2. **Evaluate existing module** (if found):
   - Does it provide sufficient configuration options?
   - Is it actively maintained?
   - Does it follow modern NixOS patterns?

3. **Decision point**:
   - Native module exists and is sufficient → **Wrapper approach** (preferred)
   - Native module incomplete/outdated → **Contribute fixes or full implementation**
   - No native module → **Container or custom implementation**

#### Step 2: Module Structure

Create your module in `hosts/_modules/nixos/services/<service-name>/`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.<service-name>;

  # Import shared types for consistency
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Storage helpers for ZFS dataset management
  storageHelpers = import ../../../lib/storage-helpers.nix { inherit lib; };
in
{
  options.modules.services.<service-name> = {
    enable = lib.mkEnableOption "<service-name>";

    # Add standardized submodules (choose applicable ones)
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = null;
      description = "Log shipping configuration";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification channels";
    };

    # Add preseed for disaster recovery (if stateful)
    preseed = {
      enable = lib.mkEnableOption "automatic restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "URL to Restic repository";
      };
      # ... (see preseed pattern below)
    };
  };

  config = lib.mkIf cfg.enable {
    # Service implementation here
  };
}
```

#### Host-Level Contribution Rule

When a host (for example `hosts/forge/services/<name>.nix`) enables a service module and contributes additional infrastructure resources—ZFS datasets, Sanoid definitions, alert rules, backup jobs, Cloudflare tunnels, etc.—**every one of those contributions must be wrapped in a guard tied to the service's enable flag**. The canonical pattern is:

```nix
let
  serviceEnabled = config.modules.services.<service>.enable or false;
in
{
  config = lib.mkMerge [
    { modules.services.<service> = { enable = true; ... }; }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.<service> = { ... };
      modules.backup.sanoid.datasets."tank/services/<service>" = { ... };
      modules.alerting.rules."<service>-service-down" = { ... };
      modules.services.caddy.virtualHosts.<service>.cloudflare = { ... };
    })
  ];
}
```

This ensures that disabling a service automatically disables all downstream infrastructure so we never create orphaned datasets, alerts, or backup jobs.

#### Host-Level Defaults Libraries

For hosts with many services following similar patterns, create a centralized defaults library to reduce duplication. This is particularly useful for:

- Standard Sanoid/Syncoid replication configurations
- Common alert patterns (service-down, systemd-down)
- Backup repository configurations
- Authentication/security policies

**Reference Implementation**: `hosts/forge/lib/defaults.nix`

```nix
# hosts/<hostname>/lib/defaults.nix
{ config, lib }:

let
  resticEnabled = (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
{
  # Standard backup configuration
  backup = {
    enable = true;
    repository = "nas-primary";
  };

  # ZFS replication helper
  mkSanoidDataset = serviceName: {
    useTemplate = [ "services" ];
    recursive = false;
    autosnap = true;
    autoprune = true;
    replication = {
      targetHost = "nas-1.example.com";
      targetDataset = "backup/${config.networking.hostName}/zfs-recv/${serviceName}";
      # ... replication options
    };
  };

  # Container service-down alert helper
  mkServiceDownAlert = serviceName: displayName: description: {
    type = "promql";
    alertname = "${displayName}ServiceDown";
    expr = ''container_service_active{name="${serviceName}"} == 0'';
    for = "2m";
    severity = "high";
    labels = { service = serviceName; category = "availability"; };
    annotations = {
      summary = "${displayName} service is down on {{ $labels.instance }}";
      description = "The ${displayName} ${description} service is not active.";
      command = "systemctl status podman-${serviceName}.service";
    };
  };

  # Systemd service-down alert helper (for native services)
  mkSystemdServiceDownAlert = serviceName: displayName: description: {
    type = "promql";
    alertname = "${displayName}ServiceDown";
    expr = ''node_systemd_unit_state{name="${serviceName}.service",state="active"} == 0'';
    for = "2m";
    severity = "high";
    labels = { service = serviceName; category = "availability"; };
    annotations = {
      summary = "${displayName} service is down on {{ $labels.instance }}";
      description = "The ${displayName} ${description} service is not active.";
      command = "systemctl status ${serviceName}.service";
    };
  };

  # Preseed/DR configuration (auto-gated by restic)
  mkPreseed = restoreMethods: lib.mkIf resticEnabled {
    enable = true;
    repositoryUrl = "/mnt/nas-backup";
    passwordFile = config.sops.secrets."restic/password".path;
    restoreMethods = restoreMethods;
  };
}
```

**Usage in Service Files**:

```nix
{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.myapp.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.myapp = {
        enable = true;
        backup = forgeDefaults.backup;
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" "restic" ];
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets."tank/services/myapp" =
        forgeDefaults.mkSanoidDataset "myapp";

      modules.alerting.rules."myapp-service-down" =
        forgeDefaults.mkServiceDownAlert "myapp" "MyApp" "application";
    })
  ];
}
```

**Key Benefits**:
- Reduces boilerplate from ~15-20 lines to 1-2 lines per concern
- Ensures consistency across all services on a host
- Single point of change for host-specific infrastructure patterns
- Separates "what the module does" from "how this host deploys it"

**When to Create a Defaults Library**:
- Host has 5+ services with similar patterns
- Multiple services share the same backup/replication target
- Alert patterns are standardized across services
- Authentication policies are consistent

**When NOT to Use Helpers**:
- Service has unique, complex alert expressions
- Backup requires custom retention or exclusion patterns
- Replication needs special handling (encrypted sends, different targets)

#### Step 3: Native Wrapper Pattern (PREFERRED)

When wrapping a native NixOS module:

```nix
config = lib.mkIf cfg.enable {
  # 1. Enable and configure native service
  services.<service-name> = {
    enable = true;
    # Pass through relevant configuration
    # Keep it minimal - let native module handle defaults
  };

  # 2. Override systemd service if needed (for ZFS, etc.)
  systemd.services."<service-name>" = {
    # Add dependencies
    after = [ "zfs-mount.service" ];
    requires = [ "zfs-mount.service" ];

    # Override user/permissions if needed
    serviceConfig = {
      User = lib.mkForce "<service-user>";
      Group = lib.mkForce "<service-group>";
      StateDirectory = lib.mkForce ""; # Disable if using ZFS
      ReadWritePaths = [ cfg.dataDir ]; # For sandboxing
    };
  };

  # 3. Add ZFS storage management
  systemd.services."ensure-<service-name>-storage" =
    storageHelpers.mkZfsStorageService {
      dataset = "tank/services/<service-name>";
      mountpoint = cfg.dataDir;
      owner = "<service-user>";
      properties = {
        recordsize = "16K"; # Optimize for workload
        compression = "zstd";
      };
    };

  # 4. Add homelab integrations (backup, monitoring, etc.)
  # See subsequent patterns below
};
```

#### Step 4: Add Homelab Integrations

Follow the standardized submodule patterns:

1. **Reverse Proxy** (if web service):
   ```nix
   modules.services.caddy.virtualHosts."<service>" = lib.mkIf (cfg.reverseProxy != null) {
     enable = cfg.reverseProxy.enable;
     hostName = cfg.reverseProxy.hostName;
     backend = cfg.reverseProxy.backend;
   };
   ```

2. **Monitoring** (see Monitoring Strategy doc):
   - Add to Uptime Kuma (user-facing check)
   - Configure Prometheus alerts (system health)
   - Add systemd health check if needed

3. **Backup** (if stateful):
   ```nix
   modules.services.backup.jobs."<service-name>" = lib.mkIf (cfg.backup != null) {
     enable = cfg.backup.enable;
     repository = cfg.backup.repository;
     paths = [ cfg.dataDir ];
     useSnapshots = cfg.backup.useSnapshots;
     # ... (see backup pattern)
   };
   ```

4. **Preseed/DR** (for critical services):
   ```nix
   # Add pre-start restore logic
   # See Disaster Recovery Preseed Pattern doc
   ```

#### Step 5: Testing & Validation

1. **Build configuration**:
   ```bash
   nix build .#nixosConfigurations.<host>.config.system.build.toplevel
   ```

2. **Deploy and verify**:
   ```bash
   # Check service status
   systemctl status <service-name>.service

   # Verify ZFS dataset
   zfs list | grep <service-name>

   # Test backup
   systemctl start backup-<service-name>.service

   # Check monitoring
   curl http://localhost:<metrics-port>/metrics
   ```

3. **Validate integrations**:
   - Reverse proxy: `curl https://<service>.domain.tld`
   - Backup: Check Restic snapshots
   - Monitoring: Verify Prometheus scrape targets
   - Logs: Check Loki for service logs

#### Step 6: Documentation

Add inline comments explaining:
- Why native vs container choice was made
- Any workarounds or special considerations
- Dependencies and assumptions
- Reference to relevant design pattern docs

### Common Patterns by Service Type

#### Web Application
- ✅ Reverse proxy (Caddy)
- ✅ Uptime Kuma health check
- ✅ Backup (if stores data)
- ⚠️ Metrics (only if critical)

#### Database
- ✅ Backup with snapshots
- ✅ Metrics (postgres_exporter, etc.)
- ✅ Preseed/DR capability
- ✅ TCP health check (optional)

#### Infrastructure Service
- ✅ Systemd monitoring (Prometheus)
- ✅ Metrics (node_exporter or custom)
- ⚠️ Backup (if configuration is critical)

#### Monitoring Service
- ✅ Systemd health check
- ✅ Prometheus monitoring (meta-monitoring)
- ❌ NO recursive monitoring (avoid complexity)

### Anti-Patterns to Avoid

❌ **Don't create container version without checking for native module**
- Always search nixpkgs first
- Containers should be last resort

❌ **Don't duplicate functionality that exists in native modules**
- Use native module features when available
- Only override what you need to change

❌ **Don't skip standardized submodules**
- Every service should use applicable patterns
- Consistency makes maintenance easier

❌ **Don't create per-service backup scripts**
- Use unified backup system
- Declare backup needs, don't implement them

❌ **Don't implement custom metric exporters**
- Use existing exporters when available
- Consider if metrics are actually needed (see Monitoring Strategy)

### Migration Path for Existing Containers

If you have existing container-based services:

1. **Check for native module** (may not have existed when originally deployed)
2. **Evaluate migration effort** vs benefits
3. **Save container version** as `.container-backup` file
4. **Implement native wrapper** with same functionality
5. **Test thoroughly** before removing container
6. **Document architecture change** with reasoning

Example: Uptime Kuma migration saved as `hosts/_modules/nixos/services/uptime-kuma/default.nix.container-backup` for reference.

---

## Shared Types Library

All standardized submodule types are centralized in `hosts/_modules/lib/types.nix` to ensure consistency and reusability across services.

### Import Pattern
```nix
# Import shared type definitions in service modules
sharedTypes = import ../../../lib/types.nix { inherit lib; };
```

### Available Shared Types
- `sharedTypes.reverseProxySubmodule` - Reverse proxy integration with TLS backend support
- `sharedTypes.metricsSubmodule` - Prometheus metrics collection with advanced labeling
- `sharedTypes.loggingSubmodule` - Log shipping with multiline parsing, regex support, and container driver config
- `sharedTypes.backupSubmodule` - Backup integration with retention policies
- `sharedTypes.notificationSubmodule` - Notification channels with escalation
- `sharedTypes.containerResourcesSubmodule` - Container resource management
- `sharedTypes.datasetSubmodule` - ZFS dataset configuration (recordsize, compression, properties)
- `sharedTypes.healthcheckSubmodule` - Container healthcheck configuration (interval, timeout, retries)

## Standardized Submodule Patterns

### 1. Reverse Proxy Integration

All web services should use the shared reverse proxy type for consistent Caddy integration.

#### Implementation Pattern
```nix
# Use shared type instead of inline definition
reverseProxy = mkOption {
  type = types.nullOr sharedTypes.reverseProxySubmodule;
  default = null;
  description = "Reverse proxy configuration for this service";
};
```

#### Auto-Registration Implementation
```nix
config = mkIf cfg.enable {
  # Automatic Caddy registration
  modules.services.caddy.virtualHosts."${serviceName}" = mkIf (cfg.reverseProxy != null) {
    enable = cfg.reverseProxy.enable;
    hostName = cfg.reverseProxy.hostName;
    backend = cfg.reverseProxy.backend;
    auth = cfg.reverseProxy.auth;
  };
};
```

### 2. Metrics Collection Pattern

Services that expose metrics should use the shared metrics type for automatic Prometheus integration.

#### Implementation Pattern
```nix
# Use shared type with service-specific defaults
metrics = mkOption {
  type = types.nullOr sharedTypes.metricsSubmodule;
  default = {
    enable = true;
    port = 9090;  # Service-specific port
    path = "/metrics";
    labels = {
      service_type = "database";
      exporter = "postgres";
      function = "storage";
    };
  };
  description = "Prometheus metrics collection configuration";
};
```

#### Auto-Registration Implementation
```nix
# No explicit registration required - the observability module automatically
# scans all enabled services under `config.modules.services.*` for metrics submodules

config = mkIf cfg.enable {
  # Services are automatically discovered when they define a metrics submodule
  # The observability module uses discoverMetricsTargets() to find all services with:
  # - (service.metrics or null) != null
  # - (service.metrics.enable or false) == true

  # Generated Prometheus scrape config will include:
  # - job_name: "service-${serviceName}"
  # - targets: ["${interface}:${port}"]
  # - metrics_path: "${path}"
  # - scrape_interval: "${scrapeInterval}"
  # - labels: service.metrics.labels + { service = serviceName; instance = hostName; }
};
```

### 3. Log Shipping Pattern

Services that produce logs should use the shared logging type for automatic Promtail/Loki integration.

#### Implementation Pattern
```nix
# Use shared type with enhanced parsing capabilities
logging = mkOption {
  type = types.nullOr sharedTypes.loggingSubmodule;
  default = {
    enable = true;
    journalUnit = "${serviceName}.service";
    labels = {
      service = serviceName;
      service_type = "application";
    };
    parseFormat = "json";  # or "logfmt", "regex", "multiline", "none"
  };
  description = "Log shipping configuration";
};

# Advanced parsing example
logging = mkOption {
  type = types.nullOr sharedTypes.loggingSubmodule;
  default = {
    enable = true;
    logFiles = [ "/var/log/app/error.log" ];
    parseFormat = "multiline";
    multilineConfig = {
      firstLineRegex = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}";
      maxWaitTime = "3s";
    };
  };
};
```

#### Auto-Registration Implementation
```nix
# Logging auto-registration follows the same pattern as metrics
# The observability module automatically discovers services with logging submodules

config = mkIf cfg.enable {
  # Promtail automatically discovers services with logging.enable = true
  # Generated configuration includes:
  # - job_name: "service-${serviceName}"
  # - journalUnit or logFiles based on configuration
  # - labels: service.logging.labels + { service = serviceName; }
  # - parseFormat for structured log processing
};
```

### 4. Unified Backup Integration Pattern ✅ **UPDATED 2025-10-29**

All stateful services should use the unified backup system with the shared backup type for consistent policy management and automatic discovery.

#### Implementation Pattern
```nix
# Use shared type with service-specific configuration
backup = mkOption {
  type = types.nullOr sharedTypes.backupSubmodule;
  default = {
    enable = true;
    repository = "nas-primary";
    frequency = "daily";
    tags = [ "service-type" "service-name" "data-category" ];
    useSnapshots = false;  # Opt-in for ZFS snapshot coordination
    excludePatterns = [
      "**/cache/**"
      "**/tmp/**"
      "**/*.log"
    ];
  };
  description = "Backup configuration for unified backup system";
};
```

#### ZFS Snapshot Integration (Opt-in)
For services that need consistent backups (databases, applications with locks, etc.), enable ZFS snapshot coordination:

```nix
# For services requiring snapshot consistency (databases, locked files)
backup = {
  enable = true;
  repository = "nas-primary";
  useSnapshots = true;        # Enable snapshot coordination
  zfsDataset = "tank/services/myservice";  # Required when useSnapshots=true
  frequency = "daily";
  tags = [ "database" "myservice" "critical" ];
  excludePatterns = [
    "**/*.log"        # Exclude logs from snapshots
    "**/cache/**"     # Exclude cache directories
  ];
};
```

**Working Example** (from dispatcharr service):
```nix
backup = {
  enable = true;
  repository = "nas-primary";
  useSnapshots = true;
  zfsDataset = "tank/services/dispatcharr";
  frequency = "daily";
  tags = [ "iptv" "dispatcharr" "application" ];
};
```

**When to Use Snapshots:**
- ✅ **Database services** (PostgreSQL, SQLite) - consistency critical
- ✅ **Application state** (Sonarr, Radarr, etc.) - avoid corrupt configs
- ✅ **Locked files** - services that may have open file handles
- ❌ **Static content** (Plex media) - snapshots add unnecessary overhead
- ❌ **Read-only data** - content that doesn't change during backup

#### Auto-Discovery Implementation
```nix
# No manual registration required!
# The unified backup system automatically discovers services with backup submodules
# Services simply declare their backup needs, system handles the rest
```

**Key Changes from Legacy Pattern:**
- ✅ **Automatic Discovery**: No manual job registration needed
- ✅ **Opt-in Snapshots**: Services declare `useSnapshots = true` when needed
- ✅ **Unified Monitoring**: All metrics flow through textfile collector
- ✅ **Enterprise Verification**: Automated integrity checks and restore testing

**Critical Configuration Updates Required:**

Services that handle databases, application state, or have file locking must enable snapshot coordination:

```nix
# Update these service backup configurations:
# 1. Sonarr - SQLite database, configuration files
modules.services.sonarr.backup = {
  enable = true;
  repository = "nas-primary";
  useSnapshots = true;                    # REQUIRED
  zfsDataset = "tank/services/sonarr";    # REQUIRED
  excludePatterns = [ "**/*.log" "**/cache/**" ];
};

# 2. Loki - Database and indexes
modules.services.loki.backup = {
  enable = true;
  repository = "nas-primary";
  useSnapshots = true;                    # REQUIRED
  zfsDataset = "tank/services/loki";      # REQUIRED
  excludePatterns = [ "**/*.tmp" ];
};
```

**Migration Guide**: See `/docs/unified-backup-design-patterns.md` for complete implementation details.

### 5. Notification Integration Pattern

Services should use the shared notification type for consistent alerting and status reporting.

#### Implementation Pattern
```nix
# Use shared type with escalation support
notifications = mkOption {
  type = types.nullOr sharedTypes.notificationSubmodule;
  default = {
    enable = true;
    channels = {
      onFailure = [ "critical-alerts" "team-slack" ];
      onBackup = [ "backup-status" ];
      onHealthCheck = [ "monitoring-alerts" ];
    };
    customMessages = {
      failure = "${serviceName} service failed on ${config.networking.hostName}";
      backup = "${serviceName} backup completed on ${config.networking.hostName}";
    };
    escalation = {
      afterMinutes = 15;
      channels = [ "on-call-pager" ];
    };
  };
  description = "Notification configuration";
};
```

### 6. Container Resource Management Pattern

Containerized services should use systemd resource limits and the shared container resources type.

#### Implementation Pattern
```nix
# For systemd services with resource limits
resources = mkOption {
  type = types.attrsOf types.str;
  default = {
    MemoryMax = "512M";
    MemoryReservation = "256M";
    CPUQuota = "50%";
  };
  description = "Systemd resource limits";
};

# For Podman containers, use shared container resources type
container = mkOption {
  type = types.submodule {
    options = {
      resources = mkOption {
        type = sharedTypes.containerResourcesSubmodule;
        default = {
          memory = "512m";
          memoryReservation = "256m";
          cpus = "1.0";
          cpuQuota = "50%";
        };
      };
      # Additional container-specific options...
    };
  };
};
```

## Implementation Guidelines

### Module Structure Template

Every service module should follow this structure:

```nix
# Service module template using shared types
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.modules.services.<service>;
  serviceName = "<service>";
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  options.modules.services.<service> = {
    enable = mkEnableOption "<service> service";

    # Core service configuration
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/${serviceName}";
      description = "Data directory";
    };

    port = mkOption {
      type = types.port;
      description = "Service port";
    };

    # Systemd resource limits
    resources = mkOption {
      type = types.attrsOf types.str;
      default = {
        MemoryMax = "256M";
        CPUQuota = "25%";
      };
      description = "Systemd resource limits";
    };

    # Standardized integration submodules using shared types
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration";
    };

    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = null;
      description = "Log shipping configuration";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification configuration";
    };

    # ZFS integration pattern
    zfs = {
      dataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/${serviceName}";
        description = "ZFS dataset to mount at dataDir";
      };

      properties = mkOption {
        type = types.attrsOf types.str;
        default = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        description = "ZFS dataset properties";
      };
    };
  };

  config = mkIf cfg.enable {
    # ZFS dataset configuration
    modules.storage.datasets.services.${serviceName} = mkIf (cfg.zfs.dataset != null) {
      mountpoint = cfg.dataDir;
      properties = cfg.zfs.properties;
      owner = serviceName;
      group = serviceName;
      mode = "0750";
    };

    # Core service implementation
    systemd.services."${serviceName}" = {
      description = "<Service> service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
      wants = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/${serviceName}";
        Restart = "always";
        User = serviceName;
        Group = serviceName;

        # Resource limits
        MemoryMax = cfg.resources.MemoryMax;
        MemoryReservation = cfg.resources.MemoryReservation or null;
        CPUQuota = cfg.resources.CPUQuota;

        # Security hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # User/group creation
    users.users."${serviceName}" = {
      isSystemUser = true;
      group = serviceName;
      home = cfg.dataDir;
      createHome = true;
    };

    users.groups."${serviceName}" = {};

    # Auto-registration with infrastructure systems using structured backend configuration
    modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = cfg.reverseProxy.backend;

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      # Additional configuration
      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Metrics auto-registration happens automatically via observability module
    # No explicit configuration needed - the observability module scans all
    # services under modules.services.* for metrics submodules

    # Firewall configuration (localhost only)
    networking.firewall = {
      interfaces.lo.allowedTCPPorts = [ cfg.port ]
        ++ lib.optional (cfg.metrics != null && cfg.metrics.enable) cfg.metrics.port;
    };

    # Directory ownership (if not using ZFS dataset)
    systemd.tmpfiles.rules = lib.mkIf (cfg.zfs.dataset == null) [
      "d ${cfg.dataDir} 0755 ${serviceName} ${serviceName} -"
    ];
  };
}
```

### Validation and Assertions

Every module should include comprehensive validation:

```nix
config = mkIf cfg.enable {
  assertions = [
    {
      assertion = cfg.reverseProxy == null || cfg.reverseProxy.backend.port == cfg.port;
      message = "Reverse proxy backend port must match service port";
    }
    {
      assertion = cfg.metrics == null || cfg.metrics.port != cfg.port;
      message = "Metrics port must be different from service port";
    }
    # Additional validations...
  ];
};
```

### 7. ZFS Integration Pattern

Services with persistent storage should use the ZFS dataset pattern for optimized storage management.

#### Implementation Pattern
```nix
zfs = {
  dataset = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "tank/services/${serviceName}";
    description = "ZFS dataset to mount at dataDir";
  };

  properties = mkOption {
    type = types.attrsOf types.str;
    default = {
      compression = "zstd";
      atime = "off";
      "com.sun:auto-snapshot" = "true";
    };
    description = "ZFS dataset properties";
  };
};

# Auto-registration with storage module
modules.storage.datasets.services.${serviceName} = mkIf (cfg.zfs.dataset != null) {
  mountpoint = cfg.dataDir;
  properties = cfg.zfs.properties;
  owner = serviceName;
  group = serviceName;
  mode = "0750";
};
```

### 8. Directory and Permission Management Pattern

Services must use systemd's native StateDirectory mechanism for directory ownership and permissions. This provides a single source of truth and prevents conflicts between tmpfiles and systemd.

#### Critical Design Principles

**✅ DO: Native SystemD Services**
- Use `StateDirectory` + `StateDirectoryMode` for directory management
- Let systemd create and manage directory ownership
- Set `UMask` to control file creation permissions
- NO tmpfiles rules for native services

**❌ DON'T: Common Mistakes**
- Don't use tmpfiles for native systemd services
- Don't set home directory to data directory (causes permission reversion)
- Don't mix tmpfiles and StateDirectory
- Don't rely on ZFS dataset properties for permissions

#### Implementation Pattern for Native Services

```nix
# Service module configuration
config = mkIf cfg.enable {
  # Set user home to /var/empty to prevent activation script interference
  users.users.${serviceName} = {
    isSystemUser = true;
    group = serviceName;
    home = lib.mkForce "/var/empty";  # CRITICAL: Prevents 700 permission enforcement
  };

  # SystemD service configuration
  systemd.services.${serviceName} = {
    serviceConfig = {
      # StateDirectory tells systemd to create /var/lib/${serviceName}
      # with ownership set to User:Group
      StateDirectory = serviceName;

      # StateDirectoryMode sets directory permissions (750 = rwxr-x---)
      StateDirectoryMode = "0750";

      # UMask ensures files created by service are 640 (rw-r-----)
      UMask = "0027";

      # User/Group are set by the service (usually from upstream module)
      User = serviceName;
      Group = serviceName;
    };
  };

  # For ZFS datasets, only specify the dataset - NO owner/group/mode
  modules.storage.datasets.services.${serviceName} = mkIf (cfg.zfs.dataset != null) {
    mountpoint = cfg.dataDir;
    properties = cfg.zfs.properties;
    # DO NOT SET: owner, group, mode - these interfere with StateDirectory
  };
};
```

#### Implementation Pattern for OCI Containers

OCI containers don't support StateDirectory, so they must use tmpfiles:

```nix
# Service module configuration for OCI containers
config = mkIf cfg.enable {
  users.users.${serviceName} = {
    isSystemUser = true;
    group = serviceName;
    home = "/var/empty";
  };

  # For OCI containers, use ZFS dataset WITH explicit permissions
  modules.storage.datasets.services.${serviceName} = mkIf (cfg.zfs.dataset != null) {
    mountpoint = cfg.dataDir;
    properties = cfg.zfs.properties;
    owner = serviceName;
    group = serviceName;
    mode = "0750";
    # Note: OCI containers don't support StateDirectory, so we explicitly set
    # permissions via tmpfiles (handled by storage module)
  };
};
```

#### Storage Module Smart Detection

The storage module automatically detects service type and applies correct pattern:

```nix
# In storage/datasets.nix
systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (serviceName: serviceConfig:
  let
    # Check if explicit permissions are set (OCI containers)
    hasExplicitPermissions = (serviceConfig.mode or null) != null
                          && (serviceConfig.owner or null) != null
                          && (serviceConfig.group or null) != null;
  in
    if hasExplicitPermissions then [
      # OCI containers: Use explicit permissions via tmpfiles
      "d \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
      "z \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
    ] else [
      # Native services: No tmpfiles rules - rely on StateDirectory
      # (tmpfiles with "-" defaults to root:root which interferes)
    ]
) cfg.services);
```

#### Permission Architecture Summary

| Service Type | Directory Creation | Permission Management | Home Directory |
|-------------|-------------------|----------------------|----------------|
| **Native SystemD** | `StateDirectory` | `StateDirectoryMode` + `UMask` | `/var/empty` |
| **Native + ZFS** | ZFS dataset | `owner`/`group`/`mode` in dataset config | `/var/empty` |
| **OCI Container** | tmpfiles | `mode`/`owner`/`group` in dataset config | `/var/empty` |

**IMPORTANT**: When using ZFS datasets, `StateDirectory` only manages permissions for directories it **creates**. If a ZFS dataset is already mounted at the path, `StateDirectory` cannot change its permissions. You must explicitly set `owner`, `group`, and `mode` in the dataset configuration.

#### Examples from Working Implementations

**Grafana (Native Service with ZFS):**
```nix
users.users.grafana.home = lib.mkForce "/var/empty";

systemd.services.grafana.serviceConfig = {
  StateDirectory = "grafana";
  StateDirectoryMode = "0750";
  UMask = "0027";
};

# ZFS dataset - MUST include owner/group/mode since ZFS mountpoint pre-exists
# StateDirectory cannot change permissions on pre-existing directories
modules.storage.datasets.services.grafana = {
  mountpoint = "/var/lib/grafana";
  owner = "grafana";
  group = "grafana";
  mode = "0750";
};
```

**Sonarr (OCI Container):**
```nix
users.users.sonarr.home = "/var/empty";

# No StateDirectory (not supported by OCI)

# ZFS dataset - WITH owner/group/mode
modules.storage.datasets.services.sonarr = {
  mountpoint = "/var/lib/sonarr";
  owner = "sonarr";
  group = "sonarr";
  mode = "0750";
  # Note: OCI containers don't support StateDirectory
};
```

#### Backup User Group Membership

For backup integration, ensure the backup user can read service data:

```nix
# Add service groups to backup user
users.users.restic-backup.extraGroups = [
  "grafana"
  "loki"
  "plex"
  "promtail"
  # Add all services that need backup
];
```

With 750 permissions (rwxr-x---), the backup user (member of service group) can read directories and files created with UMask=0027.

#### Common Pitfalls and Solutions

**Problem:** Permissions revert to 700 after nixos-rebuild
**Cause:** User home directory set to data directory
**Solution:** Set `home = lib.mkForce "/var/empty"`

**Problem:** Directory owned by root:root instead of service user
**Cause:** tmpfiles rule with "-" for user/group
**Solution:** Remove tmpfiles rule, use StateDirectory instead

**Problem:** Backup fails with permission denied
**Cause:** Files created with 600 permissions (user-only)
**Solution:** Add exclude patterns for security-sensitive files

**Problem:** Service fails to start after migration
**Cause:** StateDirectory not set, directory doesn't exist
**Solution:** Add `StateDirectory = serviceName` to serviceConfig

#### Validation Checklist

After implementing directory management:

```bash
# 1. Check StateDirectory configuration
systemctl show <service>.service -p StateDirectory -p StateDirectoryMode

# 2. Verify directory ownership
ls -ld /var/lib/<service>  # Should be <service>:<service> drwxr-x---

# 3. Check user home directory
getent passwd <service>  # Should show /var/empty

# 4. Verify tmpfiles rules
systemd-tmpfiles --cat-config | grep <service>
# Native services: Should NOT have tmpfiles entries
# OCI containers: Should have "d" and "z" entries with explicit permissions

# 5. Test permission persistence
sudo systemctl restart <service>.service
ls -ld /var/lib/<service>  # Should still be drwxr-x---
```

### Helper Functions

Reusable helper functions in `lib/` for common patterns:

- `lib/types.nix` - ✅ **Implemented** - Shared type definitions
- `lib/podman.nix` - ✅ **Implemented** - Container configuration helpers
- `lib/security.nix` - Security hardening templates
- `lib/monitoring.nix` - Metrics and logging configuration
- `lib/backup.nix` - Backup job generation

## Migration Strategy

### Phase 1: Documentation and Standards ✅ **COMPLETED**
1. ✅ Document patterns (this document)
2. ✅ Update CLAUDE.md with pattern requirements
3. ✅ Create helper libraries (`lib/types.nix`, `lib/podman.nix`)

### Phase 2: Infrastructure Implementation ✅ **COMPLETED**
1. ✅ Implement shared type definitions (`lib/types.nix`)
2. ✅ Create standardized Caddy auto-registration
3. ✅ Implement observability stack (Loki, Promtail)
4. 🔄 Centralized notification system (planned)
5. 🔄 Enhanced backup orchestration (planned)

### Phase 3: Service Migration 🔄 **IN PROGRESS**
1. ✅ Migrated core observability services (Grafana, Loki, Promtail)
2. ✅ Migrated web services with reverse proxy patterns
3. 🔄 Migrate remaining containerized services
4. 🔄 Audit and update legacy service configurations
5. 🔄 Deprecate inline type definitions in favor of shared types

### Phase 4: Validation and Testing 📋 **PLANNED**
1. Implement module validation tests
2. Add integration tests for auto-registration
3. Document troubleshooting guides
4. Create migration validation checklist

### Current Migration Status

**✅ Completed Services:**
- Grafana - Full standardized pattern implementation
- Loki - Complete observability stack with ZFS integration
- Promtail - Advanced log shipping with multiline parsing
- Caddy - Structured backend configuration with auto-registration

**🔄 In Progress:**
- Remaining containerized services (UniFi, Omada, etc.)
- Prometheus/Grafana integration for auto-discovery
- Centralized backup orchestration

**📋 Next Priority:**
- Migrate all remaining services to use shared types
- Implement centralized observability auto-registration
- Complete notification system integration

## Best Practices

### Type Safety
- Always use `types.submodule` for complex configuration
- Provide clear descriptions and examples
- Use `mkEnableOption` for boolean features
- Validate configuration with assertions

### Security
- Default to secure configurations
- Use systemd security directives
- Handle secrets via SOPS and environment variables
- Never expose credentials in process lists or logs

### Maintainability
- Keep implementation details in helper functions
- Use descriptive option names
- Provide migration paths for breaking changes
- Document all breaking changes in commit messages

### Performance
- Use lazy evaluation where possible
- Avoid expensive computations in option definitions
- Cache complex derivations
- Consider resource usage of generated configurations

This document serves as the authoritative guide for all new service modules and the target for migrating existing ones.
