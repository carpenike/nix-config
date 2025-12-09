# NixOS Configuration Documentation

This directory contains comprehensive documentation for the NixOS configuration system.

## Available Documentation

### System Management

- **[Bootstrap Quickstart](./bootstrap-quickstart.md)** - ⚡ **Quick reference** for manually bootstrapping new NixOS hosts
  - Step-by-step deployment workflow
  - SOPS secrets integration
  - Taskfile helper commands
  - Common issues and solutions

- **[Backup System Onboarding](./backup-system-onboarding.md)** - Complete guide for configuring Restic-based backups with ZFS integration, monitoring, automated testing, and service-specific profiles
  - Host onboarding procedures
  - Service backup configurations (UniFi, Omada, 1Password, Attic, System)
  - Monitoring and alerting setup
  - Troubleshooting guides

- **[NFS Mount Management](./nfs-mount-management.md)** - DRY-based centralized NFS mount configuration across multiple hosts
  - Server and share definitions
  - Profile-based configuration (homelab, performance, reliability, readonly)
  - Host-specific mount customization
  - Integration with backup system
  - Troubleshooting and best practices

### Disaster Recovery & Persistence

- **[Disaster Recovery Preseed Pattern](./disaster-recovery-preseed-pattern.md)** - ⚡ **Automated service restoration** using ZFS Syncoid replication
  - Multi-tier restore strategy (Syncoid → Local → Restic)
  - Implementation guide for native and containerized services
  - Validated for Plex, Loki, Grafana, Sonarr, Radarr, Dispatcharr
  - Testing procedures and troubleshooting

- **[Persistence Quick Reference](./persistence-quick-reference.md)** - ZFS dataset management and service persistence patterns

- **[Storage Module Guide](./storage-module-guide.md)** - Comprehensive guide for storage configuration

### PostgreSQL & Database

- **[PostgreSQL Auto-Restore (Quick Start)](./postgresql-auto-restore-quickstart.md)** - ⚡ **Automatic disaster recovery** for homelab servers - PostgreSQL restores from backup automatically when you rebuild
- **[PostgreSQL Auto-Restore (Full Guide)](./postgresql-auto-restore-homelab.md)** - Complete documentation for automatic PostgreSQL restore on server rebuild
- **[PostgreSQL Preseed Marker Fix](./postgresql-preseed-marker-fix.md)** - Root cause analysis and fix for PostgreSQL preseed marker persistence
- **[PostgreSQL Repository Selection](./postgresql-preseed-repository-selection.md)** - repo1 (NFS) vs repo2 (R2) comparison and decision guide
- **[PostgreSQL PITR Guide](./postgresql-pitr-guide.md)** - Manual point-in-time recovery procedures
- **[PostgreSQL pgBackRest Migration](./postgresql-pgbackrest-migration.md)** - Migration from custom backup scripts to pgBackRest
- **[PostgreSQL pgBackRest Offsite Backup Setup](./postgresql-offsite-backup-setup.md)** - Setting up Cloudflare R2 offsite backups

### Network Services

- **[AdGuard Modular Config](./adguard-modular-config.md)** - Modular AdGuard Home configuration patterns

- **[DNSdist Shared Config](./dnsdist-shared-config.md)** - DNSdist configuration for shared DNS infrastructure

### Monitoring & Observability

- **[Monitoring Strategy](./monitoring-strategy.md)** - ⚡ **Black-box vs white-box monitoring** principles for homelab services
  - Decision framework for Gatus vs Prometheus
  - Service-specific monitoring guidance
  - Alert routing and configuration strategies
  - Anti-patterns to avoid

### Module Development

- **[Modular Design Patterns](./modular-design-patterns.md)** - ⚡ **Required reading for new services**
  - Creating new service modules (native vs container decision)
  - Standardized submodule patterns (reverseProxy, metrics, logging, backup)
  - Service module architecture and best practices
  - Anti-patterns to avoid

### Package Management

- **[Package Management Strategy](./package-management-strategy.md)** - Nix package management patterns and strategies

- **[Nix Flake Improvement Plan](./nix-flake-improvement-plan.md)** - Roadmap for flake architecture improvements

### Reference

- **[Shared Config Example](./shared-config-example.md)** - Examples of shared configuration patterns

- **[Analysis Directory](./analysis/)** - Design pattern analysis and architectural decisions

## Quick Links

### Getting Started

1. **Creating a new service**: Read [Modular Design Patterns - Creating New Service Modules](./modular-design-patterns.md#creating-new-service-modules)
2. **Setting up backups**: Start with [Backup System Onboarding](./backup-system-onboarding.md#quick-start)
3. **Configuring NFS mounts**: See [NFS Mount Management Quick Start](./nfs-mount-management.md#quick-start)
4. **Understanding the flake structure**: Review [Nix Flake Improvement Plan](./nix-flake-improvement-plan.md)

### Common Tasks

- **Create a new service module**: [Creating New Service Modules](./modular-design-patterns.md#creating-new-service-modules)
- **Add monitoring to a service**: [Monitoring Strategy](./monitoring-strategy.md)
- **Add a new host to backups**: [Host Onboarding](./backup-system-onboarding.md#host-onboarding)
- **Enable service backups**: [Service Onboarding](./backup-system-onboarding.md#service-onboarding)
- **Configure NAS mounts**: [NFS Configuration Reference](./nfs-mount-management.md#configuration-reference)

### Troubleshooting

- **Backup issues**: [Backup Troubleshooting](./backup-system-onboarding.md#troubleshooting)
- **NFS mount problems**: [NFS Troubleshooting](./nfs-mount-management.md#troubleshooting)

## Module Locations

### Host Modules

Located in `/modules/nixos/`:

- **backup.nix** - Comprehensive backup system with Restic and ZFS integration
- **services/backup-services.nix** - Pre-configured backup profiles for common services
- **filesystems/nfs/** - Centralized NFS mount management
- **filesystems/zfs/** - ZFS configuration modules

### Home Modules

Located in `/home/_modules/`:

- Development tools
- Shell configurations
- Editor settings
- Deployment utilities

## Contributing

When adding new features or modules:

1. Update or create relevant documentation in this directory
2. Follow the existing documentation structure
3. Include practical examples and troubleshooting sections
4. Add references to the module source files
5. Update this README with links to new documentation

## Documentation Standards

All documentation should include:

- **Table of Contents** - For documents longer than 3 sections
- **Quick Start** - Minimal working example
- **Configuration Reference** - Complete option documentation
- **Examples** - Real-world usage patterns
- **Troubleshooting** - Common issues and solutions
- **Best Practices** - Recommended patterns

## Related Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Nix Pills](https://nixos.org/guides/nix-pills/)
- [NixOS Wiki](https://nixos.wiki/)
- [NixOS Discourse](https://discourse.nixos.org/)

---

**Last Updated**: 2025-10-08
