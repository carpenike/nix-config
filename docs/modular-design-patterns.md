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
- **Shared Types**: `hosts/_modules/lib/types.nix` - Centralized type definitions for all standardized submodules

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
- `sharedTypes.loggingSubmodule` - Log shipping with multiline parsing and regex support
- `sharedTypes.backupSubmodule` - Backup integration with retention policies
- `sharedTypes.notificationSubmodule` - Notification channels with escalation
- `sharedTypes.containerResourcesSubmodule` - Container resource management

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

### 4. Backup Integration Pattern

Stateful services should use the shared backup type for consistent backup policy management.

#### Implementation Pattern
```nix
# Use shared type with service-specific configuration
backup = mkOption {
  type = types.nullOr sharedTypes.backupSubmodule;
  default = {
    enable = true;
    repository = "nas-primary";
    frequency = "daily";
    tags = [ "database" "production" "critical" ];
    excludePatterns = [
      "**/cache/**"
      "**/tmp/**"
      "**/*.log"  # Exclude logs, use ZFS snapshots for recovery
    ];
    preBackupScript = ''
      # Database-specific backup preparation
      pg_dump mydb > ${cfg.dataDir}/backup.sql
    '';
  };
  description = "Backup configuration";
};
```

#### Auto-Registration Implementation
```nix
config = mkIf cfg.enable {
  # Export backup configuration for centralized backup scheduler
  modules.backup.jobs."${serviceName}" = mkIf (cfg.backup != null && cfg.backup.enable) {
    inherit (cfg.backup) repository frequency retention preBackupScript postBackupScript;
    serviceName = "${serviceName}";
    dataPath = cfg.dataDir or "/var/lib/${serviceName}";
  };
};
```

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
