# ADR-001: Contributory Infrastructure Pattern

**Status**: Accepted
**Date**: December 9, 2025
**Context**: NixOS homelab configuration

## Context

As the homelab grew to 80+ services, a pattern emerged where services needed to integrate with shared infrastructure (reverse proxy, backup, monitoring, alerting). The traditional approach of configuring everything in infrastructure modules led to:

- Large, monolithic infrastructure files
- Merge conflicts when multiple services changed
- Difficulty understanding what a service requires
- Risk of forgetting to add backup/monitoring for new services

## Decision

Adopt a **contributory pattern** where services declare their infrastructure needs, and infrastructure modules aggregate these contributions.

### Pattern Structure

```nix
# Service module (e.g., modules/nixos/services/sonarr/default.nix)
config = lib.mkIf cfg.enable {
  # Contribute to Caddy reverse proxy
  modules.services.caddy.virtualHosts.sonarr = {
    hostName = "sonarr.example.com";
    backend = { port = 8989; };
  };

  # Contribute backup policy
  modules.backup.sanoid.datasets."tank/services/sonarr" = {
    useTemplate = [ "services" ];
  };

  # Contribute alert rules
  modules.alerting.rules."sonarr-down" = {
    expr = ''container_service_active{name="sonarr"} == 0'';
    severity = "high";
  };
};
```

```nix
# Infrastructure module (e.g., modules/nixos/services/caddy/default.nix)
options.modules.services.caddy.virtualHosts = lib.mkOption {
  type = lib.types.attrsOf virtualHostType;
  default = {};
  description = "Virtual hosts contributed by services";
};

config = lib.mkIf cfg.enable {
  # Generate Caddyfile from all contributions
  services.caddy.configFile = generateCaddyfile cfg.virtualHosts;
};
```

## Consequences

### Positive

- **Self-documenting**: Reading a service module shows all its infrastructure requirements
- **Reduced merge conflicts**: Services don't share files
- **Completeness**: Adding infrastructure is part of adding a service
- **Discoverability**: `rg "modules.alerting.rules"` finds all alerts

### Negative

- **Requires documentation**: Pattern is non-obvious to newcomers
- **Discovery tools needed**: Must use grep/rg to find all contributions
- **Implicit dependencies**: Service depends on infrastructure module existing

### Mitigations

- Document pattern in `docs/repository-architecture.md`
- Provide examples in `docs/modular-design-patterns.md`
- Use consistent option naming across all contributory systems

## Systems Using This Pattern

| System | Option Path | Purpose |
|--------|-------------|---------|
| Caddy | `modules.services.caddy.virtualHosts.*` | Reverse proxy routes |
| Backup | `modules.backup.sanoid.datasets.*` | ZFS snapshot policies |
| Alerting | `modules.alerting.rules.*` | Prometheus alert rules |
| Gatus | `modules.services.gatus.contributions.*` | Health check endpoints |
| Grafana | `modules.services.grafana.integrations.*` | Datasources and dashboards |
| Impermanence | `modules.system.impermanence.directories` | Persistence paths |

## Related

- [ADR-003: Shared Types](./003-shared-types-for-service-modules.md) - Types for contribution options
- [Modular Design Patterns](../modular-design-patterns.md) - Implementation details
