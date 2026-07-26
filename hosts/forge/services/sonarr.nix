# hosts/forge/services/sonarr.nix
#
# Host-specific configuration for the Sonarr service on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/sonarr/default.nix

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.sonarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.sonarr = {
        enable = true;

        # Pin container image to a specific version with a digest for immutability.
        # Renovate bot can be configured to automate updates.
        image = "ghcr.io/home-operations/sonarr:4.0.19.2991@sha256:f9dec0cf69a45b16c698ef2a25fe6c70ff4ec8d0b2315897c0d48b3b5a456c87";

        # Use shared NFS mount and attach to the media services network.
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access via Caddy.
        reverseProxy = {
          enable = true;
          hostName = "sonarr.holthome.net";

          # Protect via Pocket ID + caddy-security; grant "media" role when the
          # upstream claim exposes the media group membership.
          # API bypass for /api, /feed, /ping - protected by Sonarr's built-in API key auth
          caddySecurity = forgeDefaults.caddySecurity.mediaWithApiBypass;
        };

        # Enable backups via the custom backup module integration.
        # Increased memory from default 512M to 1G - Sonarr's 1.3GB dataset
        # caused OOM kills during restic indexing (2026-02-03)
        backup = forgeDefaults.backup // {
          useSnapshots = true;
          zfsDataset = "tank/services/sonarr";
          resources = {
            memory = "1G";
            memoryReservation = "512M";
          };
        };

        # Enable failure notifications via the custom notifications module.
        notifications.enable = true;

        # Enable self-healing restore from backups before service start.
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.sonarr.protection = {
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
        validator = "sonarr-state";
        allowEmptyBootstrap = false;
      };

      # ZFS snapshot and replication configuration for Sonarr dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/sonarr" =
        forgeDefaults.mkSanoidDataset "sonarr";

      # Service-specific monitoring alerts
      # Contributes to host-level alerting configuration following the contribution pattern
      modules.alerting.rules."sonarr-service-down" =
        forgeDefaults.mkServiceDownAlert "sonarr" "Sonarr" "TV series management";

      # Homepage dashboard contribution
      # Service registers itself with the dashboard using the contributory pattern
      modules.services.homepage.contributions.sonarr = {
        group = "Media";
        name = "Sonarr";
        icon = "sonarr";
        href = "https://sonarr.holthome.net";
        description = "TV series management";
        siteMonitor = "http://localhost:8989";
        # Widget displays queue and series stats
        # API key injected via HOMEPAGE_VAR_SONARR_API_KEY environment variable
        widget = {
          type = "sonarr";
          url = "http://localhost:8989";
          key = "{{HOMEPAGE_VAR_SONARR_API_KEY}}";
          enableQueue = true;
        };
      };
    })
  ];
}
