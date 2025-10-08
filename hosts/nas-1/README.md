# nas-1 Configuration (Future NixOS Migration)

This directory contains configuration files and TODOs for when nas-1 is migrated from Ubuntu to NixOS.

## Current State

- **OS**: Ubuntu 24.04 LTS
- **Role**: Primary backup destination and NFS server
- **IP**: 10.20.0.11
- **Hostname**: nas-1.holthome.net

## Purpose

nas-1 serves as:

1. **NFS Server**: Provides storage for Restic repositories
2. **ZFS Replication Target**: Receives block-level ZFS snapshots from forge
3. **Backup Archive**: Long-term storage for all backups

## Directory Structure (Planned)

```text
hosts/nas-1/
├── README.md              # This file
├── TODO.md                # Migration TODOs and manual steps to automate
├── default.nix            # Main configuration (when migrating to NixOS)
├── hardware.nix           # Hardware configuration
├── zfs-replication.nix    # ZFS receive configuration
├── sanoid.nix             # Snapshot pruning for replicated data
├── nfs.nix                # NFS server exports
├── network.nix            # Network configuration
└── ssh.nix                # SSH hardening
```

## Migration Plan

See [TODO.md](./TODO.md) for detailed migration steps and configuration examples.

## Key Manual Configurations to Preserve

Current Ubuntu configurations that need to be replicated in NixOS:

1. **ZFS Datasets**:
   - `backup/forge/restic` - NFS-exported Restic repository
   - `backup/forge/zfs-recv` - ZFS replication target

2. **Users**:
   - `zfs-replication` - Receives snapshots from forge

3. **NFS Exports**:
   - `/mnt/backup/forge/restic` exported to forge

4. **ZFS Permissions**:
   - `zfs-replication` user can receive snapshots
   - Future: `sanoid` user can prune old snapshots

## Related Documentation

- [ZFS Replication Setup](../../docs/zfs-replication-setup.md)
- [Backup System Onboarding](../../docs/backup-system-onboarding.md)
- [Backup Forge Setup](../../docs/backup-forge-setup.md)

## Status

🚧 **Pre-Migration Phase**: Currently documenting manual configurations for automation when migrating to NixOS.

## Next Steps

1. ✅ Document all manual configurations
2. ⏳ Create example NixOS configurations
3. ⏳ Test in VM environment
4. ⏳ Plan migration cutover
5. ⏳ Execute migration
6. ⏳ Validate all services
