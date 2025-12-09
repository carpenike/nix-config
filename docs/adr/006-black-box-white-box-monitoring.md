# ADR-006: Black-Box vs White-Box Monitoring Strategy

**Status**: Accepted
**Date**: 2025-12-09
**Context**: Monitoring architecture for homelab services

## Context

Homelab monitoring needs to answer two distinct questions:

1. **"Is this service available?"** - User perspective
2. **"How healthy is this service internally?"** - Operator perspective

Early implementations used a single monitoring tool for both purposes, leading to either alert fatigue (too many internal alerts) or blind spots (missing user-facing issues).

## Decision

**Maintain two complementary monitoring systems with clear separation of concerns:**

| System | Type | Purpose | Alerts On |
|--------|------|---------|-----------|
| **Gatus** | Black-box | User-facing availability | Service up/down, HTTP status, port reachability |
| **Prometheus** | White-box | Internal health & performance | Resource usage, query latency, backup failures |

### Gatus (Black-Box)

- Monitors services **as a user would see them**
- Binary checks: UP ✅ or DOWN ❌
- Immediate phone notifications for user-visible failures
- Public status page for family/users
- Services contribute their own endpoints via contributory pattern

### Prometheus (White-Box)

- Monitors **internal service state**
- Quantitative metrics: gauges, counters, histograms
- Predictive alerts (disk filling, memory leak)
- Historical analysis via Grafana
- Alert routing through Alertmanager

## Consequences

### Positive

- **Clear responsibility**: Each system has one job
- **Complementary alerts**: Gatus says *what* is broken, Prometheus says *why*
- **Reduced alert fatigue**: Internal issues don't page unless they affect users
- **Public status page**: Users can self-serve availability checks
- **Predictive capability**: Prometheus catches issues before they cause outages

### Negative

- **Two systems to maintain**: More infrastructure complexity
- **Alert coordination**: Must avoid duplicate alerts for same issue
- **Learning curve**: Need to understand when to use which system

### Mitigations

- Use Gatus's native `/metrics` endpoint (no separate exporter)
- Document clear decision framework for each service
- Avoid monitoring Gatus inside Gatus (use Prometheus health check)

## Decision Framework

```text
┌─────────────────────────────────────────┐
│ New Service: Do users interact with it? │
└───────────┬─────────────────────────────┘
            │
       Yes  │  No
            ↓   ↓
    ┌───────┐  └──────────────┐
    │ Add   │                 │
    │ Gatus │                 │
    │ check │                 │
    └───┬───┘                 │
        │                     │
        ↓                     ↓
┌───────────────────────────────────────────┐
│ Does it expose metrics or use significant │
│ resources?                                │
└───────┬───────────────────────────────────┘
        │
   Yes  │  No
        ↓   ↓
┌───────┐  └─────────────────┐
│Enable │   │ Only systemd    │
│Prom   │   │ unit monitoring │
│scrape │   └─────────────────┘
└───────┘
```text

## Examples

### PostgreSQL (Both Systems)

**Gatus**: TCP check on port 5432 - "Can clients connect?"

**Prometheus**: Connection pool usage, query latency, backup status - "Why is it slow?"

### Plex (Gatus Primary)

**Gatus**: HTTPS check on web UI - Status page for family

**Prometheus**: Memory usage (transcoding leaks) - Prevent OOM

### Caddy (Prometheus Only)

**Don't** monitor Caddy in Gatus - monitor services *behind* Caddy.
If Caddy is down, all HTTP checks fail - that's the signal.

## Anti-Patterns

❌ **Don't monitor Gatus inside Gatus** (circular dependency)
✅ Use Prometheus + systemd health check timer to monitor Gatus

❌ **Don't add both checks for the same thing**
✅ Use Gatus for availability, Prometheus for internals (different perspectives)

❌ **Don't alert on resource usage without validation**
✅ Alert on symptoms (service down) and validated thresholds (disk <10%)

## Related

- [Monitoring Strategy](../monitoring-strategy.md) - Full documentation
- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md) - Gatus endpoint contributions
