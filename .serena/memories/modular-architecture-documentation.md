# Service Module Architecture Documentation

## Overview

This Nix configuration implements a sophisticated modular architecture for infrastructure services with standardized patterns for cross-cutting concerns like networking, monitoring, storage, and backup.

## Core Design Principles

### 1. Single Responsibility Pattern
Each service module handles only core service configuration. Integration with infrastructure concerns is handled by specialized integration modules.

### 2. Standardized Submodule Types
Three core submodule types provide consistent interfaces across all services:

#### Metrics Submodule
```nix
metrics = lib.mkOption {
  type = lib.types.nullOr lib.types.attrs;
  default = {
    enable = true;
    port = <service-port>;
    path = "/metrics";
    labels = {
      service_type = "<category>";
      exporter = "<exporter-name>";
    };
  };
  description = "Prometheus metrics collection configuration";
};
```

#### Reverse Proxy Submodule
```nix
reverseProxy = lib.mkOption {
  type = lib.types.nullOr lib.types.attrs;
  default = null;
  description = "Reverse proxy configuration for external access";
};
```

#### Backup Submodule
```nix
backup = lib.mkOption {
  type = lib.types.nullOr lib.types.attrs;
  default = {
    enable = true;
    repository = "primary";
    frequency = "daily";
    tags = [ "service-name" "category" ];
    paths = [ "/var/lib/service" ];
    preBackupScript = "";
    postBackupScript = "";
  };
  description = "Backup configuration for service data";
};
```

### 3. Auto-Discovery and Registration
Integration modules automatically discover and configure services based on these standardized submodules:

- **Observability Module**: Scans all services for `metrics` submodules and auto-generates Prometheus scrape configs
- **Backup Integration Module**: Discovers services with `backup` submodules and creates Restic backup jobs
- **Caddy Module**: Auto-registers services with `reverseProxy` submodules as virtual hosts

## Implementation Examples

### Complete Service Module Pattern
```nix
# modules/nixos/services/example/default.nix
{ lib, pkgs, config, ... }:
let
  cfg = config.modules.services.example;
in
{
  options.modules.services.example = {
    enable = lib.mkEnableOption "example service";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Service port";
    };

    # Standardized integration submodules
    metrics = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = {
        enable = true;
        port = 8080;
        path = "/metrics";
        labels = {
          service_type = "application";
          exporter = "example";
        };
      };
      description = "Prometheus metrics configuration";
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = "Reverse proxy configuration";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = {
        enable = true;
        repository = "primary";
        frequency = "daily";
        tags = [ "example" "application" ];
        paths = [ "/var/lib/example" ];
      };
      description = "Backup configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Core service implementation
    systemd.services.example = {
      description = "Example Service";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.example}/bin/example --port ${toString cfg.port}";
        Restart = "always";
        User = "example";
      };
    };

    # Auto-register with Caddy if reverse proxy enabled
    modules.services.caddy.virtualHosts.example = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName or "example.${config.networking.domain}";
      backend = cfg.reverseProxy.backend or {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };
      auth = cfg.reverseProxy.auth or null;
    };

    # User and permissions
    users.users.example = {
      isSystemUser = true;
      group = "example";
      home = "/var/lib/example";
      createHome = true;
    };
    users.groups.example = {};
  };
}
```

### Host Configuration Usage
```nix
# hosts/luna/default.nix
{
  modules.services = {
    example = {
      enable = true;
      port = 8080;

      # Enable reverse proxy with authentication
      reverseProxy = {
        enable = true;
        hostName = "example.holthome.net";
        auth = {
          basicAuth = {
            users = {
              admin = "$2y$10$hashed_password";
            };
          };
        };
      };

      # Customize backup settings
      backup = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "example" "critical" ];
        preBackupScript = ''
          # Flush service state before backup
          systemctl kill -s USR1 example
        '';
      };
    };
  };
}
```

## Auto-Discovery Implementation

### Observability Auto-Discovery
The observability module scans all `modules.services.*` configurations:

```nix
# Simplified auto-discovery logic from observability module
discoverMetricsTargets = config:
  let
    allServices = config.modules.services or {};
    servicesWithMetrics = lib.filterAttrs (name: service:
      (service.metrics or null) != null &&
      (service.metrics.enable or false)
    ) allServices;
  in
    lib.mapAttrsToList (serviceName: service: {
      job_name = "service-${serviceName}";
      static_configs = [{
        targets = [ "localhost:${toString service.metrics.port}" ];
        labels = service.metrics.labels // { service = serviceName; };
      }];
      metrics_path = service.metrics.path or "/metrics";
    }) servicesWithMetrics;
```

### Backup Auto-Discovery
The backup integration module follows the same pattern:

```nix
# Simplified backup discovery from backup-integration module
discoverServiceBackups = config:
  let
    allServices = config.modules.services or {};
    servicesWithBackup = lib.filterAttrs (name: service:
      (service.backup or null) != null &&
      (service.backup.enable or false)
    ) allServices;
  in
    lib.mapAttrsToList (serviceName: service: {
      name = "service-${serviceName}";
      config = {
        enable = true;
        repository = service.backup.repository;
        tags = [ serviceName ] ++ (service.backup.tags or []);
        paths = service.backup.paths or [ "/var/lib/${serviceName}" ];
        schedule = service.backup.frequency;
        preBackupScript = service.backup.preBackupScript or "";
        postBackupScript = service.backup.postBackupScript or "";
      };
    }) servicesWithBackup;
```

## Integration Modules

### Key Integration Modules
1. **`backup-integration.nix`**: Auto-discovers service backup configs and creates Restic jobs
2. **`observability/default.nix`**: Auto-discovers metrics endpoints and configures Prometheus
3. **`caddy/default.nix`**: Auto-registers reverse proxy configs as virtual hosts

### Benefits of This Architecture
- **Consistency**: All services follow the same patterns
- **Automation**: No manual configuration of cross-cutting concerns
- **Maintainability**: Service modules focus only on service-specific logic
- **Flexibility**: Can opt-out of auto-discovery for custom configurations
- **Type Safety**: Nix evaluation catches configuration errors early

## Migration Guide

### Converting Existing Services
1. **Extract Integration Logic**: Move reverse proxy, metrics, and backup config to standardized submodules
2. **Update Options**: Use the standardized submodule types
3. **Remove Manual Registration**: Let auto-discovery handle Prometheus and backup configuration
4. **Test Auto-Discovery**: Verify that services are automatically discovered by integration modules

### Validation
Run `/nix-validate` to ensure all services follow the standardized patterns and that auto-discovery is working correctly.

## Future Enhancements

### Planned Additions
1. **Notification Submodule**: Standardized alerting and notification configuration
2. **Storage Submodule**: Automated ZFS dataset and volume management
3. **Security Submodule**: Consistent security policies and systemd hardening
4. **Health Check Submodule**: Standardized health monitoring patterns

This architecture provides a solid foundation for managing complex infrastructure services while maintaining consistency, automation, and type safety across the entire configuration.
