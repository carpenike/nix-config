# Persistence Implementation Execution Plan

**Status**: Ready for Implementation
**Last Updated**: 2025-10-09
**Validated By**: Gemini Pro 2.5, O3-mini

---

## Executive Summary

This plan implements the persistence architecture from `persistence-implementation-plan.md` with the following validated approach:
- **Declarative dataset management** via NixOS modules (no manual ZFS commands)
- **Host-level pool configuration** (forge uses `tank`, others use `rpool`)
- **Per-service datasets** with automatic creation and ZFS property tuning
- **Layered architecture** preserving existing `/persist` base while adding service isolation
- **Breaking changes acceptable** - homelab environment allows fast iteration

---

## Architectural Decisions

### ✅ Validated Architecture (Gemini Pro + O3-mini Consensus)

#### 1. Layered Dataset Structure
```
Base (disko-config.nix):
  rpool/safe/persist → /persist (legacy mount)
  rpool/safe/home → /home (legacy mount)

Service Layer (automatic):
  rpool/safe/persist/sonarr → /persist/sonarr (auto-mount)
  rpool/safe/persist/plex → /persist/plex (auto-mount)
  rpool/safe/persist/postgres → /persist/postgres (auto-mount)
```

**Why**:
- Base datasets in disko provide foundation (explicit control)
- Service datasets layer on top (automatic hierarchy)
- ZFS property inheritance from parent
- Per-service isolation without breaking existing setup

#### 2. Automatic Dataset Creation
```nix
# Service module declares requirements
modules.storage.datasets.services.sonarr = {
  recordsize = "16K";
  compression = "lz4";
};

# Activation script creates automatically
system.activationScripts.zfs-service-datasets
```

**Why**:
- Fully declarative (no manual admin commands)
- Idempotent (safe to run multiple times)
- Runs after pool import, before services start
- Standard NixOS pattern for stateful changes

#### 3. Host-Level Pool Configuration
```nix
# Forge (2x NVME → tank pool)
modules.storage.datasets.parentDataset = "tank/persist";

# Other hosts (boot pool)
modules.storage.datasets.parentDataset = "rpool/safe/persist";
```

**Why**:
- Services remain generic and reusable
- Pool selection per-host requirements
- Single configuration point
- Scales to multiple pools if needed

#### 4. Hybrid Mount Strategy
- **Base datasets**: `mountpoint = "legacy"` (explicit control, boot-critical)
- **Service datasets**: ZFS auto-mount (automatic hierarchy)

**Why**:
- Best of both worlds
- Explicit control for system-critical mounts
- Automatic mounting for service datasets
- Avoids complex fileSystems declarations

---

## Implementation Phases

### Phase 0: Foundation (CURRENT STATE) ✅
- [x] Base datasets in disko-config.nix
- [x] Impermanence working with /persist
- [x] Backup system operational (backup.nix)
- [x] Notification system integrated
- [x] Helper functions established (lib/backup-helpers.nix, lib/notification-helpers.nix)

### Phase 1: Storage Dataset Module (Foundational)
**Time**: 2-3 hours
**Risk**: Low (no breaking changes, new functionality)

#### 1.1 Create Storage Datasets Module
**File**: `hosts/_modules/nixos/storage/datasets.nix`

**Features**:
- Options for host-level pool configuration
- Service dataset declarations
- Automatic ZFS dataset creation via activation scripts
- Idempotent operations (check existence before create)
- Property inheritance with per-service overrides

**Key Components**:
```nix
options.modules.storage.datasets = {
  enable = mkEnableOption "declarative ZFS dataset management";
  parentDataset = mkOption { default = "rpool/safe/persist"; };
  parentMount = mkOption { default = "/persist"; };
  services = mkOption { /* per-service config */ };
};

system.activationScripts.zfs-service-datasets = {
  deps = [ "zfs-import-scan" ];
  text = /* dataset creation logic */;
};
```

**Success Criteria**:
- Module loads without errors
- Activation script runs after pool import
- Idempotent dataset creation works
- Properties set correctly

#### 1.2 Import Module
**File**: `hosts/_modules/nixos/default.nix`

```nix
imports = [
  # ... existing imports
  ./storage/datasets.nix
];
```

#### 1.3 Test on Single Host
**Host**: forge (has tank pool, good test case)

```nix
# hosts/forge/default.nix
modules.storage.datasets = {
  enable = true;
  parentDataset = "tank/persist";
  parentMount = "/persist";
};
```

**Validation**:
```bash
nixos-rebuild dry-build  # Check for errors
nixos-rebuild test       # Test without boot entry
# Verify activation script runs
# Check no datasets created yet (no services declared)
```

---

### Phase 2: Service Integration Pattern (1 Service Proof of Concept)
**Time**: 2-3 hours
**Risk**: Low (single service, reversible)

#### 2.1 Choose Pilot Service
**Recommendation**: Sonarr
- Small footprint
- Non-critical (can tolerate downtime)
- Representative pattern for other *arr apps
- SQLite database (good test of recordsize tuning)

#### 2.2 Update Service Module
**File**: Create or update Sonarr service module

```nix
# hosts/_modules/nixos/services/sonarr/default.nix
{ config, lib, ... }:
let
  cfg = config.services.sonarr;
  storageCfg = config.modules.storage.datasets;
in {
  config = lib.mkIf cfg.enable {
    # Declare dataset requirements
    modules.storage.datasets.services.sonarr = {
      recordsize = "16K";  # SQLite + small files
      compression = "lz4";
      properties = {
        "com.sun:auto-snapshot" = "true";
      };
    };

    # Configure service
    services.sonarr.dataDir = "${storageCfg.parentMount}/sonarr";

    # Ensure permissions
    systemd.tmpfiles.rules = [
      "d ${storageCfg.parentMount}/sonarr 0755 sonarr sonarr - -"
    ];

    # Backup integration (reuse existing pattern)
    modules.backup.restic.jobs.sonarr = lib.mkIf config.modules.backup.enable {
      enable = true;
      paths = [ "${storageCfg.parentMount}/sonarr" ];
      excludePatterns = [ "**/.cache" "**/*.tmp" ];
      repository = "nas-primary";
      tags = [ "sonarr" "media" ];
    };
  };
}
```

#### 2.3 Migration Steps (Forge)
```bash
# 1. Backup current data (safety first)
restic backup /persist/var/lib/sonarr --tag pre-migration

# 2. Enable new configuration
nixos-rebuild switch

# 3. Verify dataset created
zfs list | grep sonarr
# Expected: tank/persist/sonarr

# 4. Stop service and migrate data
systemctl stop sonarr
rsync -avP /persist/var/lib/sonarr/ /persist/sonarr/

# 5. Verify data integrity
ls -la /persist/sonarr/
# Check config files, database present

# 6. Start service with new location
systemctl start sonarr

# 7. Verify service health
systemctl status sonarr
curl http://localhost:8989  # Or appropriate health check

# 8. Cleanup old data (after validation)
# Wait 24-48 hours to ensure stability
rm -rf /persist/var/lib/sonarr
```

**Success Criteria**:
- ✅ Dataset created automatically
- ✅ ZFS properties set correctly (recordsize=16K)
- ✅ Service starts successfully
- ✅ Data accessible and functional
- ✅ Backup job runs successfully
- ✅ No errors in journal logs

---

### Phase 3: Expand to Additional Services
**Time**: 1-2 hours per service
**Risk**: Low (proven pattern from Phase 2)

#### 3.1 Service Priority Order
1. **Radarr** (similar to Sonarr)
2. **Plex** (large recordsize test)
3. **Home Assistant** (frequent writes test)
4. **PostgreSQL** (database optimization test)

#### 3.2 ZFS Property Matrix

| Service | recordsize | compression | Properties | Reasoning |
|---------|------------|-------------|------------|-----------|
| Sonarr | 16K | lz4 | auto-snapshot=true | SQLite + small files |
| Radarr | 16K | lz4 | auto-snapshot=true | SQLite + small files |
| Plex | 1M | lz4 | auto-snapshot=false | Large media cache, frequent rewrites |
| Home Assistant | 16K | lz4 | auto-snapshot=true | Frequent small writes |
| PostgreSQL (data) | 8K | lz4 | logbias=latency | Matches PG page size |
| PostgreSQL (WAL) | 128K | off | logbias=throughput | Sequential writes |

#### 3.3 Template for Each Service

```nix
modules.storage.datasets.services.{service} = {
  recordsize = "{size}";
  compression = "{lz4|off}";
  properties = {
    "com.sun:auto-snapshot" = "{true|false}";
    # Additional properties as needed
  };
};

services.{service}.dataDir = "${storageCfg.parentMount}/{service}";

systemd.tmpfiles.rules = [
  "d ${storageCfg.parentMount}/{service} {mode} {user} {group} - -"
];

modules.backup.restic.jobs.{service} = {
  enable = true;
  paths = [ "${storageCfg.parentMount}/{service}" ];
  # Service-specific excludes
};
```

#### 3.4 Migration Runbook Template

```bash
# For each service:
1. Backup current data
2. Deploy new config (nixos-rebuild switch)
3. Verify dataset created (zfs list)
4. Stop service
5. Migrate data (rsync)
6. Start service
7. Verify functionality
8. Wait 24-48h before cleanup
```

---

### Phase 4: Sanoid/Syncoid Integration
**Time**: 3-4 hours
**Risk**: Medium (replaces custom snapshot logic)

#### 4.1 Create Replication Module
**File**: `hosts/_modules/nixos/replication/zfs.nix`

```nix
options.modules.replication.zfs = {
  enable = mkEnableOption "ZFS replication via Sanoid/Syncoid";

  sanoid = {
    datasets = mkOption {
      # Snapshot retention policies per dataset
    };
  };

  syncoid = {
    enable = mkEnableOption "Syncoid replication";
    destination = mkOption { type = types.str; };
    datasets = mkOption { /* datasets to replicate */ };
  };
};
```

#### 4.2 Replace Custom Snapshot Logic
**File**: `hosts/_modules/nixos/backup.nix`

- Remove custom ZFS snapshot service (lines 563-640)
- Delegate to Sanoid module
- Keep backup job integration

#### 4.3 Configuration Example

```nix
modules.replication.zfs = {
  enable = true;

  sanoid.datasets = {
    "tank/persist" = {
      useTemplate = [ "production" ];
      recursive = true;  # Apply to all children
    };
  };

  syncoid = {
    enable = true;
    destination = "backup-pool/tank-replica";
    datasets = [ "tank/persist" ];
  };
};
```

#### 4.4 Notification Templates

Add to `hosts/_modules/nixos/notifications/default.nix`:

```nix
modules.notifications.templates = {
  sanoid-failure = {
    enable = true;
    priority = "high";
    title = "Sanoid Snapshot Failed";
    body = "Dataset: ${dataset}\nError: ${errorMessage}";
  };

  syncoid-lag-warning = {
    enable = true;
    priority = "medium";
    title = "Syncoid Replication Lag";
    body = "Lag: ${lagHours} hours\nDataset: ${dataset}";
  };
};
```

**Success Criteria**:
- ✅ Sanoid creates snapshots on schedule
- ✅ Syncoid replicates to backup pool
- ✅ Notifications fire on failures
- ✅ Custom snapshot logic removed
- ✅ Backup jobs still function

---

### Phase 5: Preseed Services (Self-Healing)
**Time**: 4-6 hours
**Risk**: Medium (complex restore logic)

#### 5.1 Add to Storage Helpers
**File**: `lib/storage-helpers.nix`

```nix
mkPreseedService = {
  serviceName,
  dataPath,
  resticRepo,
  zfsDataset ? null,
  timeout ? 3600,
  ...
}: {
  systemd.services."preseed@${serviceName}" = {
    description = "Pre-seed data for ${serviceName}";
    before = [ "${serviceName}.service" ];
    wants = [ "zfs-mount.service" ];
    after = [ "zfs-mount.service" ];

    script = ''
      set -euo pipefail

      # Check if data exists
      if [ -d "${dataPath}" ] && [ "$(ls -A ${dataPath})" ]; then
        echo "Data exists at ${dataPath}, skipping restore"
        exit 0
      fi

      echo "Data missing at ${dataPath}, attempting restore..."

      # Try 1: ZFS snapshot restore (fastest)
      ${lib.optionalString (zfsDataset != null) ''
        if zfs list -t snapshot | grep -q "^${zfsDataset}@"; then
          echo "Attempting ZFS snapshot restore..."
          LATEST_SNAP=$(zfs list -t snapshot -o name -s creation ${zfsDataset} | tail -n1)
          if zfs send "$LATEST_SNAP" | zfs receive -F "${zfsDataset}"; then
            echo "Successfully restored from ZFS snapshot"
            exit 0
          fi
        fi
      ''}

      # Try 2: Restic restore (slower, but reliable)
      echo "Attempting Restic restore from ${resticRepo}..."
      if restic restore latest --target "${dataPath}" --repo "${resticRepo}"; then
        echo "Successfully restored from Restic backup"
        exit 0
      fi

      # Try 3: S3 restore (slowest, last resort)
      # Could be implemented if S3 is separate from Restic

      # If we get here, all restores failed
      echo "WARNING: All restore attempts failed for ${serviceName}"
      echo "Service will start with empty data directory"
      mkdir -p "${dataPath}"
      exit 0  # Don't fail - let service try to initialize
    '';

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = timeout;
      User = "root";
      RemainAfterExit = true;
    };
  };
};
```

#### 5.2 Service Integration Pattern

```nix
# In service module
config = lib.mkIf cfg.enable (lib.mkMerge [
  # Existing config

  # Add preseed service
  (storageHelpers.mkPreseedService {
    serviceName = "sonarr";
    dataPath = "/persist/sonarr";
    resticRepo = config.modules.backup.restic.repositories.nas-primary.url;
    zfsDataset = "tank/persist/sonarr";
    timeout = 1800;  # 30 minutes
  })

  # Update service dependencies
  {
    systemd.services.sonarr = {
      after = [ "preseed@sonarr.service" ];
      wants = [ "preseed@sonarr.service" ];
    };
  }
]);
```

#### 5.3 Notification Integration

```nix
modules.notifications.templates = {
  preseed-success = {
    enable = true;
    priority = "low";
    title = "Data Restored: ${serviceName}";
    body = "Source: ${restoreSource}\nDuration: ${duration}";
  };

  preseed-failure = {
    enable = true;
    priority = "high";
    title = "Restore Failed: ${serviceName}";
    body = "All restore methods failed\nService starting with empty data";
  };

  preseed-skipped = {
    enable = true;
    priority = "low";
    title = "Restore Skipped: ${serviceName}";
    body = "Data already present";
  };
};
```

#### 5.4 Testing Procedure

```bash
# Test restore automation
1. Stop service
2. Move data directory (simulate loss)
   mv /persist/sonarr /persist/sonarr.backup
3. Start service
   systemctl start sonarr
4. Monitor preseed service
   journalctl -u preseed@sonarr -f
5. Verify restore completed
6. Verify service started successfully
7. Compare data integrity
```

**Success Criteria**:
- ✅ Preseed service detects missing data
- ✅ ZFS snapshot restore works (if available)
- ✅ Restic fallback works
- ✅ Service starts after restore
- ✅ Notifications sent for all outcomes
- ✅ Timeout prevents infinite hangs

---

### Phase 6: Barman-Cloud PostgreSQL PITR (If Using PostgreSQL)
**Time**: 2-3 hours
**Risk**: Low (isolated to PostgreSQL)

#### 6.1 Create PITR Module
**File**: `hosts/_modules/nixos/database/postgresql/pitr.nix`

```nix
options.modules.database.postgresql.pitr = {
  enable = mkEnableOption "PostgreSQL PITR via Barman-Cloud";

  s3Bucket = mkOption { type = types.str; };
  passwordFile = mkOption { type = types.path; };
  environmentFile = mkOption { type = types.path; };

  walArchiveCommand = mkOption {
    type = types.str;
    default = "barman-cloud-wal-archive s3://\${cfg.s3Bucket} %p";
  };

  baseBackupSchedule = mkOption {
    type = types.str;
    default = "daily";
  };
};
```

#### 6.2 PostgreSQL Integration

```nix
config = lib.mkIf cfg.enable {
  # Configure PostgreSQL for WAL archival
  services.postgresql.settings = {
    archive_mode = "on";
    archive_command = cfg.walArchiveCommand;
    wal_level = "replica";
    max_wal_senders = 3;
  };

  # Create separate datasets for data and WAL
  modules.storage.datasets.services = {
    postgres-data = {
      recordsize = "8K";
      compression = "lz4";
      properties.logbias = "latency";
    };
    postgres-wal = {
      recordsize = "128K";
      compression = "off";
      properties.logbias = "throughput";
    };
  };

  # Base backup service
  systemd.services.postgres-base-backup = {
    description = "PostgreSQL base backup to S3";
    serviceConfig.Type = "oneshot";
    script = ''
      barman-cloud-backup \
        --compression gzip \
        s3://${cfg.s3Bucket} \
        pg-main
    '';
  };

  systemd.timers.postgres-base-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = cfg.baseBackupSchedule;
  };
};
```

#### 6.3 Exclude from General Backups

```nix
# In backup.nix configuration
modules.backup.restic.jobs.system = {
  paths = [ "/persist" ];
  excludePatterns = [
    "/persist/postgres-data/**"  # Handled by Barman
    "/persist/postgres-wal/**"   # Handled by Barman
  ];
};
```

**Success Criteria**:
- ✅ WAL archival to S3 working
- ✅ Base backups created on schedule
- ✅ PITR restore tested and documented
- ✅ PostgreSQL data excluded from filesystem backups
- ✅ Monitoring alerts configured

---

## Host-Specific Configurations

### Forge (2x NVME, tank pool)

```nix
# hosts/forge/default.nix
{
  modules.storage.datasets = {
    enable = true;
    parentDataset = "tank/persist";
    parentMount = "/persist";
  };

  # Services use tank automatically
  services.sonarr.enable = true;  # Creates tank/persist/sonarr
  services.radarr.enable = true;  # Creates tank/persist/radarr
  services.plex.enable = true;    # Creates tank/persist/plex
}
```

### Luna/Rydev (Standard hosts, rpool)

```nix
# hosts/luna/default.nix or hosts/rydev/default.nix
{
  modules.storage.datasets = {
    enable = true;
    parentDataset = "rpool/safe/persist";
    parentMount = "/persist";
  };

  # Services use rpool automatically
  services.home-assistant.enable = true;  # Creates rpool/safe/persist/home-assistant
}
```

---

## Rollback Strategy

### Per Phase Rollback

**Phase 1 (Storage Module)**:
```bash
# Remove from imports
git revert <commit>
nixos-rebuild switch
```

**Phase 2-3 (Service Migration)**:
```bash
# Per service:
1. Stop service
2. Move data back: rsync /persist/{service}/ /persist/var/lib/{service}/
3. Revert config: services.{service}.dataDir = "/persist/var/lib/{service}";
4. Rebuild and start service
5. Destroy dataset: zfs destroy tank/persist/{service}
```

**Phase 4 (Sanoid/Syncoid)**:
```bash
# Restore custom snapshot logic
git revert <commits>
nixos-rebuild switch
# Sanoid datasets remain but inactive
```

**Phase 5 (Preseed)**:
```bash
# Disable preseed services
services.{service}.wants = lib.mkForce [];
services.{service}.after = lib.mkForce [];
nixos-rebuild switch
```

---

## Testing Checklist

### Per-Service Testing

- [ ] Dataset created automatically
- [ ] ZFS properties set correctly
- [ ] Service starts successfully
- [ ] Data readable and writable
- [ ] Backup job runs
- [ ] Restore test successful
- [ ] Preseed automation works
- [ ] Notifications fire correctly
- [ ] No errors in journal
- [ ] Performance acceptable

### System-Wide Testing

- [ ] All services start on boot
- [ ] Impermanence still functions
- [ ] Backups complete successfully
- [ ] Monitoring dashboards show data
- [ ] Disk usage as expected
- [ ] ZFS scrub runs successfully
- [ ] Replication lag acceptable
- [ ] Documentation generated

---

## Monitoring & Alerts

### Key Metrics to Track

```
# ZFS Health
- Dataset capacity (per service)
- Snapshot count and age
- Replication lag
- Scrub status and errors

# Backup Status
- Last backup time (per service)
- Backup success rate
- Restore test results
- Preseed activation frequency

# Service Health
- Service start failures after preseed
- Data migration completion
- Property configuration drift
```

### Alert Thresholds

```yaml
Critical:
  - Replication lag > 24 hours
  - Backup failure > 48 hours
  - Preseed failures
  - Dataset capacity > 90%

Warning:
  - Replication lag > 12 hours
  - Backup failure > 24 hours
  - Snapshot age > 48 hours
  - Dataset capacity > 80%
```

---

## Success Criteria (Overall)

### Phase 1
- [x] Storage datasets module created
- [ ] Module loads without errors
- [ ] Activation scripts run correctly
- [ ] No impact on existing systems

### Phase 2
- [ ] Single service migrated successfully
- [ ] Dataset auto-creation works
- [ ] ZFS properties applied
- [ ] Service functional
- [ ] Backup integration works

### Phase 3
- [ ] All services migrated
- [ ] Per-service optimization verified
- [ ] No data loss
- [ ] All services functional
- [ ] Performance improvements measured

### Phase 4
- [ ] Sanoid managing snapshots
- [ ] Syncoid replicating
- [ ] Custom logic removed
- [ ] Notifications working
- [ ] Replication verified

### Phase 5
- [ ] Preseed services functional
- [ ] Restore automation tested
- [ ] All restore paths validated
- [ ] Timeouts working correctly
- [ ] Self-healing verified

### Phase 6 (If Applicable)
- [ ] Barman-Cloud configured
- [ ] WAL archival working
- [ ] Base backups running
- [ ] PITR tested
- [ ] PostgreSQL excluded from general backups

---

## Documentation Updates Required

### Files to Update

1. **README.md**
   - Add storage architecture section
   - Document per-service datasets
   - Link to this plan

2. **New: docs/storage-architecture.md**
   - Detailed architecture documentation
   - Dataset hierarchy
   - Pool configuration guide
   - Service integration patterns

3. **New: docs/restore-procedures.md**
   - Manual restore procedures
   - Preseed troubleshooting
   - PITR restore for PostgreSQL
   - Disaster recovery runbook

4. **Update: docs/backup-system-onboarding.md**
   - Integration with new storage system
   - Dataset-aware backups
   - Service-specific considerations

---

## Timeline Estimate

| Phase | Time | Dependencies |
|-------|------|--------------|
| Phase 1 | 2-3 hours | None |
| Phase 2 | 2-3 hours | Phase 1 |
| Phase 3 | 4-8 hours | Phase 2 |
| Phase 4 | 3-4 hours | Phase 3 |
| Phase 5 | 4-6 hours | Phase 4 |
| Phase 6 | 2-3 hours | Phase 3 (optional) |
| **Total** | **17-27 hours** | Over 2-3 weekends |

---

## Risk Assessment

### Low Risk
- Phase 1: New module, no changes to existing system
- Phase 2: Single service, full backup available
- Phase 6: Isolated to PostgreSQL

### Medium Risk
- Phase 3: Multiple services, coordination needed
- Phase 4: Replacing proven custom logic
- Phase 5: Complex restore logic

### Mitigation
- ✅ Comprehensive backups before each phase
- ✅ Per-service rollback procedures documented
- ✅ Test on non-critical services first
- ✅ Breaking changes acceptable (homelab)
- ✅ Can pause between phases
- ✅ Rollback tested for each phase

---

## Next Steps

1. **Review this plan** - Ensure alignment with goals
2. **Start Phase 1** - Create storage datasets module
3. **Test Phase 1** - Deploy to forge, verify activation
4. **Proceed sequentially** - Complete each phase before next
5. **Document learnings** - Update plan with actual findings

---

## Notes

- This is a homelab environment - breaking changes are acceptable
- Can implement phases independently (except dependencies)
- Each phase is reversible
- Focus on one host at a time (forge first)
- Document actual time taken vs estimates
- Update this plan as implementation reveals new insights

---

## References

- Original Plan: `docs/persistence-implementation-plan.md`
- Architecture Analysis: Gemini Pro 2.5 (2025-10-09)
- Technical Validation: O3-mini (2025-10-09)
- Existing Modules: `hosts/_modules/nixos/backup.nix`, `hosts/_modules/nixos/impermanence.nix`
- Helper Libraries: `lib/backup-helpers.nix`, `lib/notification-helpers.nix`
