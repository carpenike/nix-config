# Metrics Pattern Usage Guide

This guide demonstrates how to use the new standardized metrics collection pattern that enables automatic Prometheus discovery.

## Overview

The standardized metrics pattern eliminates manual Prometheus configuration by allowing services to declare their metrics endpoints declaratively. When a service enables `metrics.enable = true`, it automatically appears in the Prometheus scrape configuration.

## Basic Usage

### 1. Import Shared Types

In your service module, import the shared type definitions:

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.services.myservice;
  # Import shared type definitions
  sharedTypes = import ../../lib/types.nix { inherit lib; };
in
{
  options.modules.services.myservice = {
    enable = lib.mkEnableOption "My Service";

    # Add standardized metrics submodule
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 9100;
        path = "/metrics";
        labels = {
          service_type = "monitoring";
          exporter = "node";
        };
      };
      description = "Prometheus metrics collection configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Your service implementation here
    # Metrics auto-registration happens automatically
  };
}
```

### 2. Service Implementation Example

Here's how the Glances service was migrated to use the new pattern:

```nix
# Before (manual configuration required)
modules.services.caddy.virtualHosts.glances = {
  enable = true;
  hostName = "glances.holthome.net";
  proxyTo = "localhost:61208";
};

# After (automatic registration)
modules.services.glances = {
  enable = true;
  metrics = {
    enable = true;
    port = 61208;
    path = "/api/3/metrics";
    labels = {
      service_type = "system_monitoring";
      exporter = "glances";
    };
  };
  reverseProxy = {
    enable = true;
    hostName = "glances.holthome.net";
    backend = {
      port = 61208;
    };
  };
};
```

## Available Options

### Metrics Submodule Options

```nix
metrics = {
  enable = true;                    # Enable metrics collection
  port = 9090;                      # Metrics endpoint port
  path = "/metrics";                # HTTP path (default: /metrics)
  interface = "127.0.0.1";          # Bind interface (default: 127.0.0.1)
  scrapeInterval = "60s";           # How often to scrape (default: 60s)
  scrapeTimeout = "10s";            # Scrape timeout (default: 10s)

  labels = {                        # Additional static labels
    service_type = "database";
    team = "infrastructure";
    environment = "production";
  };

  relabelConfigs = [                # Advanced relabeling
    {
      source_labels = [ "__name__" ];
      regex = "^go_.*";
      action = "drop";              # Drop Go runtime metrics
    }
  ];
};
```

### Reverse Proxy Submodule Options

```nix
reverseProxy = {
  enable = true;
  hostName = "service.holthome.net";

  backend = {
    scheme = "http";                # or "https"
    host = "127.0.0.1";            # Backend host
    port = 8080;                   # Backend port

    tls = {                        # For HTTPS backends
      verify = true;               # Verify TLS cert
      sni = "override.example.com"; # SNI override
      caFile = "/path/to/ca.pem";  # Custom CA
    };
  };

  auth = {                         # Basic authentication
    user = "admin";
    passwordHashEnvVar = "SERVICE_PASSWORD_HASH";
  };

  security = {
    hsts = {
      enable = true;               # Enable HSTS (default: true)
      maxAge = 15552000;          # 6 months (default)
      includeSubDomains = true;   # Include subdomains
      preload = false;            # HSTS preload
    };

    customHeaders = {              # Additional security headers
      "X-Frame-Options" = "SAMEORIGIN";
      "X-Content-Type-Options" = "nosniff";
    };
  };

  extraConfig = ''                 # Additional Caddy directives
    # Custom configuration here
  '';
};
```

## How Auto-Discovery Works

### 1. Service Declaration

When a service declares metrics configuration:

```nix
modules.services.myapp = {
  enable = true;
  metrics = {
    enable = true;
    port = 8080;
    path = "/metrics";
  };
};
```

### 2. Automatic Registration

The observability module scans all service configurations and generates Prometheus scrape configs:

```yaml
# Generated Prometheus configuration
scrape_configs:
  - job_name: "service-myapp"
    static_configs:
      - targets: ["127.0.0.1:8080"]
        labels:
          service: "myapp"
          instance: "luna"
          __metrics_path__: "/metrics"
    scrape_interval: "60s"
    scrape_timeout: "10s"
    metrics_path: "/metrics"
```

### 3. Discovery Process

1. **Evaluation Time**: The observability module calls `discoverMetricsTargets config`
2. **Scanning**: Function scans `config.modules.services.*` for enabled metrics
3. **Generation**: Creates Prometheus scrape configurations automatically
4. **Integration**: Configurations are merged with any static targets

## Best Practices

### 1. Consistent Labeling

Use consistent label schemes across services:

```nix
labels = {
  service_type = "database";      # database, web, monitoring, cache
  team = "infrastructure";        # owning team
  environment = "production";     # production, staging, development
  tier = "critical";             # critical, important, standard
};
```

### 2. Appropriate Scrape Intervals

Choose intervals based on service characteristics:

```nix
# High-frequency monitoring (databases, load balancers)
scrapeInterval = "15s";

# Standard monitoring (web services)
scrapeInterval = "60s";

# Low-frequency monitoring (batch jobs)
scrapeInterval = "300s";
```

### 3. Security Considerations

Always bind metrics to localhost and use reverse proxy for external access:

```nix
metrics = {
  interface = "127.0.0.1";  # Never bind to 0.0.0.0
  port = 9090;
};

reverseProxy = {
  enable = true;
  auth = {                  # Require authentication
    user = "monitor";
    passwordHashEnvVar = "METRICS_PASSWORD_HASH";
  };
};
```

### 4. Resource Monitoring

Include resource-related labels for capacity planning:

```nix
labels = {
  resource_tier = "high_memory";    # high_memory, high_cpu, standard
  scaling_group = "web_servers";    # logical grouping for scaling
};
```

## Troubleshooting

### 1. Service Not Appearing in Prometheus

Check if metrics are properly configured:

```bash
# Verify service has metrics enabled
nix eval .#nixosConfigurations.luna.config.modules.services.myservice.metrics.enable

# Check discovered targets
nix eval .#nixosConfigurations.luna.config.services.prometheus.scrapeConfigs --json
```

### 2. Scrape Failures

Common issues and solutions:

- **Connection refused**: Check if service is running and port is correct
- **404 errors**: Verify metrics path is correct
- **Authentication failures**: Ensure no auth required for metrics endpoint
- **Timeout errors**: Increase scrapeTimeout or optimize metrics generation

### 3. Missing Labels

Verify label configuration:

```bash
# Check service metrics configuration
nix eval .#nixosConfigurations.luna.config.modules.services.myservice.metrics.labels --json
```

## Migration from Manual Configuration

### Before (Manual Prometheus Config)

```nix
services.prometheus.scrapeConfigs = [
  {
    job_name = "myservice";
    static_configs = [{
      targets = [ "localhost:8080" ];
    }];
  }
];
```

### After (Automatic Discovery)

```nix
modules.services.myservice = {
  enable = true;
  metrics = {
    enable = true;
    port = 8080;
  };
};

# Prometheus configuration is generated automatically
```

This new pattern eliminates configuration drift and ensures all services are consistently monitored without manual intervention.
