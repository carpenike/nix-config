# hosts/nas-1/lib/defaults.nix
#
# NAS-1 specific defaults built on the shared host-defaults library.
# This file provides nas-1's specific configuration values.
#
# nas-1 is a BACKUP TARGET host:
# - Receives ZFS replication from forge (via zfs-replication user)
# - Receives ZFS replication from nas-0 (TrueNAS primary NAS)
# - Exports NFS shares for Restic and PostgreSQL backups
# - Does NOT replicate its own data elsewhere (it IS the backup)
# - Minimal services: NFS, ZFS, Tailscale, SSH

{ config, lib }:

import ../../../lib/host-defaults.nix {
  inherit config lib;
  hostConfig = {
    # ZFS pool configuration
    # nas-1 uses "backup" pool (RAIDZ1 with 4x12TB HDDs)
    zfsPool = "backup";
    servicesDataset = "backup/services"; # Minimal - NAS doesn't run many services

    # Container networking (minimal - NAS doesn't run containers)
    podmanNetwork = null;

    # Replication configuration
    # nas-1 does NOT replicate out - it IS the replication target
    # Set to null to indicate this host receives but doesn't send
    replication = null;

    # Backup configuration
    # nas-1's own config can be backed up to B2 for DR
    # but the main backup data on ZFS stays local
    backup = {
      repository = "b2-offsite";
      mountPath = "/mnt/backup-staging";
      passwordSecret = "restic/nas-1-password";
    };

    # Impermanence configuration (if using)
    impermanence = {
      persistPath = "/persist";
      rootPoolName = "rpool/local/root";
      rootBlankSnapshotName = "blank";
    };
  };
}
