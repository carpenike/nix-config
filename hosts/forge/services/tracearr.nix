# hosts/forge/services/tracearr.nix
#
# Host-specific configuration for Tracearr on 'forge'.
# Tracearr provides account sharing detection and monitoring for Plex, Jellyfin, and Emby.
#
# Architecture: External Database Mode
# - PostgreSQL with TimescaleDB extension (managed by forge's PostgreSQL)
# - Redis for caching/sessions (shared forge Redis instance, DB index 0)
# - Standard tracearr image (not supervised all-in-one)
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
      modules.services.tracearr = {
        enable = true;

        # Use external database mode (centralized PostgreSQL + Redis)
        deploymentMode = "external";

        # Use standard image (not supervised all-in-one)
        # Pin with digest for reproducibility; Renovate will update
        image = "ghcr.io/connorgallopo/tracearr:latest";

        # Enable MaxMind GeoIP for accurate IP geolocation
        maxmindLicenseKeyFile = config.sops.secrets."tracearr/maxmind_license_key".path;

        # External PostgreSQL configuration (forge's centralized instance)
        # TimescaleDB extension is enabled on the database
        database = {
          host = "host.containers.internal"; # Podman bridge to host
          port = 5432;
          name = "tracearr";
          user = "tracearr";
          passwordFile = config.sops.secrets."tracearr/db_password".path;
          manageDatabase = true; # Auto-provision via postgresql module
        };

        # Security secrets (required for external mode)
        # These are used by the tracearr web server for authentication/sessions
        secrets = {
          jwtSecretFile = config.sops.secrets."tracearr/jwt_secret".path;
          cookieSecretFile = config.sops.secrets."tracearr/cookie_secret".path;
        };

        # External Redis configuration (forge's centralized instance)
        redis.url = "redis://host.containers.internal:6379/0";

        healthcheck.enable = true;

        # Reverse proxy configuration for external access via Caddy
        # No caddySecurity - Tracearr authenticates via Plex/Jellyfin SSO
        reverseProxy = {
          enable = true;
          hostName = "tracearr.holthome.net";
        };

        # Enable backups (external mode only backs up app data, not databases)
        backup = forgeDefaults.backup;

        # Enable failure notifications via Pushover
        notifications.enable = true;

        # Enable self-healing restore from backups before service start
        preseed = forgeDefaults.preseed;
      };

      # Provision tracearr database in centralized PostgreSQL
      # TimescaleDB extension enables time-series capabilities for session tracking
      modules.services.postgresql.databases.tracearr = {
        owner = "tracearr";
        ownerPasswordFile = config.sops.secrets."tracearr/db_password".path;
        extensions = [ "timescaledb" ];
        # Grafana datasource for tracearr dashboards (optional)
        grafanaDatasources = [{
          name = "Tracearr";
          timescaleDB = true;
          folder = "Media";
          dashboards = [ ];
        }];
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
