# hosts/forge/services/radarr.nix
#
# Host-specific configuration for the Radarr service on 'forge'.
# Radarr is a movie collection manager.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.radarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.radarr = {
        enable = true;

        # Pin container image to specific version with digest
        image = "ghcr.io/home-operations/radarr:6.0.4@sha256:73fbdba72dcde5fec16264e63a9daba7829b5c2806a75615463a67117b100de3";

        # Use shared NFS mount and attach to media services network
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "radarr.holthome.net";

          # Protect via Pocket ID + caddy-security; grant media role via claim mapping
          caddySecurity = forgeDefaults.caddySecurity.media;
        };

        # Enable backups
        backup = forgeDefaults.backup;

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/radarr" = forgeDefaults.mkSanoidDataset "radarr";

      # Service availability alert
      modules.alerting.rules."radarr-service-down" =
        forgeDefaults.mkServiceDownAlert "radarr" "Radarr" "movie management";
    })
  ];
}
