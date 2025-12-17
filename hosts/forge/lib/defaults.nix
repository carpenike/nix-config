# hosts/forge/lib/defaults.nix
#
# Forge-specific defaults built on the shared host-defaults library.
# This file provides forge's specific configuration values.
#
# Usage:
#   let
#     forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
#   in
#   {
#     modules.services.myservice = {
#       podmanNetwork = forgeDefaults.podmanNetwork;
#       backup = forgeDefaults.backup;
#       preseed = forgeDefaults.preseed;
#       reverseProxy.caddySecurity = forgeDefaults.caddySecurity.media;
#     };
#   }

{ config, lib }:

# Import the shared host-defaults library with forge-specific configuration
import ../../../lib/host-defaults.nix {
  inherit config lib;
  hostConfig = {
    # ZFS pool configuration
    zfsPool = "tank";
    servicesDataset = "tank/services";

    # Container networking
    podmanNetwork = "media-services";

    # Replication to NAS
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv";
      sendOptions = "wp"; # Raw encrypted send with property preservation
      recvOptions = "u"; # Don't mount on receive
      # Updated after nas-1 NixOS migration (Dec 2025)
      hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdXExnO3O50DdbCmNHpaXUbKveVyuXGajQ6pDTGge9u";
      targetName = "NFS";
      targetLocation = "nas-1";
    };

    # Backup configuration
    backup = {
      repository = "nas-primary";
      mountPath = "/mnt/nas-backup";
      passwordSecret = "restic/password";
    };

    # Impermanence configuration
    impermanence = {
      persistPath = "/persist";
      rootPoolName = "rpool/local/root";
      rootBlankSnapshotName = "blank";
    };
  };
}
