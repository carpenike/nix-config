# ADR-009: Thin Orchestrator Pattern for Service Stacks

**Status**: Accepted
**Date**: December 9, 2025
**Context**: NixOS homelab module design for multi-service stacks

## Context

Some services work together as cohesive stacks:

- **Observability**: Loki + Promtail + Grafana + Prometheus
- **Media automation**: Sonarr + Radarr + SABnzbd + Plex

The question is how to organize the NixOS modules for these stacks.

### The "God Module" Anti-Pattern

An early approach was to create meta-modules that re-expose all options from underlying services:

```nix
# BAD: God module that proxies everything
options.modules.services.observability = {
  loki = {
    port = mkOption { ... };
    retentionDays = mkOption { ... };
    storagePath = mkOption { ... };
    # ... 50 more options copied from loki module
  };
  grafana = {
    port = mkOption { ... };
    oidc = mkOption { ... };
    # ... 100 more options copied from grafana module
  };
};
```

This approach has significant problems:

- **Dual maintenance**: Options defined in two places
- **Documentation drift**: Meta-module docs diverge from underlying modules
- **Type synchronization**: Changes in underlying module break meta-module
- **Obscures direct usage**: Users forget they can configure services directly

## Decision

**Use a "thin orchestrator" pattern that only provides cross-cutting concerns, not option re-exposure.**

### Thin Orchestrator Responsibilities

1. **Master enable toggle** - Turn the whole stack on/off
2. **Component toggles** - Enable/disable individual services
3. **Cross-cutting wiring** - Connections between services (Promtail → Loki URL)
4. **Stack-level concerns** - Auto-discovery, shared alerts

### What Thin Orchestrators Do NOT Do

- ❌ Re-expose individual service options
- ❌ Create wrapper types for underlying options
- ❌ Document options that belong to underlying modules

## Consequences

### Positive

- **No option duplication**: Options defined once in service modules
- **Clear separation**: Orchestrator handles wiring, services handle config
- **Smaller code**: Observability orchestrator is ~190 lines (vs 876 god-module)
- **Direct customization**: Users configure services directly when needed
- **Easier maintenance**: Changes to Loki don't break orchestrator

### Negative

- **Two-level configuration**: Enable via orchestrator, customize via service
- **Discovery challenge**: Users must know they can configure services directly
- **Wiring complexity**: Cross-service dependencies explicitly managed

### Mitigations

- Document the pattern clearly in README
- Provide examples showing orchestrator + direct configuration
- Use `mkDefault` for orchestrator-provided values (user overridable)

## Implementation

### Thin Orchestrator Structure

```nix
{ config, lib, ... }:
let
  cfg = config.modules.services.observability;
in
{
  options.modules.services.observability = {
    enable = lib.mkEnableOption "observability stack";

    # Component toggles ONLY - no option re-exposure
    loki.enable = lib.mkOption { type = lib.types.bool; default = cfg.enable; };
    promtail.enable = lib.mkOption { type = lib.types.bool; default = cfg.enable; };
    grafana.enable = lib.mkOption { type = lib.types.bool; default = cfg.enable; };
    prometheus.enable = lib.mkOption { type = lib.types.bool; default = false; };

    # Stack-level concerns only
    autoDiscovery.enable = lib.mkOption { type = lib.types.bool; default = true; };
  };

  config = lib.mkIf cfg.enable {
    # Enable services - they configure themselves
    modules.services.loki.enable = cfg.loki.enable;
    modules.services.promtail.enable = cfg.promtail.enable;
    modules.services.grafana.enable = cfg.grafana.enable;

    # Cross-cutting wiring
    modules.services.promtail.lokiUrl = lib.mkIf (cfg.promtail.enable && cfg.loki.enable)
      "http://127.0.0.1:${toString config.modules.services.loki.port}";

    # Auto-configure Grafana datasources
    modules.services.grafana.autoConfigure = {
      loki = lib.mkDefault cfg.loki.enable;
      prometheus = lib.mkDefault cfg.prometheus.enable;
    };
  };
}
```

### Host-Level Usage

```nix
# Enable stack with thin orchestrator
modules.services.observability.enable = true;

# Customize individual services DIRECTLY (not through orchestrator)
modules.services.loki.retention = 30;
modules.services.grafana.oidc = { ... };
modules.services.promtail.extraScrapeConfigs = [ ... ];
```

## When to Use Thin Orchestrators

✅ **Use when**:

- Multiple services form a logical stack
- Services need wiring between each other
- You want a simple "enable the whole stack" toggle
- Cross-cutting concerns need coordination

❌ **Don't use when**:

- Services are independent
- No cross-service wiring needed
- Simple host-level config suffices

## Reference Implementation

- **Observability Stack**: `modules/nixos/services/observability/default.nix`
  - ~190 lines (vs 876 in god-module version)
  - Enables: Loki, Promtail, Grafana, optionally Prometheus
  - Wires: Promtail → Loki, Grafana datasources
  - Provides: Auto-discovery of metrics endpoints

## Related

- [Modular Design Patterns](../modular-design-patterns.md#thin-orchestrator-pattern-multi-service-stacks)
- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md)
- [ADR-003: Shared Types for Service Modules](./003-shared-types-for-service-modules.md)
- [ADR-011: Service Factory and Module Architecture](./011-service-factory-module-architecture.md) - Explains why modules provide service registry
