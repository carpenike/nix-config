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

let
  # Podman bridge gateway IPs (single source of truth for forge).
  # media-services network (podman1): Caddy also listens here so containers can
  # reach reverse-proxied services without hairpin NAT.
  podmanBridgeGateway = "10.89.0.1";
  # Default podman network (podman0): what host.containers.internal resolves to;
  # host services (PostgreSQL, Redis) bind here for container access.
  podmanDefaultBridgeGateway = "10.88.0.1";
in

# Import the shared host-defaults library with forge-specific configuration
(import ../../../lib/host-defaults.nix {
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
})
// {
  inherit podmanBridgeGateway podmanDefaultBridgeGateway;

  # Hairpin-NAT workaround for containers doing PocketID OIDC:
  # id.<domain> resolves to forge's LAN IP, which container bridges can't
  # reach, so OIDC discovery times out. Point the container's hosts file at
  # the podman bridge gateway where Caddy also listens.
  # Usage: extraHosts = forgeDefaults.pocketidHostsEntry;
  pocketidHostsEntry = {
    "id.${config.networking.domain}" = podmanBridgeGateway;
  };
}
