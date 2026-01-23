# ADR-007: Multi-Tier Disaster Recovery (Preseed Pattern)

**Status**: Accepted
**Date**: December 9, 2025
**Context**: NixOS homelab automated service restoration

## Context

Services with persistent data need automated recovery when their ZFS dataset is missing or corrupted. Without automation, restoring a service requires manual intervention, increasing downtime and operational burden.

Several restoration sources exist with different trade-offs:

- **ZFS Syncoid replication**: Fast, block-level, preserves snapshots
- **Local ZFS snapshots**: Instant, no network dependency
- **Restic file backup**: Offsite, geographic redundancy

The question is how to orchestrate these sources for automatic recovery.

## Decision

**Implement a multi-tier preseed system that attempts restoration in priority order, with Restic excluded from automated restore by default.**

### Restore Priority Order

1. **Syncoid (Primary)**: Block-level replication from nas-1
   - Fastest for large datasets
   - Preserves ZFS properties and snapshot lineage
   - Maintains incremental replication for future syncs

2. **Local Snapshots**: ZFS snapshots on same host
   - Instant rollback
   - No network dependency
   - Limited to retention window

3. **Restic (Manual DR Only)**: File-based backup
   - ⚠️ **NOT recommended for automated preseed**
   - Breaks ZFS lineage (future sends must be full)
   - Use only for true disaster recovery with manual intervention

### Default Configuration

```nix
restoreMethods = [ "syncoid" "local" ];  # Recommended
```

### Architecture

```text
Service Start
    │
    ▼
┌─────────────────────┐
│ Dataset exists?     │──Yes──▶ Start service normally
└─────────┬───────────┘
          │ No
          ▼
┌─────────────────────┐
│ Try Syncoid restore │──Success──▶ Start service
└─────────┬───────────┘
          │ Fail
          ▼
┌─────────────────────┐
│ Try local snapshot  │──Success──▶ Start service
└─────────┬───────────┘
          │ Fail
          ▼
    Preseed fails
    (Alert operator)
```

## Consequences

### Positive

- **Automatic recovery**: Services restore themselves without intervention
- **Preserved ZFS lineage**: Syncoid/local restores maintain incremental capability
- **Clear failure signal**: Preseed failure indicates infrastructure issue (nas-1 down)
- **Consistent pattern**: Same implementation for native and containerized services

### Negative

- **No automatic offsite restore**: Restic excluded from automation
- **Network dependency**: Syncoid requires nas-1 reachability
- **Manual DR for worst case**: True disaster requires operator intervention

### Why Exclude Restic from Automation

Including Restic in automated preseed has these problems:

1. **Breaks ZFS lineage**: After Restic restore, future Syncoid sends must be full (not incremental)
2. **Hides infrastructure issues**: nas-1 down = silent failover instead of alert
3. **Creates cleanup work**: Manual re-establishment of replication required
4. **False sense of recovery**: Service runs, but backup infrastructure is degraded

### When to Include Restic

Only for services where immediate availability is more important than ZFS lineage:

```nix
# Use sparingly - only for critical services
restoreMethods = [ "syncoid" "local" "restic" ];
```

## Implementation

### Service Module Integration

```nix
# In service module
preseed = {
  enable = lib.mkEnableOption "automatic restore before service start";
  repositoryUrl = lib.mkOption { type = lib.types.str; };
  passwordFile = lib.mkOption { type = lib.types.path; };
  restoreMethods = lib.mkOption {
    type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
    default = [ "syncoid" "local" ];
  };
};
```

### Host Configuration

```nix
# Using forgeDefaults helper
modules.services.sonarr = {
  enable = true;
  preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
};
```

### Preseed Service Unit

```nix
systemd.services."preseed-${serviceName}" = {
  wantedBy = [ ];  # Started as dependency only
  before = [ "${serviceName}.service" ];
  requiredBy = [ "${serviceName}.service" ];

  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
  };

  script = ''
    if zfs list ${dataset} &>/dev/null; then
      echo "Dataset exists, skipping preseed"
      exit 0
    fi

    # Try restore methods in order...
  '';
};
```

## Related

- [Disaster Recovery Preseed Pattern](../disaster-recovery-preseed-pattern.md) - Full documentation
- [Preseed Restore Methods Guide](../preseed-restore-methods-guide.md) - Method selection
- [ADR-002: Host-Level Defaults Library](./002-host-level-defaults-library.md) - `mkPreseed` helper
