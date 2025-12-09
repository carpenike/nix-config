# NixOS Configuration Documentation

This directory contains comprehensive documentation for the NixOS configuration system.

## Quick Start

| Goal | Document |
|------|----------|
| **Understand the repo** | [Repository Architecture](./repository-architecture.md) |
| **Create a new service** | [Modular Design Patterns](./modular-design-patterns.md#creating-new-service-modules) |
| **Set up backups** | [Backup System Onboarding](./backup-system-onboarding.md#quick-start) |
| **Bootstrap a new host** | [Bootstrap Quickstart](./bootstrap-quickstart.md) |
| **Configure monitoring** | [Monitoring Strategy](./monitoring-strategy.md) |

---

## Architecture

- **[Repository Architecture](./repository-architecture.md)** - ⚡ **Start here**
  - Directory layout and module organization
  - `mylib` components and injection pattern
  - Host architecture patterns (single-disk vs two-disk)
  - Key patterns and conventions

- **[Architectural Decision Records (ADRs)](./adr/README.md)** - Design decisions with context
  - [ADR-001: Contributory Infrastructure Pattern](./adr/001-contributory-infrastructure-pattern.md)
  - [ADR-002: Host-Level Defaults Library](./adr/002-host-level-defaults-library.md)
  - [ADR-003: Shared Types for Service Modules](./adr/003-shared-types-for-service-modules.md)
  - [ADR-004: Impermanence Host-Level Control](./adr/004-impermanence-host-level-control.md)
  - [ADR-005: Native Services Over Containers](./adr/005-native-services-over-containers.md)
  - [ADR-006: Black-Box vs White-Box Monitoring](./adr/006-black-box-white-box-monitoring.md)
  - [ADR-007: Multi-Tier Disaster Recovery](./adr/007-multi-tier-disaster-recovery.md)
  - [ADR-008: Authentication Priority Framework](./adr/008-authentication-priority-framework.md)
  - [ADR-009: Thin Orchestrator Pattern](./adr/009-thin-orchestrator-pattern.md)

---

## Module Development

- **[Modular Design Patterns](./modular-design-patterns.md)** - ⚡ **Required reading for new services**
  - Creating new service modules (native vs container decision)
  - Standardized submodule patterns (reverseProxy, metrics, logging, backup)
  - `mylib.types` shared type definitions
  - Host-level defaults library patterns
  - Anti-patterns to avoid

- **[Reverse Proxy Pattern](./reverse-proxy-pattern.md)** - Caddy integration patterns

- **[Modular Caddy Config](./modular-caddy-config.md)** - Caddy module architecture

---

## Authentication & Security

- **[Authentication SSO Pattern](./authentication-sso-pattern.md)** - ⚡ **Pocket ID + Caddy Security**
  - Native OIDC integration
  - Trusted header auth (auth proxy)
  - caddySecurity for single-user apps
  - Hybrid auth patterns

- **[API Key Authentication](./api-key-authentication.md)** - S2S and user API key patterns

- **[Pocket ID Integration](./pocketid-integration-pattern.md)** - Passwordless SSO setup

---

## Backup & Disaster Recovery

- **[Backup System Onboarding](./backup-system-onboarding.md)** - Complete Restic + ZFS guide
  - Host onboarding procedures
  - Service backup configurations
  - ZFS replication (Sanoid/Syncoid)
  - Monitoring and troubleshooting

- **[Disaster Recovery Preseed Pattern](./disaster-recovery-preseed-pattern.md)** - ⚡ **Automated restoration**
  - Multi-tier restore strategy (Syncoid → Local → Restic)
  - Implementation for native and containerized services
  - Testing procedures

- **[Unified Backup Design Patterns](./unified-backup-design-patterns.md)** - Backup architecture

- **[Preseed Restore Methods Guide](./preseed-restore-methods-guide.md)** - Which restore methods to use

- **[Backup Forge Setup](./backup-forge-setup.md)** - Forge-specific backup configuration

- **[Backup Metrics Reference](./backup-metrics-reference.md)** - Prometheus metrics for backups

---

## Storage & Persistence

- **[Persistence Quick Reference](./persistence-quick-reference.md)** - ZFS dataset patterns

- **[Storage Module Guide](./storage-module-guide.md)** - Declarative ZFS dataset management

- **[ZFS Replication Setup](./zfs-replication-setup.md)** - Forge → NAS replication

- **[NFS Mount Management](./nfs-mount-management.md)** - Centralized NFS configuration
  - Server and share definitions
  - Profile-based configuration
  - Integration with backup system

---

## Monitoring & Observability

- **[Monitoring Strategy](./monitoring-strategy.md)** - ⚡ **Black-box vs white-box**
  - Gatus (black-box) vs Prometheus (white-box) decisions
  - Service-specific monitoring guidance
  - Alert routing strategies
  - Anti-patterns to avoid

- **[Metrics Pattern Usage](./metrics-pattern-usage.md)** - Prometheus metrics patterns

- **[Structured Logging Framework](./structured-logging-framework.md)** - JSON logging patterns

- **[Notifications](./notifications.md)** - Pushover, ntfy, Healthchecks.io

---

## PostgreSQL

- **[PostgreSQL Auto-Restore](./postgresql-auto-restore-homelab.md)** - Automatic DR for homelab
- **[PostgreSQL PITR Guide](./postgresql-pitr-guide.md)** - Point-in-time recovery procedures
- **[PostgreSQL pgBackRest Migration](./postgresql-pgbackrest-migration.md)** - Migration guide
- **[PostgreSQL Offsite Backup](./postgresql-offsite-backup-setup.md)** - Cloudflare R2 backups
- **[PostgreSQL Preseed Marker Fix](./postgresql-preseed-marker-fix.md)** - DR troubleshooting
- **[pgBackRest Multi-Repo Workaround](./pgbackrest-multi-repo-workaround.md)** - Multi-repo config
- **[pgBackRest Unified Config](./pgbackrest-unified-config.md)** - Configuration patterns

---

## Network Services

- **[AdGuard Modular Config](./adguard-modular-config.md)** - AdGuard Home patterns
- **[DNSdist Shared Config](./dnsdist-shared-config.md)** - DNS infrastructure
- **[Cloudflare Tunnel Implementation](./cloudflare-tunnel-implementation.md)** - External access

---

## System Management

- **[Bootstrap Quickstart](./bootstrap-quickstart.md)** - ⚡ New host deployment
- **[Container Image Management](./container-image-management.md)** - Image pinning and updates
- **[Custom Package Patterns](./custom-package-patterns.md)** - Creating custom packages
- **[Package Management Strategy](./package-management-strategy.md)** - Nix package patterns

---

## Service Operations

- **[TeslaMate Operations](./teslamate-operations.md)** - TeslaMate stack management
- **[UPS Monitoring](./ups-monitoring.md)** - Network UPS Tools configuration
- **[Resilio Sync](./resilio-sync.md)** - Folder synchronization

---

## Reference

- **[AI Orchestration](./ai_orchestration.md)** - How Copilot, Zen MCP, and Perplexity work together
- **[Shared Config Example](./shared-config-example.md)** - Configuration patterns
- **[*arr Services API Key Config](./arr-services-api-key-configuration.md)** - Sonarr/Radarr API keys

### Subdirectories

- **[services/](./services/)** - Service-specific implementation docs
- **[analysis/](./analysis/)** - Design pattern analysis

---

## Contributing

When adding new documentation:

1. Follow the existing structure and formatting
2. Include practical examples and troubleshooting sections
3. Add "Last Updated" date in the header
4. Update this README with links to new docs
5. For design decisions, consider creating an ADR

### Documentation Standards

All documentation should include:

- **Quick Start** - Minimal working example
- **Configuration Reference** - Complete options
- **Examples** - Real-world usage patterns
- **Troubleshooting** - Common issues and solutions

---

**Last Updated**: December 9, 2025
