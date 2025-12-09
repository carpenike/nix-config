# ADR-003: Shared Types for Service Modules

**Status**: Accepted
**Date**: December 9, 2025
**Context**: NixOS service modules with standardized options

## Context

Service modules needed consistent option types for common patterns:

- Reverse proxy configuration
- Backup policies
- Metrics collection
- Logging configuration
- Notification channels

Initially, each module defined these types inline, leading to:

- 500+ lines of duplicated type definitions
- Inconsistent option structures across services
- Maintenance burden when patterns evolved

## Decision

Centralize shared type definitions in `lib/types.nix` and inject them via `mylib.types`.

### Implementation

```nix
# lib/types.nix
{ lib }:
{
  reverseProxySubmodule = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "reverse proxy";
      hostName = lib.mkOption { type = lib.types.str; };
      backend = lib.mkOption {
        type = lib.types.submodule {
          options = {
            scheme = lib.mkOption { type = lib.types.str; default = "http"; };
            host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };
            port = lib.mkOption { type = lib.types.port; };
          };
        };
      };
      # ... additional options
    };
  };

  backupSubmodule = lib.types.submodule { ... };
  metricsSubmodule = lib.types.submodule { ... };
  loggingSubmodule = lib.types.submodule { ... };
  notificationSubmodule = lib.types.submodule { ... };
}
```

```nix
# lib/default.nix
{
  types = import ./types.nix { inherit lib; };
}
```

```nix
# Any service module
{ lib, mylib, ... }:
let
  sharedTypes = mylib.types;
in
{
  options.modules.services.myservice = {
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration";
    };
  };
}
```

## Consequences

### Positive

- **Consistency**: All services use identical option structures
- **Single maintenance point**: Update type once, all services benefit
- **Type safety**: Submodules validate configuration at eval time
- **Documentation**: Types are self-documenting with descriptions

### Negative

- **Coupling**: All services depend on shared types
- **Migration effort**: Initial effort to update 59 modules

### Mitigations

- Types are additive (new options don't break existing configs)
- Use `lib.types.nullOr` for optional integrations
- Document available types in `docs/modular-design-patterns.md`

## Available Types

| Type | Purpose | Key Options |
|------|---------|-------------|
| `reverseProxySubmodule` | Caddy integration | `hostName`, `backend`, `auth`, `security` |
| `backupSubmodule` | Restic backup | `repository`, `paths`, `excludePatterns`, `useSnapshots` |
| `metricsSubmodule` | Prometheus scraping | `port`, `path`, `labels`, `scrapeInterval` |
| `loggingSubmodule` | Log shipping | `journalUnit`, `logFiles`, `parseFormat` |
| `notificationSubmodule` | Alert channels | `onFailure`, `onBackup`, `escalation` |

## Migration

The migration from inline types to shared types involved:

1. Creating `lib/types.nix` with consolidated definitions
2. Updating `lib/default.nix` to expose via `mylib.types`
3. Updating 59 service modules to use `mylib.types`
4. Adding `mylib` to function arguments in all modules

See `docs/repository-structure-refactor-plan.md` Phase 1 for details.

## Related

- [ADR-001: Contributory Pattern](./001-contributory-infrastructure-pattern.md) - Uses these types
- [Modular Design Patterns](../modular-design-patterns.md) - Type usage examples
