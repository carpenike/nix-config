# ADR-011: Service Factory and Module Architecture

**Status**: Accepted
**Date**: January 23, 2026
**Amended**: July 17, 2026
**Context**: NixOS homelab service configuration with service factory pattern

## Context

With the introduction of `lib/service-factory.nix`, a question arose: should we consolidate from a two-layer architecture to a single-layer approach for factory-based container services?

### Current Architecture (Two Layers)

```text
modules/nixos/services/sonarr/default.nix  →  Defines spec, options, calls factory
hosts/forge/services/sonarr.nix            →  Enables module, adds storage/backup/alerts
```

### Proposed Alternative (Single Layer)

```text
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

The 2026 service-contract pilot extends this decision across native NixOS
modules, custom systemd services, and OCI containers:

- Preserve one typed `modules.services.<name>` registry regardless of runtime.
- Share only runtime-neutral capability option fragments.
- Keep each runtime implementation explicit in its owning service module.
- Publish typed internal runtime facts for integrations that need unit,
  endpoint, identity, or state-path information.
- Keep host-specific pins, resource budgets, storage protection, backups, and
  alerts in host modules.

The pilot covered Actual (native NixOS module), Sonarr (OCI factory), and
Cooklang (custom systemd). Focused evaluated output was identical before and
after the change for all three services.

### Layer Responsibilities

| Layer | Responsibility |
| --- | --- |
| **Capability fragments** (`lib/service-options.nix`) | Runtime-neutral option declarations for base, web, and state capabilities |
| **Runtime adapter** | Explicit native-module, custom-systemd, or OCI implementation and internal runtime facts |
| **Module** (`modules/nixos/services/X/`) | Service registry, application semantics, and runtime adapter ownership |
| **Host** (`hosts/X/services/Y.nix`) | Instantiation, version/image pin, storage protection, backup, and alerts |

The OCI factory remains a runtime adapter for conventional single-container
services. Its `operationalProfile` selects alert, NFS, label, and backup-tag
defaults; it is not a service import category or a universal service model.

### Runtime Facts

Enabled adapters publish internal metadata under
`modules.services.<name>._runtime`:

- Runtime kind
- Owned systemd units
- Named endpoints
- Process identity
- Persistent state paths

Host modules do not set these values. Shared integrations may consume them when
doing so removes naming assumptions without adding backend branches.

### No Universal Factory

Native NixOS modules, custom systemd units, and OCI containers have materially
different lifecycle, credential, user, state, and debugging behavior. Do not
route all three through one implementation function. Capability fragments share
the public vocabulary; runtime adapters remain visible.

Do not add a general `deploymentMode` option. Dual backends are limited to a
temporary migration, an unresolved upstream incompatibility, or a host
capability that genuinely changes the correct runtime.

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
- **Cross-runtime consistency**: Shared capabilities use the same option
  vocabulary without hiding backend behavior
- **Explicit integration facts**: Consumers no longer need to infer every unit
  or endpoint from naming conventions

### Negative

- **Two files per service**: Module + host file (acceptable overhead)
- **Indirection**: Must trace through both files to understand full configuration
- **Fragment discipline required**: A shared fragment must not become a union of
  every backend's options

### Mitigations

- Factory handles most complexity, keeping modules minimal (~30-50 lines)
- Clear separation: module = "what the service is", host = "where and how it runs"
- Document the pattern so future maintainers understand the architecture
- Add a fragment only after at least two runtimes demonstrate the same option
  contract
- Keep application-specific and backend-specific behavior local

## Related

- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md)
- [ADR-009: Thin Orchestrator Pattern](./009-thin-orchestrator-pattern.md)
- [Modular Design Patterns](../modular-design-patterns.md)
- `lib/service-options.nix` - Runtime-neutral capability option fragments
- `lib/service-factory.nix` - The factory implementation
- `lib/types/service-spec.nix` - Service spec schema
