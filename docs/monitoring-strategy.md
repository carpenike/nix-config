# Monitoring Strategy: Black-Box vs White-Box

This document establishes the strategic division of monitoring responsibilities between Gatus (black-box) and Prometheus/Alertmanager (white-box) for homelab services.

**Last Updated**: December 4, 2025
**Architecture**: Gatus replaces Uptime Kuma as the black-box monitoring solution

---

## Core Principle

**"Use Gatus for user-facing availability (is it up?) and Prometheus for system internals (how well is it running?)."**

These two monitoring perspectives are **complementary, not redundant**:
- **Gatus alert** tells you *what* is broken (user impact)
- **Prometheus alert** tells you *why* it's breaking (system health)

---

## Black-Box Monitoring (Gatus)

### Purpose
External validation from the user's perspective. Answers: **"Is this service available and behaving as a user would expect from the outside?"**

### Characteristics
- **Knows nothing about internal state** - interacts as a client would
- **Binary checks**: Service is UP ✅ or DOWN ❌
- **Immediate alerts**: User-facing failures require immediate action
- **Public status page**: Family/users can see service availability
- **Declarative configuration**: Services contribute their own endpoints

### What to Monitor in Gatus

Add to Gatus if the service meets ANY of these criteria:
- ✅ Users directly interact with it (web UI, API, network service)
- ✅ You want it displayed on a public status page
- ✅ The check is simple and external (HTTP 200, port open, ping)
- ✅ Failure immediately impacts user experience

### Check Types

| Check Type | Use Case | Example |
|------------|----------|---------|
| **HTTP(S)** | Web services, APIs | Status 200 + keyword "Login" |
| **TCP Port** | Database connections | Port 5432 accepting connections |
| **DNS** | DNS resolution | Query google.com through AdGuard |
| **Ping** | Host reachability | NAS, other homelab nodes |
| **TLS Certificate** | Certificate expiry | Certificate valid, >30 days remaining |

### Alert Routing
- **Target**: Phone notifications (critical/immediate)
- **When**: User-visible service failures
- **Configure in**: NixOS configuration via `modules.services.gatus.contributions`

---

## White-Box Monitoring (Prometheus)

### Purpose
Internal health and performance measurement. Answers: **"What is the internal state, load, and performance of this service and its components?"**

### Characteristics
- **Requires metrics exposure** - service must instrument itself
- **Quantitative measurements**: Gauges, counters, histograms, trends
- **Predictive alerts**: Warn before failures occur (disk filling, memory leak)
- **Historical analysis**: Grafana dashboards, capacity planning

### What to Monitor in Prometheus

Add to Prometheus if the service meets ANY of these criteria:
- ✅ Exposes metrics (native exporter or instrumented)
- ✅ Resource usage matters (CPU, memory, disk, network)
- ✅ Needs predictive alerting (trending toward failure)
- ✅ Requires historical trending and dashboards

### Metric Sources

| Source | Purpose | Examples |
|--------|---------|----------|
| **node_exporter** | System-level metrics | CPU, memory, disk, network, systemd units |
| **postgres_exporter** | Database internals | Connection pools, query latency, replication lag |
| **Application exporters** | App-specific metrics | Auth failures, request rates, queue depths |
| **Textfile collectors** | Custom metrics | ZFS health, GPU usage, container stats |

### Alert Types

| Alert Category | Severity | Example |
|----------------|----------|---------|
| **Resource Critical** | Critical | Disk <10%, Memory >90% sustained |
| **Degradation** | High | Query latency >500ms p95 |
| **Predictive** | Warning | Disk will fill in 4 hours (trend) |
| **Internal Failure** | High | Backup job failed, systemd restart loop |

### Alert Routing
- **Target**: Alertmanager → Slack/Email/Phone (severity-based)
- **When**: System trending toward failure or internal problems
- **Configure in**: NixOS configuration (`modules.alerting.rules`)

---

## When to Use BOTH

Use both monitoring systems when:
1. **Service is critical AND complex** - PostgreSQL, authentication services
2. **Different perspectives provide different value** - External availability ≠ internal health
3. **Alerts serve different purposes** - User impact vs operational health

### Example: PostgreSQL

**Gatus Check:**
- Type: TCP Port
- Target: `localhost:5432`
- Alert: "Database is completely unreachable"
- Purpose: Fast validation that users/apps can connect

**Prometheus Monitoring:**
- Exporter: postgres_exporter
- Metrics: Connection pool usage, query latency, replication lag, backup status
- Alerts: High connection count, slow queries, backup failures
- Purpose: Catch slow degradation before total failure

**Why both?** TCP check is immediate user-perspective validation. Prometheus catches internal problems (slow queries, connection exhaustion) before they cause complete outages.

---

## Service-Specific Guidance

### Authentication (PocketID, Keycloak)
| System | Check | Purpose |
|--------|-------|---------|
| **Gatus** | HTTPS → login page returns 200 + "Login" keyword | Users can access login |
| **Prometheus** | Auth success/failure rate, request latency | Detect attacks or misconfig |

### DNS (AdGuard Home, Pihole)
| System | Check | Purpose |
|--------|-------|---------|
| **Gatus** | DNS query for google.com succeeds | DNS resolution working |
| **Prometheus** | systemd unit state, query rate, block rate | Service health, performance |

### Reverse Proxy (Caddy, Traefik)
| System | Check | Purpose |
|--------|-------|---------|
| **Gatus** | HTTP(S) checks on **proxied services** (not Caddy itself) | Detect broken routes |
| **Prometheus** | systemd unit state, restart count | Caddy service health |

**Note**: Don't monitor "Caddy itself" in Gatus. Monitor the services **behind** Caddy. If Caddy is down, all HTTP checks fail - that's your signal.

### Media (Plex, Jellyfin)
| System | Check | Purpose |
|--------|-------|---------|
| **Gatus** | HTTPS → web UI returns 200 | Status page for family 📊 |
| **Prometheus** | Memory usage (transcode leaks), CPU (encoding) | Prevent OOM, resource exhaustion |

### Databases (PostgreSQL, MySQL)
| System | Check | Purpose |
|--------|-------|---------|
| **Gatus** | TCP port check (optional - systemd check may suffice) | Basic reachability |
| **Prometheus** | Connection pools, query performance, backup status | Internal health, capacity |

### Monitoring Itself (Gatus, Prometheus)
| System | Check | Purpose |
|--------|-------|---------|
| **Gatus** | ❌ Don't monitor itself (circular dependency) | N/A |
| **Prometheus** | systemd health check service state | Meta-monitoring |

**Critical Pattern**: Use systemd health check timers to probe Gatus, then monitor the timer state in Prometheus. This avoids the "monitoring the monitor" complexity trap.

---

## Implementation Checklist

### For New Services

When adding a service to your homelab, follow this decision tree:

```
┌─────────────────────────────────────────┐
│ New Service: "example-service"          │
└─────────────────┬───────────────────────┘
                  │
                  ↓
      ┌───────────────────────────┐
      │ Do users interact with    │
      │ this service?             │
      └───────┬───────────────────┘
              │
         Yes  │  No
              ↓   ↓
    ┌─────────┐  └──────────────┐
    │ Add to  │                 │
    │ Gatus   │                 │
    │         │                 │
    └─────┬───┘                 │
          │                     │
          ↓                     ↓
    ┌─────────────────────────────────────┐
    │ Does it expose metrics or use       │
    │ significant resources?              │
    └───────┬─────────────────────────────┘
            │
       Yes  │  No
            ↓   ↓
    ┌───────┐  └─────────────────┐
    │ Enable│   │ Only systemd    │
    │ Prom  │   │ unit monitoring │
    │ scrape│   │ is sufficient   │
    └───────┘   └─────────────────┘
```

### Prometheus Configuration (Keep Simple)

**Current exporters to maintain:**
- ✅ `node_exporter` - System metrics (already configured)
- ✅ `postgres_exporter` - Database metrics (already configured)
- ✅ Systemd unit state monitoring (already configured)
- ✅ Textfile collectors: ZFS, GPU, containers (already configured)

**When to add application exporters:**
- Only for **critical services** where internal metrics provide significant value
- Examples: caddy-security (auth failures), Caddy (request latency), critical APIs
- **Default to NO** - infrastructure monitoring is usually sufficient

### Gatus Configuration (Declarative)

For each **user-facing** service, add a Gatus contribution in the service's NixOS configuration:

```nix
# In service module or host service file
modules.services.gatus.contributions.myservice = {
  name = "My Service";
  group = "Applications";
  url = "https://myservice.holthome.net/health";
  interval = "60s";
  conditions = [
    "[STATUS] == 200"
    "[RESPONSE_TIME] < 1000"
  ];
};
```

**Check types**:
1. **Web services**: HTTP(S) check with keyword/status validation
2. **DNS services**: DNS query check
3. **Databases**: TCP port check (if not sufficiently covered by Prometheus)
4. **Infrastructure hosts**: Ping/ICMP check for critical nodes (NAS, etc.)

---

## Alert Philosophy

### Prometheus Alerts
**Goal**: Predict and prevent failures before user impact

**Characteristics**:
- Threshold-based (CPU >90% for 5m)
- Trend-based (disk will fill in 4h)
- Internal failures (backup failed, restart loop)
- **Route through Alertmanager** with severity-based routing

### Gatus Alerts
**Goal**: Immediate notification of user-visible failures

**Characteristics**:
- Binary (service up or down)
- External perspective (as users see it)
- **Configure in NixOS** via contribution pattern
- Direct notifications (phone, critical channels)

### Alert Fatigue Prevention

**Anti-Pattern**: Don't alert on "guesses" (CPU high, memory high) unless you've validated they predict failures.

**Best Practice**: Alert on **symptoms** (service down, backup failed) and **validated thresholds** (disk <10%).

**Homelab Optimization**:
- Keep alert count low (high signal-to-noise)
- Validate every alert adds value
- Remove alerts that trigger without actionable issues

---

## Visualization Strategy

### Gatus
- **Purpose**: Public status page for users/family
- **Audience**: Non-technical users
- **Content**: Service availability (green/red), uptime percentages

### Grafana Dashboards
- **Purpose**: Operational visibility and analysis
- **Audience**: Homelab operator (you)
- **Content**: Resource trends, performance metrics, capacity planning

**Separation of Concerns**: Users see "Is Plex up?", operators see "Why is Plex using 8GB RAM?"

---

## Migration Path

### Current State
- ✅ Prometheus + node_exporter deployed
- ✅ postgres_exporter deployed
- ✅ Custom textfile collectors (ZFS, GPU, containers)
- ✅ Alertmanager integrated
- ✅ Gatus deployed with contributory endpoint pattern

### To Implement
1. **Add Gatus contributions** for user-facing services (in NixOS config)
2. **Review Prometheus alert rules** - ensure they follow "alert on symptoms" philosophy
3. **Document runbooks** for each alert type (what to do when it fires)
4. **Test alert delivery** - verify both Gatus and Prometheus alerts reach you

### Future Enhancements (Optional)
- Add application exporters for critical services (if justified by value)
- Implement predictive alerting for capacity planning
- Create Grafana dashboards for specific service deep-dives

---

## Anti-Patterns to Avoid

❌ **Don't monitor Gatus inside Gatus** (circular dependency)
✅ **Do** use Prometheus + systemd health check timer to monitor Gatus

❌ **Don't add both Gatus and Prometheus checks for the same thing**
✅ **Do** use Gatus for availability, Prometheus for internals (different perspectives)

❌ **Don't add gatus-exporter** to expose Gatus metrics to Prometheus
✅ **Do** use Gatus's native `/metrics` endpoint (already built-in)

❌ **Don't monitor Caddy directly in Gatus**
✅ **Do** monitor the services **behind** Caddy (if Caddy is down, all checks fail)

❌ **Don't alert on resource usage without validation**
✅ **Do** alert on symptoms (service down) and validated thresholds (disk <10%)

---

## Decision Framework Summary

### Quick Reference Table

| Question | Gatus | Prometheus | Both |
|----------|-------|------------|------|
| User-facing web service? | ✅ HTTP(S) check | Optional: app metrics | If critical |
| Database service? | Optional: TCP check | ✅ Internal metrics | Usually |
| Infrastructure host? | ✅ Ping check | ✅ node_exporter | Yes |
| Monitoring service itself? | ❌ No | ✅ Health check state | No |
| Reverse proxy? | ❌ Monitor services behind it | ✅ Systemd state | Yes |
| Internal-only service? | ❌ No | ✅ If exposes metrics | No |

### The Mental Model

```
┌─────────────────────────────────────────────────────────────┐
│                    User Perspective                          │
│                     (Gatus Checks)                            │
│                                                              │
│  "Can users access the service right now?"                  │
│   → HTTP 200? DNS resolving? Port open?                     │
│   → Binary: UP ✅ or DOWN ❌                                 │
│   → Alert immediately on failure                            │
└──────────────────────────┬──────────────────────────────────┘
                           │
                Service is running
                           │
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                   System Perspective                         │
│              (Prometheus/Grafana Metrics)                    │
│                                                              │
│  "How healthy is the service internally?"                   │
│   → CPU/Memory usage? Disk space? Query latency?            │
│   → Quantitative: Trends, thresholds, predictions           │
│   → Alert on degradation before failure                     │
└─────────────────────────────────────────────────────────────┘
```

---

## References

- **Gatus Module**: `hosts/_modules/nixos/services/gatus/default.nix`
- **Prometheus Configuration**: `hosts/forge/monitoring.nix`
- **Alerting Module**: `hosts/_modules/nixos/alerting.nix`
- **Alert Definitions**: Co-located with services (e.g., `hosts/forge/services/*.nix`)

---

## Revision History

- **Dec 4, 2025**: Updated to use Gatus as black-box monitoring solution
  - Replaced Uptime Kuma references with Gatus
  - Added declarative configuration patterns via NixOS contributions
  - Updated decision framework and examples
- **Nov 5, 2025**: Initial document created based on Gemini Pro strategic analysis
  - Established black-box vs white-box monitoring principles
  - Defined clear decision framework for service monitoring
  - Documented anti-patterns and best practices for homelab context
