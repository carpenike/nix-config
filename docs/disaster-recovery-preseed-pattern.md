# Disaster Recovery Preseed Pattern

**Last Updated**: 2025-12-31
**Status**: Active - Production Pattern
**Architecture**: ZFS Syncoid-based Multi-tier Restoration

## Overview

The preseed pattern provides automated disaster recovery for services with ZFS replication. When a service's dataset is missing or corrupted, a preseed service automatically restores it from the most recent backup source before the main service starts.

This pattern works for both **native systemd services** (Plex, Loki, Grafana) and **containerized services** (Sonarr, Radarr, Dispatcharr) with identical implementation.

## Architecture

### Multi-tier Restore Strategy

The preseed system attempts restoration in order of preference:

1. **Syncoid (Primary)**: Block-level replication from remote host (nas-1)
   - Fastest for large datasets
   - Preserves ZFS properties and snapshots
   - Maintains incremental replication lineage
   - Requires replication configured in Sanoid

2. **Local Snapshots**: ZFS snapshots on the same host
   - Instant rollback for recent snapshots
   - No network dependency
   - Preserves ZFS lineage
   - Limited to snapshot retention window

3. **Restic (Manual DR Only)**: File-based backup from repository
   - ⚠️ **NOT recommended for automated preseed** (breaks ZFS lineage)
   - Geographic redundancy (NFS/cloud)
   - Use only for true disaster recovery when ZFS sources unavailable
   - Requires manual intervention to re-establish replication after restore

### Restore Method Selection

**Recommended for homelab (default):**

```nix
restoreMethods = [ "syncoid" "local" ];
```

This configuration:

- Preserves ZFS snapshot lineage and incremental replication
- Fails preseed if nas-1 unavailable (correct signal for infrastructure issue)
- Allows manual intervention to fix root cause before bootstrapping

**When to include Restic:**

Only for services where immediate availability from offsite backup is more important than maintaining ZFS lineage:

```nix
restoreMethods = [ "syncoid" "local" "restic" ];  # Use sparingly
```

**Trade-offs:**

- ✅ Automatic recovery from offsite backup if ZFS sources fail
- ❌ Breaks ZFS incremental replication (future sends must be full)
- ❌ Hides infrastructure issues (nas-1 down = silent failover)
- ❌ Creates manual cleanup work to re-establish replication

### Component Architecture

```
Service Module (e.g., plex/default.nix)
├── Import storage-helpers.nix
├── findReplication Logic
│   ├── Search config.modules.backup.sanoid.datasets
│   ├── Find dataset matching service path
│   └── Extract replication configuration
├── replicationConfig Computation
│   ├── Parse remoteHost from replication target
│   ├── Compute source dataset (strip /zfs-recv suffix)
│   └── Build replication parameters
├── Preseed Options
│   ├── enable: Whether to enable preseed
│   ├── repositoryUrl: Restic repository path
│   ├── passwordFile: Repository authentication
│   ├── restoreMethods: ["syncoid" "local" "restic"]
│   └── (optional) environmentFile for cloud repos
└── Service Generation
    ├── mkPreseedService creates systemd unit
    ├── Main service depends on preseed
    └── Preseed runs only when dataset missing
```

## Implementation Pattern

### 1. Module Structure

Every service module with preseed support follows this structure:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.servicename;

  # Use mylib for storage helpers (injected via _module.args)
  storageHelpers = mylib.storageHelpers pkgs;
  helpers-lib = storageHelpers.mkHelpers {
    inherit config;
    serviceName = "servicename";
  };

  # Extract dataset path from service configuration
  datasetPath =
    if cfg.zfsDataset != null && lib.hasPrefix "/" cfg.zfsDataset
    then lib.removePrefix "/" cfg.zfsDataset
    else cfg.zfsDataset;

  # Find replication configuration from Sanoid datasets
  findReplication = datasets: mountpoint:
    let
      # Helper to get dataset mountpoint
      getMount = ds: ds.mountpoint or null;

      # Helper to get parent mount if dataset has no mountpoint
      findParentMount = path:
        let
          parts = lib.splitString "/" path;
          parentParts = lib.take ((lib.length parts) - 1) parts;
          parentPath = lib.concatStringsSep "/" parentParts;
          parentDataset = datasets.${parentPath} or null;
        in
          if parentDataset != null && parentDataset ? mountpoint
          then parentDataset.mountpoint
          else if parentPath != "" && parentPath != path
          then findParentMount parentPath
          else null;

      # Find all datasets that could match this mountpoint
      matchingDatasets = lib.filterAttrs (name: ds:
        let
          dsMount = getMount ds;
          actualMount =
            if dsMount != null
            then dsMount
            else findParentMount name;
        in
          actualMount != null && actualMount == mountpoint
      ) datasets;

      # Find datasets with replication configured
      replicatedDatasets = lib.filterAttrs (name: ds:
        ds ? replication && ds.replication != []
      ) matchingDatasets;

    in
      if replicatedDatasets != {}
      then lib.head (lib.attrValues replicatedDatasets)
      else null;

  # Compute replication configuration if available
  replicationConfig =
    if cfg.preseed.enable && cfg.zfsDataset != null
    then
      let
        replicationDataset = findReplication
          config.modules.backup.sanoid.datasets
          cfg.mountpoint;
      in
        if replicationDataset != null && replicationDataset ? replication
        then
          let
            firstReplication = lib.head replicationDataset.replication;
            # Extract remote host from target (e.g., "backup/forge/zfs-recv/servicename")
            targetParts = lib.splitString "/" firstReplication.target;
            remoteHost = lib.head targetParts;
            # Source dataset is target without /zfs-recv suffix
            sourceDataset = lib.concatStringsSep "/"
              (lib.filter (p: p != "zfs-recv") targetParts);
          in {
            inherit remoteHost sourceDataset;
            target = firstReplication.target;
          }
        else null
    else null;

in {
  options.modules.services.servicename = {
    # ... service options ...

    preseed = {
      enable = lib.mkEnableOption "preseed restoration for servicename";

      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for fallback restoration";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing repository password";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for cloud repository credentials";
      };

      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum ["syncoid" "local" "restic"]);
        default = ["syncoid" "local" "restic"];
        description = "Restore methods to attempt in order";
      };
    };
  };

  config = lib.mkMerge [
    # Main service configuration
    (lib.mkIf cfg.enable {
      # ... service config ...
    })

    # Preseed service generation
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      let
        preseedService = helpers-lib.mkPreseedService {
          serviceName = "servicename";
          dataset = datasetPath;
          mountpoint = cfg.mountpoint;
          mainServiceUnit = "servicename.service";
          replicationCfg = replicationConfig;
          datasetProperties = { };
          resticRepoUrl = cfg.preseed.repositoryUrl;
          resticPasswordFile = cfg.preseed.passwordFile;
          resticEnvironmentFile = cfg.preseed.environmentFile;
          resticPaths = [ cfg.mountpoint ];
          restoreMethods = cfg.preseed.restoreMethods;
          hasCentralizedNotifications = config.modules.notifications.enable or false;
          owner = "servicename";
          group = "servicename";
        };
      in {
        systemd.services = preseedService.systemd.services;

        # Add preseed dependency to main service
        systemd.services.servicename = {
          after = [ "preseed-servicename.service" ];
          wants = [ "preseed-servicename.service" ];
        };

        assertions = preseedService.assertions;
      }
    ))
  ];
}
```

### 2. Host Configuration

Enable preseed in the host configuration:

```nix
# hosts/forge/default.nix
modules.services.servicename = {
  enable = true;
  zfsDataset = "tank/services/servicename";
  mountpoint = "/var/lib/servicename";

  preseed = {
    enable = true;
    repositoryUrl = "/mnt/nas-backup";
    passwordFile = config.sops.secrets."restic/password".path;
    # Recommended: Exclude restic to preserve ZFS lineage
    restoreMethods = [ "syncoid" "local" ];
  };
};

# Configure Sanoid replication for the dataset
modules.backup.sanoid.datasets."tank/services/servicename" = {
  useTemplate = [ "production" ];
  recursive = false;
  replication = [{
    target = "backup/forge/zfs-recv/servicename";
    remoteHost = "nas-1.holthome.net";
  }];
};
```

### 3. mkPreseedService Parameters

The `mkPreseedService` helper function accepts:

| Parameter | Type | Description |
|-----------|------|-------------|
| `serviceName` | string | Name of the service (used for unit naming) |
| `dataset` | string | ZFS dataset path (e.g., "tank/services/plex") |
| `mountpoint` | path | Mount point for the dataset |
| `mainServiceUnit` | string | Main systemd service unit name |
| `replicationCfg` | attrset or null | Replication config from findReplication |
| `datasetProperties` | attrset | ZFS properties to set on dataset creation |
| `resticRepoUrl` | string | Restic repository URL for fallback |
| `resticPasswordFile` | path | Restic password file path |
| `resticEnvironmentFile` | path or null | Optional environment file for cloud repos |
| `resticPaths` | list | Paths to restore from Restic |
| `restoreMethods` | list | Ordered list of restore methods to try |
| `hasCentralizedNotifications` | bool | Whether to send notifications |
| `owner` | string | Dataset owner user |
| `group` | string | Dataset owner group |

## Service Coverage

### Services with Preseed Support

| Service | Type | Dataset | Status |
|---------|------|---------|--------|
| Plex | Native | tank/services/plex | ✅ Production |
| Loki | Native | tank/services/loki | ✅ Production |
| Grafana | Native | tank/services/grafana | ✅ Production |
| Sonarr | Container | tank/services/sonarr | ✅ Production |
| Radarr | Container | tank/services/radarr | ✅ Production |
| Dispatcharr | Container | tank/services/dispatcharr | ✅ Production |

### Services with Custom Preseed

| Service | Reason | Implementation |
|---------|--------|----------------|
| PostgreSQL | Custom PITR with pgBackRest | `postgresql-preseed.nix` |

### Services Without Preseed

| Service | Reason |
|---------|--------|
| Promtail | Stateless log shipper, no persistent data |
| Prometheus | Time-series data rebuilt from scraping |
| Caddy | Configuration managed declaratively |

## Testing Procedure

### Disaster Recovery Test

To validate preseed functionality:

```bash
# 1. Stop the service
ssh forge.holthome.net "sudo systemctl stop servicename.service"

# 2. Verify dataset size before deletion
ssh forge.holthome.net "zfs list tank/services/servicename"

# 3. Delete the dataset
ssh forge.holthome.net "sudo zfs destroy -r tank/services/servicename"

# 4. Verify dataset is gone
ssh forge.holthome.net "zfs list tank/services/servicename"  # Should fail

# 5. Trigger preseed restoration
ssh forge.holthome.net "sudo systemctl start preseed-servicename.service"

# 6. Monitor restoration progress
ssh forge.holthome.net "sudo journalctl -u preseed-servicename.service -f"

# 7. Verify dataset restored
ssh forge.holthome.net "zfs list tank/services/servicename"

# 8. Start the service
ssh forge.holthome.net "sudo systemctl start servicename.service"

# 9. Verify service functionality
ssh forge.holthome.net "curl -s http://localhost:PORT/health"
```

### Validated Test Results

**Plex Restoration** (2025-11-03):
- Dataset: tank/services/plex
- Size: 142M (compressed)
- Method: Syncoid from nas-1.holthome.net
- Duration: ~30 seconds
- Result: ✅ Service operational, HTTP 200

**Dispatcharr Restoration** (2025-11-03):
- Dataset: tank/services/dispatcharr
- Size: 704K
- Method: Syncoid from nas-1.holthome.net
- Duration: <10 seconds
- Result: ✅ Service operational

## Troubleshooting

### Preseed Service Not Running

Check if the condition is met:

```bash
# Preseed only runs if dataset is missing
zfs list tank/services/servicename

# Check systemd condition
systemctl cat preseed-servicename.service | grep ConditionPathExists
```

### Syncoid Restoration Failed

Check replication configuration:

```bash
# Verify replication target exists on nas-1
ssh nas-1.holthome.net "zfs list backup/forge/zfs-recv/servicename"

# Check SSH connectivity
ssh nas-1.holthome.net "echo 'Connection OK'"

# Test manual syncoid
sudo syncoid nas-1.holthome.net:backup/forge/zfs-recv/servicename tank/services/servicename
```

### Restic Restoration Failed

Check repository access:

```bash
# Test repository access
restic -r /mnt/nas-backup snapshots

# Check password file
cat /run/secrets/restic/password

# Verify NFS mount
mount | grep /mnt/nas-backup
```

## Integration with Backup System

The preseed pattern integrates with the unified backup system:

1. **Sanoid/Syncoid**: Provides ZFS replication to remote hosts
   - Configured in `modules.backup.sanoid.datasets`
   - Preseed uses `findReplication` to discover replication config

2. **Restic**: Provides file-based backups as fallback
   - Configured in service preseed options
   - Use sparingly to preserve ZFS lineage

3. **Monitoring**: Preseed services emit metrics
   - Success/failure status
   - Restoration duration
   - Data volume restored
   - Method used (syncoid/local/restic)

## Bootstrap Data Loss Protection

**Issue Identified**: 2025-11-10

New services with no pre-existing backups could lose data if a system rebuild occurred between initial bootstrap and the first Sanoid snapshot.

**Scenario:**

1. New service deploys with empty dataset (no backups exist)
2. All restore methods fail (expected for new service)
3. Service starts and creates initial configuration
4. Sanoid creates first snapshot
5. System rebuild happens before second snapshot
6. Preseed finds local snapshot, rolls back
7. **Data loss**: Changes between snapshots lost

**Solution Implemented:**

The preseed script now sets `holthome:preseed_complete=yes` property even when all restore methods fail. This treats "bootstrap with empty dataset" as a successful one-time event, preventing automatic rollback on subsequent rebuilds.

**Trade-off Accepted (Homelab Context):**

If nas-1 is down during first boot of a new service:

- Preseed marks complete anyway (no backup sources available)
- Service starts empty
- **Recovery**: `zfs destroy -r tank/services/SERVICE` + rebuild

This is acceptable for homelab because:

- Single operator with full context
- Notification alerts to preseed failure
- Recovery is trivial (one command)
- Alternative (complex error parsing) not worth maintenance burden

## Best Practices

1. **Always configure replication** for critical services
   - Syncoid provides fastest restoration
   - Preserves ZFS snapshots and properties

2. **Use ZFS-native restore methods by default** (homelab recommended)
   - `restoreMethods = ["syncoid" "local"]`
   - Preserves incremental replication capability
   - Provides clear signal when infrastructure issues occur

3. **Reserve Restic for true disaster recovery**
   - Only include in `restoreMethods` if immediate availability > ZFS lineage
   - Understand trade-off: automatic failover vs broken replication
   - Have plan to re-establish replication after Restic restore

4. **Test disaster recovery regularly**
   - Validates preseed functionality
   - Confirms backup integrity
   - Measures restoration time

5. **Monitor preseed services**
   - Alert on preseed failures
   - Track restoration metrics
   - Review logs after DR events

6. **Document service-specific requirements**
   - Special restore procedures
   - Post-restoration validation steps
   - Service dependencies

## Future Enhancements

Potential improvements to the preseed pattern:

- [ ] Automated preseed testing (scheduled DR drills)
- [ ] Pre-restore dataset snapshots (safety net)
- [ ] Parallel restoration from multiple sources
- [ ] Bandwidth throttling for Syncoid
- [ ] Smart restore method selection based on data size
- [ ] Integration with service health checks
- [ ] Automated rollback on restoration failure

## Related Documentation

- **Storage Module**: `docs/storage-module-guide.md`
- **Unified Backup**: `docs/unified-backup-design-patterns.md`
- **PostgreSQL Preseed**: `docs/postgresql-preseed-marker-fix.md`
- **Sanoid/Syncoid**: `docs/backup-system-onboarding.md`
- **ZFS Replication**: `docs/zfs-replication-setup.md`

## References

- **Implementation**: `modules/nixos/storage/helpers-lib.nix` (mkPreseedService, via `mylib.storageHelpers pkgs`)
- **Example Modules**:
  - `modules/nixos/services/plex/default.nix`
  - `modules/nixos/services/loki/default.nix`
  - `modules/nixos/services/grafana/default.nix`
- **Host Config**: `hosts/forge/default.nix`
