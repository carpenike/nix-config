# Unified Backup Design Patterns

**Last Updated**: 2025-10-29
**Status**: Active - Replaces previous backup patterns
**Architecture**: Unified control plane with opt-in snapshots

## Overview

This document establishes the standardized design patterns for the unified backup management system implemented in late 2025. The unified approach consolidates backup operations under a single control plane while maintaining service autonomy and eliminating tight coupling between backup components.

## Architecture Principles

### 1. Unified Control Plane
- **Single Module**: All backup operations managed by `modules.services.backup`
- **Service Discovery**: Automatic detection of services with backup submodules
- **Repository Management**: Centralized configuration of backup repositories
- **Enterprise Monitoring**: Unified metrics collection via textfile collector

### 2. Opt-in Snapshot Coordination
- **Explicit Declaration**: Services declare `useSnapshots = true` when needed
- **Temporary Snapshots**: Created before backup, cleaned up after
- **No Coupling**: Services don't depend on centralized Sanoid configuration
- **ZFS Integration**: Leverages existing ZFS infrastructure without modification

### 3. Hybrid Database Strategy
- **PostgreSQL**: pgBackRest for PITR + Restic for offsite archives
- **Application DBs**: Direct Restic backup with optional snapshot coordination
- **Unified Monitoring**: Same metrics framework for all backup types

## Implementation Architecture

```
Unified Backup System
├── modules.services.backup/
│   ├── default.nix        # Main module, repositories, global settings
│   ├── restic.nix         # Service discovery, backup orchestration
│   ├── snapshots.nix      # Opt-in ZFS snapshot coordination
│   ├── postgres.nix       # PostgreSQL hybrid backup integration
│   ├── monitoring.nix     # Enterprise monitoring via textfile collector
│   └── verification.nix   # Automated verification & restore testing
│
├── Service Integration (automatic via discovery)
│   ├── Service declares backup submodule
│   ├── System discovers and configures backup job
│   └── Monitoring automatically enabled
│
└── Infrastructure Integration
    ├── Existing Sanoid (for ongoing snapshots)
    ├── Node Exporter textfile collector
    ├── Prometheus alerting rules
    └── Grafana dashboard generation
```

## Service Integration Patterns

### Standard Service Backup Configuration

Services should declare backup requirements using the standardized backup submodule:

```nix
# In service module options
backup = lib.mkOption {
  type = lib.types.nullOr sharedTypes.backupSubmodule;
  default = {
    enable = true;
    repository = "nas-primary";
    frequency = "daily";
    tags = [ "service-type" "service-name" "data-category" ];
    useSnapshots = false;  # Opt-in for ZFS snapshot coordination
  };
  description = "Backup configuration for this service";
};
```

### ZFS Snapshot Integration (Opt-in)

For services requiring snapshot consistency:

```nix
backup = {
  enable = true;
  repository = "nas-primary";
  useSnapshots = true;        # Enable snapshot coordination
  zfsDataset = "tank/services/myservice";  # Required when useSnapshots=true
  frequency = "daily";
  tags = [ "database" "myservice" "critical" ];
};
```

### PostgreSQL Hybrid Pattern

Database services using PostgreSQL should leverage the hybrid approach:

```nix
# PostgreSQL handled automatically by postgres.nix submodule
# - pgBackRest manages PITR locally and to NFS
# - Restic handles offsite backup of pgBackRest archives
# - Unified monitoring covers both systems
```

## Repository Configuration

### Multi-Repository Pattern

Configure repositories for different backup tiers:

```nix
modules.services.backup = {
  enable = true;

  repositories = {
    # Primary repository (fast local/NFS storage)
    nas-primary = {
      url = "/mnt/nas-backup";
      passwordFile = config.sops.secrets."restic/password".path;
      primary = true;
      type = "local";
    };

    # Offsite repository (cloud storage for DR)
    r2-offsite = {
      url = "s3:https://account.r2.cloudflarestorage.com/bucket/host";
      passwordFile = config.sops.secrets."restic/password".path;
      environmentFile = config.sops.secrets."restic/r2-env".path;
      primary = false;
      type = "s3";
    };
  };
};
```

### Repository Selection Strategy

- **nas-primary**: Fast recovery, frequent backups, service data
- **r2-offsite**: Geographic redundancy, system state, long-term retention
- **Hybrid**: Database PITR local, archives offsite

## Monitoring Integration

### Textfile Collector Metrics

All backup metrics flow through the existing node-exporter textfile collector:

```prometheus
# Backup job metrics
restic_backup_status{backup_job="service-grafana",repository="nas-primary",hostname="forge"} 1
restic_backup_duration_seconds{backup_job="service-grafana",repository="nas-primary",hostname="forge"} 145
restic_backup_last_success_timestamp{backup_job="service-grafana",repository="nas-primary",hostname="forge"} 1698765432

# PostgreSQL backup metrics
postgres_backup_verification_status{hostname="forge"} 1
postgres_pgbackrest_offsite_backup_status{hostname="forge"} 1

# Verification metrics
restic_verification_status{repository="nas-primary",hostname="forge"} 1
restic_restore_test_status{repository="nas-primary",hostname="forge"} 1
```

### Alerting Rules

Comprehensive alerting covers all backup scenarios:

- **UnifiedBackupFailed**: Backup job failure (critical)
- **UnifiedBackupStale**: Backup older than threshold (high)
- **UnifiedBackupSlow**: Performance degradation (medium)
- **PostgresBackupVerificationFailed**: Database verification failure (high)
- **BackupMonitoringUnhealthy**: Monitoring system issues (high)

## Migration Patterns

### From Legacy System

Gradual migration from existing backup-integration:

```nix
# Phase 1: Run both systems in parallel
modules.services.backup-integration.enable = true;  # Existing system
modules.services.backup.enable = false;             # New system (staged)

# Phase 2: Enable new system alongside old
modules.services.backup-integration.enable = true;  # Keep running
modules.services.backup.enable = true;              # Start testing

# Phase 3: Migrate to unified system
modules.services.backup-integration.enable = false; # Disable old
modules.services.backup.enable = true;              # Use new system
```

### Service Migration

Update service configurations to use unified patterns:

```nix
# OLD: Manual backup-integration configuration
modules.services.backup-integration = {
  enable = true;
  defaultRepository = "nas-primary";
};

# NEW: Service declares backup needs, system handles automatically
modules.services.myservice = {
  backup = {
    enable = true;
    repository = "nas-primary";
    useSnapshots = true;  # If needed
  };
};
```

## Verification Framework

### Automated Testing

The verification framework provides enterprise-grade backup validation:

- **Repository Integrity**: Automated `restic check` operations
- **Restore Testing**: Monthly sample file restoration
- **Performance Monitoring**: Duration and throughput tracking
- **Compliance Reporting**: Automated verification reports

### Configuration

```nix
verification = {
  enable = true;
  schedule = "weekly";
  checkData = false;          # Set true for thorough verification
  checkDataSubset = "10%";    # Subset for data verification

  restoreTesting = {
    enable = true;
    schedule = "monthly";
    sampleFiles = 5;
  };
};
```

## Best Practices

### 1. Repository Design
- Use local repositories for fast recovery
- Use cloud repositories for geographic redundancy
- Separate credentials per repository type
- Plan retention policies by data criticality

### 2. Snapshot Strategy
- Only enable snapshots for services that need consistency
- Use temporary snapshots for backup, not long-term retention
- Leverage existing Sanoid for ongoing snapshot management
- Document snapshot requirements in service modules

### 3. Monitoring Integration
- All metrics flow through textfile collector
- Use structured labels for filtering and grouping
- Set appropriate alerting thresholds per service type
- Include runbook links in alert annotations

### 4. Security Patterns
- Use SOPS for all backup credentials
- Separate environment files per repository
- Apply least-privilege access controls
- Encrypt all backup repositories

### 5. Testing and Validation
- Enable automated verification for critical repositories
- Test restore procedures regularly
- Monitor backup performance trends
- Document recovery procedures per service

## Migration Timeline

The unified backup system is implemented and ready for deployment:

1. **Current State**: Legacy backup-integration system operational
2. **Phase 1**: Deploy unified system alongside existing (testing)
3. **Phase 2**: Migrate services to unified patterns (gradual)
4. **Phase 3**: Deprecate legacy system (complete migration)
5. **Future**: Enhanced verification and compliance features

## Reference Implementation

See the complete implementation in:
- `hosts/_modules/nixos/services/backup/` - Unified backup module
- `hosts/forge/default.nix:542-556` - Grafana Sanoid integration example
- `hosts/forge/backup.nix:121-159` - Migration configuration example
- `hosts/_modules/lib/types.nix` - Backup submodule type definition

This unified approach provides enterprise-grade backup management while maintaining the simplicity and directness appropriate for homelab environments.
