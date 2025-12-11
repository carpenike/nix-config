# hosts/nas-0/lib/defaults.nix
#
# NAS-0 specific defaults built on the shared host-defaults library.
# This file provides nas-0's specific configuration values.
#
# nas-0 is a PRIMARY STORAGE host:
# - Primary bulk storage for media services (Plex, *arr stack on forge)
# - NFS exports: /mnt/tank/share, /mnt/tank/home
# - SMB shares for Windows/macOS access
# - Replicates critical datasets to nas-1 for redundancy
# - 117TB across 14 mirror vdevs (28 drives)

{ config, lib }:

import ../../../lib/host-defaults.nix {
  inherit config lib;
  hostConfig = {
    # ZFS pool configuration
    # nas-0 uses "tank" pool (14 mirror vdevs, 117TB total)
    zfsPool = "tank";
    servicesDataset = "tank/services"; # Minimal - NAS doesn't run many services

    # Container networking (minimal - NAS doesn't run containers)
    podmanNetwork = null;

    # Replication configuration
    # nas-0 replicates critical datasets to nas-1 for off-site redundancy
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/nas-0/zfs-recv";
      sendOptions = "w"; # Raw send (preserves encryption if any)
      recvOptions = "u"; # Don't mount on receive
      hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
      targetName = "NAS";
      targetLocation = "nas-1";
    };

    # Backup configuration
    # nas-0's system config can be backed up to B2 for DR
    # The main data on tank stays local (too large for cloud backup)
    backup = {
      repository = "b2-offsite";
      mountPath = "/mnt/backup-staging";
      passwordSecret = "restic/nas-0-password";
    };

    # Impermanence configuration
    impermanence = {
      persistPath = "/persist";
      rootPoolName = "rpool/local/root";
      rootBlankSnapshotName = "blank";
    };
  };
}
