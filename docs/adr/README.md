# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records documenting significant design choices in this repository.

## What is an ADR?

An ADR captures a decision that has significant impact on the architecture, along with the context and consequences. They help future maintainers understand *why* things are the way they are.

## ADR Index

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [001](./001-contributory-infrastructure-pattern.md) | Contributory Infrastructure Pattern | Accepted | Services declare infrastructure needs; infrastructure aggregates |
| [002](./002-host-level-defaults-library.md) | Host-Level Defaults Library | Accepted | Parameterized factory for host-specific helper functions |
| [003](./003-shared-types-for-service-modules.md) | Shared Types for Service Modules | Accepted | Centralized type definitions via `mylib.types` |
| [004](./004-impermanence-host-level-control.md) | Impermanence Host-Level Control | Accepted | Hosts control service persistence, not modules |
| [005](./005-native-services-over-containers.md) | Native Services Over Containers | Accepted | Prefer NixOS modules over OCI containers when available |
| [006](./006-black-box-white-box-monitoring.md) | Black-Box vs White-Box Monitoring | Accepted | Gatus for availability, Prometheus for internals |
| [007](./007-multi-tier-disaster-recovery.md) | Multi-Tier Disaster Recovery | Accepted | Preseed pattern with Syncoid → Local → (Restic) priority |
| [008](./008-authentication-priority-framework.md) | Authentication Priority Framework | Accepted | OIDC → Headers → Disable+Caddy → Built-in auth priority |
| [009](./009-thin-orchestrator-pattern.md) | Thin Orchestrator Pattern | Accepted | Lightweight stack modules without option re-exposure |
| [010](./010-cross-module-dependency-patterns.md) | Cross-Module Dependency Patterns | Accepted | Safe patterns for inter-module references with `or false` guards |

## ADR Template

When adding a new ADR, use this structure:

```markdown
# ADR-NNN: Title

**Status**: Proposed | Accepted | Deprecated | Superseded
**Date**: YYYY-MM-DD
**Context**: Brief context

## Context

What is the issue that we're seeing that is motivating this decision?

## Decision

What is the change that we're proposing?

## Consequences

### Positive
- Benefit 1
- Benefit 2

### Negative
- Drawback 1
- Drawback 2

### Mitigations
- How we address the drawbacks

## Related

- Links to related ADRs or documentation
```

## Related Documentation

- [Repository Architecture](../repository-architecture.md) - High-level architecture overview
- [Modular Design Patterns](../modular-design-patterns.md) - Implementation patterns
