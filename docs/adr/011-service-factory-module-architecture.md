# ADR-011: Service Factory and Module Architecture

**Status**: Accepted
**Date**: January 23, 2026
**Context**: NixOS homelab service configuration with service factory pattern

## Context

With the introduction of `lib/service-factory.nix`, a question arose: should we consolidate from a two-layer architecture to a single-layer approach for factory-based container services?

### Current Architecture (Two Layers)

```
modules/nixos/services/sonarr/default.nix  →  Defines spec, options, calls factory
hosts/forge/services/sonarr.nix            →  Enables module, adds storage/backup/alerts
```

### Proposed Alternative (Single Layer)

```
hosts/forge/services/sonarr.nix  →  Everything: spec, factory call, storage, backup, alerts
```

### Arguments for Consolidation

1. Factory already provides the abstraction (container config, health checks, integration)
2. Module layer appears to add indirection without proportional value
3. Most services are forge-only, so reusability seems theoretical
4. Changes often touch both files anyway

### Discovery: Cross-Service Dependencies

Investigation revealed **20+ places** in the codebase checking `config.modules.services.X.enable`:

```nix
# Cross-service dependencies
config.modules.services.qbittorrent.enable or false  # qbit-manage → qbittorrent
config.modules.services.postgresql.enable or false   # dispatcharr assertion
config.modules.services.grafana.enable or false      # auto-integration

# Observability auto-wiring
config.modules.services.loki.enable or false         # grafana datasource
config.modules.services.pocketid.enable or false     # OIDC integration
```

These are used for:
- Cross-service dependencies (qbit-manage → qbittorrent, qbit-manage → tqm)
- Grafana auto-integration (postgresql → grafana datasource)
- Assertions (dispatcharr requires postgresql, teslamate requires grafana)
- Observability stack auto-wiring
- Host-level `serviceEnabled` guards

## Decision

**Keep the two-layer architecture** (modules/ + hosts/) for factory-based services.

The module layer's value is not philosophical "definition vs instantiation" separation, but rather the concrete benefit of providing a **queryable service registry** via the NixOS option namespace.

### Layer Responsibilities

| Layer | Responsibility |
|-------|----------------|
| **Factory** (`lib/service-factory.nix`) | Container mechanics: image, volumes, health checks, networking, labels |
| **Module** (`modules/nixos/services/X/`) | Service registry: exposes `enable` option, holds spec, enables cross-service discovery |
| **Host** (`hosts/X/services/Y.nix`) | Instantiation: enables service, configures storage/backup/alerts |

### Why Not Consolidate?

Without the module layer defining `config.modules.services.X.enable`:

1. **No queryable namespace** — Other modules cannot discover which services are enabled
2. **Manual registry required** — Would need `services.enabledList = [ "postgresql" ... ]` which is brittle
3. **Breaks composability** — Modules would need explicit dependencies passed in, creating tight coupling

## Consequences

### Positive

- **Service discovery**: Modules can query `config.modules.services.X.enable` to auto-wire integrations
- **Decoupled composability**: Grafana doesn't care *how* PostgreSQL runs, just whether it's enabled
- **Type safety**: NixOS module system validates option types
- **Future flexibility**: Easy to add services to additional hosts

### Negative

- **Two files per service**: Module + host file (acceptable overhead)
- **Indirection**: Must trace through both files to understand full configuration

### Mitigations

- Factory handles most complexity, keeping modules minimal (~30-50 lines)
- Clear separation: module = "what the service is", host = "where and how it runs"
- Document the pattern so future maintainers understand the architecture

## Related

- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md)
- [ADR-009: Thin Orchestrator Pattern](./009-thin-orchestrator-pattern.md)
- [Modular Design Patterns](../modular-design-patterns.md)
- `lib/service-factory.nix` - The factory implementation
- `lib/types/service-spec.nix` - Service spec schema
