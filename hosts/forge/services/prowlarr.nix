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
        image = "ghcr.io/home-operations/prowlarr:2.6.3.5592@sha256:8c9ee448bb6de0e3e8b9c2f536b7a3455ec6ff5e184c2fb2a8602791b2757442";

        # Prowlarr is an indexer manager - it doesn't need access to downloads/media directories
        downloadsDir = null;
        mediaDir = null;

        # Attach to media services network for DNS resolution
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "prowlarr.holthome.net";
          # API bypass for /api, /feed, /ping - protected by Prowlarr's built-in API key auth
          caddySecurity = forgeDefaults.caddySecurity.mediaWithApiBypass;
        };

        # Resource limits: use module defaults (512M memory, 1 CPU)

        # Enable crash-consistent backups from a read-only ZFS snapshot.
        backup = forgeDefaults.backup // {
          useSnapshots = true;
          zfsDataset = "tank/services/prowlarr";
        };

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.prowlarr.protection = {
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
        validator = "prowlarr-state";
        allowEmptyBootstrap = false;
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/prowlarr" = forgeDefaults.mkSanoidDataset "prowlarr";

      # Service availability alert
      modules.alerting.rules."prowlarr-service-down" =
        forgeDefaults.mkServiceDownAlert "prowlarr" "Prowlarr" "indexer manager";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.prowlarr = {
        group = "Downloads";
        name = "Prowlarr";
        icon = "prowlarr";
        href = "https://prowlarr.holthome.net";
        description = "Indexer Manager";
        siteMonitor = "http://localhost:9696";
        widget = {
          type = "prowlarr";
          url = "http://localhost:9696";
          key = "{{HOMEPAGE_VAR_PROWLARR_API_KEY}}";
        };
      };
    })
  ];
}
