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
- [Repository Structure Refactor Plan](../repository-structure-refactor-plan.md) - Refactoring history
