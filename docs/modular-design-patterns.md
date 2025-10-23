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

## Standardized Submodule Patterns

### 1. Reverse Proxy Integration

All web services should follow the Caddy virtualHosts pattern for consistent reverse proxy integration.

#### Pattern Structure
```nix
options.modules.services.<service>.reverseProxy = mkOption {
  type = types.nullOr (types.submodule {
    options = {
      enable = mkEnableOption "reverse proxy for this service";

      hostName = mkOption {
        type = types.str;
        description = "FQDN for this service";
        example = "service.holthome.net";
      };

      backend = mkOption {
        type = types.submodule {
          options = {
            scheme = mkOption {
              type = types.enum [ "http" "https" ];
              default = "http";
            };
            host = mkOption {
              type = types.str;
              default = "127.0.0.1";
            };
            port = mkOption {
              type = types.port;
              description = "Backend port";
            };
          };
        };
      };

      auth = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            user = mkOption { type = types.str; };
            passwordHashEnvVar = mkOption { type = types.str; };
          };
        });
        default = null;
      };
    };
  });
  default = null;
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

Services that expose metrics should use a standardized metrics submodule for automatic Prometheus integration.

#### Pattern Structure
```nix
options.modules.services.<service>.metrics = mkOption {
  type = types.nullOr (types.submodule {
    options = {
      enable = mkEnableOption "Prometheus metrics collection";

      port = mkOption {
        type = types.port;
        description = "Metrics endpoint port";
      };

      path = mkOption {
        type = types.str;
        default = "/metrics";
        description = "Metrics endpoint path";
      };

      scrapeInterval = mkOption {
        type = types.str;
        default = "60s";
        description = "How often Prometheus should scrape this target";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional labels for this scrape target";
        example = { environment = "production"; team = "infrastructure"; };
      };
    };
  });
  default = null;
};
```

#### Auto-Registration Implementation
```nix
config = mkIf cfg.enable {
  # Export metrics configuration for Prometheus discovery
  modules.observability.scrapeTargets."${serviceName}" = mkIf (cfg.metrics != null && cfg.metrics.enable) {
    inherit (cfg.metrics) port path scrapeInterval labels;
    target = "localhost:${toString cfg.metrics.port}";
    serviceName = "${serviceName}";
  };
};
```

### 3. Log Shipping Pattern

Services that produce logs should use a standardized logging submodule for automatic Promtail/Loki integration.

#### Pattern Structure
```nix
options.modules.services.<service>.logging = mkOption {
  type = types.nullOr (types.submodule {
    options = {
      enable = mkEnableOption "log shipping to Loki";

      logFiles = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Log files to ship to Loki";
      };

      journalUnit = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Systemd unit to collect journal logs from";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional labels for log streams";
      };

      parseFormat = mkOption {
        type = types.enum [ "json" "logfmt" "regex" "none" ];
        default = "none";
        description = "Log parsing format";
      };
    };
  });
  default = null;
};
```

#### Auto-Registration Implementation
```nix
config = mkIf cfg.enable {
  # Export logging configuration for Promtail discovery
  modules.observability.logSources."${serviceName}" = mkIf (cfg.logging != null && cfg.logging.enable) {
    inherit (cfg.logging) logFiles journalUnit labels parseFormat;
    serviceName = "${serviceName}";
  };
};
```

### 4. Backup Integration Pattern

Stateful services should use a standardized backup submodule for consistent backup policy management.

#### Pattern Structure
```nix
options.modules.services.<service>.backup = mkOption {
  type = types.nullOr (types.submodule {
    options = {
      enable = mkEnableOption "backups for this service";

      repository = mkOption {
        type = types.str;
        description = "Backup repository identifier";
        example = "primary";
      };

      frequency = mkOption {
        type = types.enum [ "hourly" "daily" "weekly" ];
        default = "daily";
        description = "Backup frequency";
      };

      retention = mkOption {
        type = types.submodule {
          options = {
            daily = mkOption { type = types.int; default = 7; };
            weekly = mkOption { type = types.int; default = 4; };
            monthly = mkOption { type = types.int; default = 6; };
          };
        };
        default = {};
        description = "Backup retention policy";
      };

      preBackupScript = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Script to run before backup (e.g., database dump)";
      };

      postBackupScript = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Script to run after backup";
      };
    };
  });
  default = null;
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

Services should use a standardized notification submodule for consistent alerting and status reporting.

#### Pattern Structure
```nix
options.modules.services.<service>.notifications = mkOption {
  type = types.nullOr (types.submodule {
    options = {
      enable = mkEnableOption "notifications for this service";

      channels = mkOption {
        type = types.submodule {
          options = {
            onFailure = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for service failures";
              example = [ "gotify-critical" "slack-alerts" ];
            };

            onSuccess = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for successful operations";
            };

            onBackup = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for backup events";
            };
          };
        };
        default = {};
      };

      customMessages = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Custom message templates";
        example = {
          failure = "Service \${serviceName} failed on \${hostname}";
          success = "Service \${serviceName} completed successfully";
        };
      };
    };
  });
  default = null;
};
```

### 6. Container Resource Management Pattern

Podman-based services should use a standardized resource management submodule.

#### Pattern Structure
```nix
options.modules.services.<service>.container = mkOption {
  type = types.submodule {
    options = {
      image = mkOption {
        type = types.str;
        description = "Container image";
      };

      tag = mkOption {
        type = types.str;
        default = "latest";
        description = "Container image tag";
      };

      resources = mkOption {
        type = types.submodule {
          options = {
            memory = mkOption {
              type = types.str;
              description = "Memory limit (e.g., '256m', '2g')";
            };

            memoryReservation = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Memory soft limit/reservation";
            };

            cpus = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "CPU limit (e.g., '0.5', '2')";
            };

            cpuQuota = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "CPU quota percentage (e.g., '50%')";
            };
          };
        };
      };

      healthcheck = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            test = mkOption {
              type = types.listOf types.str;
              description = "Health check command";
              example = [ "CMD" "curl" "-f" "http://localhost:8080/health" ];
            };

            interval = mkOption {
              type = types.str;
              default = "30s";
            };

            timeout = mkOption {
              type = types.str;
              default = "10s";
            };

            retries = mkOption {
              type = types.int;
              default = 3;
            };

            startPeriod = mkOption {
              type = types.str;
              default = "60s";
            };
          };
        });
        default = null;
      };

      security = mkOption {
        type = types.submodule {
          options = {
            readOnlyRootFilesystem = mkOption {
              type = types.bool;
              default = true;
            };

            noNewPrivileges = mkOption {
              type = types.bool;
              default = true;
            };

            user = mkOption {
              type = types.nullOr types.str;
              default = null;
            };

            group = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
          };
        };
        default = {};
      };
    };
  };
};
```

## Implementation Guidelines

### Module Structure Template

Every service module should follow this structure:

```nix
# Service module template
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.modules.services.<service>;
  serviceName = "<service>";
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

    # Standardized integration submodules
    reverseProxy = /* ... */;
    metrics = /* ... */;
    logging = /* ... */;
    backup = /* ... */;
    notifications = /* ... */;
    container = /* ... */;  # If containerized
  };

  config = mkIf cfg.enable {
    # Core service implementation
    systemd.services."${serviceName}" = {
      description = "<Service> service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/${serviceName}";
        Restart = "always";
        User = serviceName;
        Group = serviceName;

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

    # Auto-registration with infrastructure systems
    modules.services.caddy.virtualHosts."${serviceName}" = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = cfg.reverseProxy.backend;
      auth = cfg.reverseProxy.auth;
    };

    modules.observability.scrapeTargets."${serviceName}" = mkIf (cfg.metrics != null && cfg.metrics.enable) {
      target = "localhost:${toString cfg.metrics.port}";
      inherit (cfg.metrics) path scrapeInterval labels;
    };

    # Additional auto-registrations for logging, backup, notifications...
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

### Helper Functions

Create reusable helper functions in `lib/` for common patterns:

- `lib/container.nix` - Container configuration helpers
- `lib/security.nix` - Security hardening templates
- `lib/monitoring.nix` - Metrics and logging configuration
- `lib/backup.nix` - Backup job generation

## Migration Strategy

### Phase 1: Documentation and Standards
1. ✅ Document patterns (this document)
2. Update CLAUDE.md with pattern requirements
3. Create helper libraries

### Phase 2: Infrastructure Implementation
1. Implement automatic Prometheus config generation
2. Implement automatic Promtail config generation
3. Create centralized notification system
4. Enhance backup orchestration

### Phase 3: Service Migration
1. Audit existing services for compliance
2. Migrate high-priority services first
3. Deprecate legacy patterns
4. Update all remaining services

### Phase 4: Validation and Testing
1. Implement module validation tests
2. Add integration tests for auto-registration
3. Document troubleshooting guides

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
