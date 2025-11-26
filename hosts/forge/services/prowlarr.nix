# hosts/forge/services/prowlarr.nix
#
# Host-specific configuration for the Prowlarr service on 'forge'.
# Prowlarr is an indexer manager for *arr services.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.prowlarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.prowlarr = {
        enable = true;

        # Pin container image to specific version with digest
        image = "ghcr.io/home-operations/prowlarr:2.1.5.5216@sha256:affb671fa367f4b7029d58f4b7d04e194e887ed6af1cf5a678f3c7aca5caf6ca";

        # Attach to media services network for DNS resolution
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "prowlarr.holthome.net";
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
      modules.backup.sanoid.datasets."tank/services/prowlarr" = forgeDefaults.mkSanoidDataset "prowlarr";

      # Service availability alert
      modules.alerting.rules."prowlarr-service-down" =
        forgeDefaults.mkServiceDownAlert "prowlarr" "Prowlarr" "indexer manager";
    })
  ];
}
