# hosts/forge/services/bazarr.nix
#
# Host-specific configuration for the Bazarr service on 'forge'.
# Bazarr is a subtitle manager for Sonarr and Radarr.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.bazarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.bazarr = {
        enable = true;

        # Pin container image to specific version with digest
        image = "ghcr.io/home-operations/bazarr:1.5.4@sha256:6e2fab9cca3096714795458aec222da5e2e5cde07ed07e439f9879c9de3b5b94";

        # Bazarr needs to access both TV and movie directories
        tvDir = "/mnt/data/media/tv";
        moviesDir = "/mnt/data/media/movies";

        # Attach to media services network for DNS resolution to Sonarr and Radarr
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Systemd dependencies ensure Sonarr/Radarr start before Bazarr
        # API keys and URLs must be configured in Bazarr web UI: Settings -> Sonarr/Radarr
        # Use container hostnames: sonarr:8989 and radarr:7878 (DNS via media-services network)
        dependencies = {
          sonarr.enable = true;
          radarr.enable = true;
        };

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "bazarr.holthome.net";

          # Protect via Pocket ID + caddy-security; use media claim for authorization
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
      modules.backup.sanoid.datasets."tank/services/bazarr" = forgeDefaults.mkSanoidDataset "bazarr";

      # Service availability alert
      modules.alerting.rules."bazarr-service-down" =
        forgeDefaults.mkServiceDownAlert "bazarr" "Bazarr" "subtitle manager";
    })
  ];
}
