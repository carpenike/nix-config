# ADR-010: Cross-Module Dependency Patterns

**Status**: Accepted
**Date**: December 19, 2025
**Context**: NixOS homelab configuration

## Context

As the repository grew, modules developed various ways of referencing each other. An audit revealed both valid patterns that enable powerful integrations and anti-patterns that cause evaluation failures, infinite recursion, or tight coupling.

The core challenge: NixOS module evaluation is lazy, but checking `config.modules.services.X.enable` without guards can trigger premature evaluation of module X's options, leading to infinite recursion or evaluation errors when module X isn't even enabled.

## Decision

Adopt standardized patterns for cross-module dependencies, with mandatory safe evaluation guards.

### Safe Evaluation Pattern

**Always** use `or false` when checking if another module is enabled:

```nix
# GOOD - safe evaluation, breaks recursion cycle
config.modules.services.postgresql.enable or false

# BAD - can cause infinite recursion or evaluation errors
config.modules.services.postgresql.enable
```

The `or false` pattern short-circuits evaluation: if the option doesn't exist or hasn't been defined yet, it returns `false` without forcing full evaluation of the referenced module.

### Valid Patterns

#### 1. Required Dependencies with Assertions

Use when: Service genuinely cannot function without the dependency.

```nix
# modules/nixos/services/dispatcharr/default.nix
config = lib.mkIf cfg.enable {
  assertions = [{
    assertion = config.modules.services.postgresql.enable or false;
    message = "dispatcharr requires postgresql to be enabled";
  }];

  # Service configuration...
};
```

- Provides clear error message at evaluation time
- Uses `or false` for safe evaluation
- Documents the hard dependency explicitly

#### 2. Optional Integration Validation

Use when: Integration is opt-in but requires both services when enabled.

```nix
# modules/nixos/services/teslamate/default.nix
options.modules.services.teslamate.grafanaIntegration.enable =
  lib.mkEnableOption "Grafana dashboard integration";

config = lib.mkIf cfg.enable {
  assertions = [{
    assertion = !cfg.grafanaIntegration.enable ||
                (config.modules.services.grafana.enable or false);
    message = "teslamate grafanaIntegration requires grafana to be enabled";
  }];
};
```

- Integration wrapped in explicit enable flag
- User opts in knowing both services needed
- Graceful: service works without integration

#### 3. Thin Orchestrator Wiring

Use when: Coordinating multiple related services as a stack.

```nix
# modules/nixos/services/observability/default.nix (≤200 lines)
options.modules.services.observability = {
  enable = lib.mkEnableOption "observability stack";
  enableLoki = lib.mkOption { default = true; };
  enablePromtail = lib.mkOption { default = true; };
};

config = lib.mkIf cfg.enable {
  # Component toggles only - no option re-exposure
  modules.services.loki.enable = lib.mkDefault cfg.enableLoki;
  modules.services.promtail.enable = lib.mkDefault cfg.enablePromtail;

  # Cross-cutting coordination
  modules.services.promtail.lokiUrl = lib.mkIf
    (config.modules.services.loki.enable or false)
    "http://localhost:3100";

  # Datasource registration
  modules.services.grafana.integrations.loki = lib.mkIf
    (config.modules.services.loki.enable or false)
    { url = "http://localhost:3100"; };
};
```

Constraints (per [ADR-009](./009-thin-orchestrator-pattern.md)):
- ~200 lines maximum
- Component toggles, NOT option re-exposure
- Cross-cutting concerns only (URLs, registration)
- Uses `mkDefault` for host-level overrides

#### 4. Safe Conditional Coordination

Use when: Services share resources requiring mutual exclusion or coordination.

```nix
# modules/nixos/services/qbit-manage/default.nix
config = lib.mkIf cfg.enable {
  # Only manage torrents if tqm isn't already doing it
  settings.manageTorrents = lib.mkDefault
    !(config.modules.services.tqm.enable or false);
};
```

- Graceful degradation when peer absent
- All checks use `or false`
- Sensible defaults either way

#### 5. Cross-Service Contribution Interfaces

Use when: Service provides integration points for other services.

```nix
# modules/nixos/services/postgresql/default.nix
config = lib.mkIf cfg.enable {
  # Triple-guarded contribution to grafana datasources
  modules.services.grafana.integrations.postgresql = lib.mkIf (
    (config.modules.services.grafana.enable or false) &&
    cfg.enableGrafanaIntegration  # Opt-in flag
  ) {
    type = "postgres";
    url = "localhost:5432";
  };
};
```

- Documented in [modular-design-patterns.md](../modular-design-patterns.md)
- Triple-guarded: `or false`, `mkIf`, and opt-in flag
- Infrastructure aggregates contributions

### Invalid Patterns (Anti-Patterns)

#### 1. Direct Contributions from Service Modules

**Bad**: Service directly contributes to unrelated service's namespace.

```nix
# BAD - in hosts/forge/services/myservice.nix
modules.services.gatus.contributions.myservice = { ... };
```

**Why**: Gatus contributions should be in host config or use the contribution pattern properly through infrastructure modules.

#### 2. Unguarded Enable Checks

**Bad**: Checking enable without `or false`.

```nix
# BAD - can cause infinite recursion
lib.mkIf config.modules.services.postgresql.enable { ... }
```

**Good**:

```nix
# GOOD - safe evaluation
lib.mkIf (config.modules.services.postgresql.enable or false) { ... }
```

#### 3. Assuming Options Exist

**Bad**: Referencing options that might not exist.

```nix
# BAD - crashes if grafana module not imported
config.modules.services.grafana.settings.someOption
```

**Good**: Use `or` with sensible defaults, or guard with enable check.

#### 4. God Modules

**Bad**: Orchestrator that re-exposes all underlying options.

```nix
# BAD - 2000-line module re-exposing everything
options.modules.services.media = {
  sonarr.enable = ...;
  sonarr.port = ...;
  sonarr.apiKey = ...;  # Re-exposing all sonarr options
  radarr.enable = ...;
  radarr.port = ...;
  # etc for 50 more options
};
```

**Good**: Keep orchestrators thin (~200 lines), only coordinate, don't re-expose.

## Consequences

### Positive

- **No evaluation failures**: `or false` prevents infinite recursion
- **Clear contracts**: Patterns document how modules may interact
- **Predictable behavior**: Services work independently by default
- **Maintainable**: Each pattern has clear use case and constraints

### Negative

- **Verbosity**: `or false` must be added to every cross-module check
- **Learning curve**: Contributors must understand when each pattern applies
- **Review burden**: PRs need checking for safe evaluation patterns

### Mitigations

- This ADR documents the patterns for reference
- PR template can include cross-module dependency checklist
- Existing modules serve as examples (sonarr, dispatcharr, teslamate)

## Pattern Selection Guide

| Scenario | Pattern | Example |
|----------|---------|---------|
| Service cannot function without X | Required dependency assertion | dispatcharr → postgresql |
| Optional feature needs X when enabled | Optional integration validation | teslamate → grafana |
| Coordinating related service stack | Thin orchestrator | observability stack |
| Peer services share resources | Safe conditional coordination | qbit-manage ↔ tqm |
| Service provides integration API | Contribution interfaces | postgresql → grafana datasource |

## Related

- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md) - Foundation for contributions
- [ADR-009: Thin Orchestrator Pattern](./009-thin-orchestrator-pattern.md) - Constraints on orchestrators
- [Modular Design Patterns](../modular-design-patterns.md) - Implementation details
