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
        image = "ghcr.io/home-operations/radarr:6.1.2@sha256:9967e56263a3c67eeaede5824103ee4c1c1f1511abd5965ac1e294bfd9b76dbb";

        # Use shared NFS mount and attach to media services network
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "radarr.holthome.net";

          # Protect via Pocket ID + caddy-security; grant media role via claim mapping
          # API bypass for /api, /feed, /ping - protected by Radarr's built-in API key auth
          caddySecurity = forgeDefaults.caddySecurity.mediaWithApiBypass;
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

      # Homepage dashboard contribution
      modules.services.homepage.contributions.radarr = {
        group = "Media";
        name = "Radarr";
        icon = "radarr";
        href = "https://radarr.holthome.net";
        description = "Movie collection manager";
        siteMonitor = "http://localhost:7878";
        # Widget displays queue and movie stats
        # API key injected via HOMEPAGE_VAR_RADARR_API_KEY environment variable
        widget = {
          type = "radarr";
          url = "http://localhost:7878";
          key = "{{HOMEPAGE_VAR_RADARR_API_KEY}}";
          enableQueue = true;
        };
      };
    })
  ];
}
