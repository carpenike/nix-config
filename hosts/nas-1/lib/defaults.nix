# hosts/nas-1/lib/defaults.nix
#
# NAS-1 specific defaults built on the shared host-defaults library.
# This file provides nas-1's specific configuration values.
#
# NAS hosts typically:
# - Are replication TARGETS (receive from other hosts) rather than sources
# - Have different ZFS pool names (e.g., "data", "backup")
# - May not run containerized services
# - Have different backup strategies (offsite to B2/S3)

{ config, lib }:

import ../../../lib/host-defaults.nix {
  inherit config lib;
  hostConfig = {
    # ZFS pool configuration - NAS typically has different pools
    zfsPool = "data"; # Main data pool
    servicesDataset = "data/services"; # If running services on NAS

    # Container networking (if running containers)
    podmanNetwork = "nas-services";

    # Replication configuration
    # NAS-1 replicates to NAS-0 for redundancy (or to offsite)
    replication = {
      targetHost = "nas-0.holthome.net";
      targetDataset = "backup/nas-1/zfs-recv";
      sendOptions = "wp";
      recvOptions = "u";
      hostKey = "nas-0.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."; # TODO: Add actual key
      targetName = "NAS-0";
      targetLocation = "nas-0";
    };

    # Backup configuration - NAS might back up to different location
    backup = {
      repository = "b2-offsite"; # Offsite backup for critical data
      mountPath = "/mnt/backup-staging";
      passwordSecret = "restic/nas-password";
    };
  };
}
