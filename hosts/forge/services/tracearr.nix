# hosts/forge/services/tracearr.nix
#
# Host-specific configuration for Tracearr on 'forge'.
# Tracearr provides account sharing detection and monitoring for Plex, Jellyfin, and Emby.
#
# Features:
# - Session tracking with IP geolocation (via MaxMind GeoIP)
# - Sharing detection rules (impossible travel, simultaneous locations, device velocity, etc.)
# - Trust scores and real-time alerts
# - Multi-server support (Plex, Jellyfin, Emby in one dashboard)
# - Stream map visualization
# - Tautulli/Jellystat history import
#
# Authentication: Uses native Plex/Jellyfin SSO (no additional auth layer needed)

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.tracearr.enable or false;
in
{
  config = lib.mkMerge [
    {
      # SOPS secrets for Tracearr
      # Add to hosts/forge/secrets.sops.yaml:
      #   tracearr:
      #     maxmind_license_key: <your-maxmind-license-key>
      sops.secrets."tracearr/maxmind_license_key" = {
        sopsFile = ../secrets.sops.yaml;
        owner = "tracearr";
        group = "tracearr";
        mode = "0400";
      };

      modules.services.tracearr = {
        enable = true;

        # Pin container image with digest for reproducibility
        # Renovate will automatically update this
        image = "ghcr.io/connorgallopo/tracearr:supervised@sha256:5527e61653fe98e690608546138244ab6ac19436f3c09f815d09826b428194cd";

        # Enable MaxMind GeoIP for accurate IP geolocation
        maxmindLicenseKeyFile = config.sops.secrets."tracearr/maxmind_license_key".path;

        healthcheck.enable = true;

        # Reverse proxy configuration for external access via Caddy
        # No caddySecurity - Tracearr authenticates via Plex/Jellyfin SSO
        reverseProxy = {
          enable = true;
          hostName = "tracearr.holthome.net";
        };

        # Enable backups via the custom backup module integration
        backup = forgeDefaults.backup;

        # Enable failure notifications via Pushover
        notifications.enable = true;

        # Enable self-healing restore from backups before service start
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Tracearr dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/tracearr" =
        forgeDefaults.mkSanoidDataset "tracearr";

      # Service-specific monitoring alerts
      # Contributes to host-level alerting configuration following the contribution pattern
      modules.alerting.rules."tracearr-service-down" =
        forgeDefaults.mkServiceDownAlert "tracearr" "Tracearr" "media monitoring";

      # Homepage dashboard contribution
      # Service registers itself with the dashboard using the contributory pattern
      modules.services.homepage.contributions.tracearr = {
        group = "Media";
        name = "Tracearr";
        icon = "mdi-radar"; # No official icon yet, using radar icon
        href = "https://tracearr.holthome.net";
        description = "Media server account monitoring";
        siteMonitor = "http://localhost:3004";
      };

      # Gatus availability monitoring
      # External health check for the service
      modules.services.gatus.contributions.tracearr = {
        name = "Tracearr";
        group = "Media";
        url = "https://tracearr.holthome.net";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
        ];
      };
    })
  ];
}
