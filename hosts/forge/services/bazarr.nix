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
        image = "ghcr.io/home-operations/bazarr:1.6.0@sha256:cd63bbd0986c93e238eb8b9442604d249f0d4080099b389f822abe2062044417";

        # Bazarr needs to access both TV and movie directories
        tvDir = "/mnt/data/media/tv";
        moviesDir = "/mnt/data/media/movies";

        # Attach to media services network for DNS resolution to Sonarr and Radarr
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Resource limits - increased from default 256M due to memory alert
        # Bazarr uses ~230M under normal load, 512M provides headroom
        resources = {
          memory = "512M";
          memoryReservation = "256M";
          cpus = "1.0";
        };

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
          # API bypass for /api - protected by Bazarr's built-in API key auth
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
      modules.storage.datasets.services.bazarr.protection = {
        class = "standard";
        objectives = {
          onsiteRpoSeconds = 86400;
          offsiteRpoSeconds = null;
          rtoSeconds = 28800;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = "bazarr-state";
        allowEmptyBootstrap = false;
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/bazarr" = forgeDefaults.mkSanoidDataset "bazarr";

      # Service availability alert
      modules.alerting.rules."bazarr-service-down" =
        forgeDefaults.mkServiceDownAlert "bazarr" "Bazarr" "subtitle manager";
    })
  ];
}
