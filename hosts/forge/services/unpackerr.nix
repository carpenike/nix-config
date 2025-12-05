# Unpackerr - Archive extraction for Starr apps
#
# Unpackerr monitors download directories and extracts compressed archives (rar, zip, 7z)
# so Sonarr/Radarr can import media files. It polls arr apps for queued items and extracts
# archives as they complete downloading.
#
# Key behaviors:
# - delete_orig = false for torrents (preserve for cross-seeding via qBittorrent)
# - delete_orig = true for usenet (SABnzbd downloads - no seeding needed)
#
# Architecture: STATELESS worker - no persistent storage, all config via environment
# Integrations: Sonarr, Radarr
# No web UI - pure worker service
{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.unpackerr.enable or false;
in
{
  config = lib.mkMerge [
    # Service configuration
    {
      modules.services.unpackerr = {
        enable = true;

        # Container settings
        user = 917; # Unpackerr UID (917 is unused in media stack)
        group = 65537; # media group GID
        timezone = config.time.timeZone;

        # Infrastructure
        podmanNetwork = forgeDefaults.podmanNetwork;
        nfsMountDependency = "media";
        mediaDir = "/mnt/media";

        # Environment file with API keys (defined in secrets.nix)
        environmentFile = config.sops.templates."unpackerr/env".path;

        # Sonarr integration
        sonarr = {
          enable = true;
          url = "http://sonarr:8989";
          # API key comes from environment file
          path = "/data/qb/downloads"; # qBittorrent download directory
          protocols = "torrent";
          deleteOrig = false; # Preserve for cross-seeding
          deleteDelay = "5m";
        };

        # Radarr integration
        radarr = {
          enable = true;
          url = "http://radarr:7878";
          # API key comes from environment file
          path = "/data/qb/downloads"; # qBittorrent download directory
          protocols = "torrent";
          deleteOrig = false; # Preserve for cross-seeding
          deleteDelay = "5m";
        };

        # Extraction settings
        startDelay = "1m"; # Wait for arr apps to start
        retryDelay = "5m";
        maxRetries = 3;
        parallel = 1; # Sequential extractions

        # Resource limits
        resources = {
          memory = "512M";
          memoryReservation = "128M";
          cpus = "1.0";
        };
      };
    }

    # Guard downstream contributions with serviceEnabled check
    (lib.mkIf serviceEnabled {
      # Service-down alert (stateless service - no backup/sanoid needed)
      modules.alerting.rules."unpackerr-service-down" =
        forgeDefaults.mkServiceDownAlert "unpackerr" "Unpackerr" "archive extraction";
    })
  ];
}
